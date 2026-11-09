import AppKit
import ClipboardCore
import ImageIO

/// Decode for the intended display area rather than retaining preview-sized
/// pixels for every history row. Both variants share one cache and work budget.
enum ThumbnailVariant: String, CaseIterable, Sendable {
    case list, preview

    fileprivate func cacheKey(for key: String) -> String { rawValue + ":" + key }

    fileprivate func maximumPixelSize(width: Int, height: Int, orientation: Int) -> Int {
        let rotated = (5...8).contains(orientation)
        let displayedWidth = rotated ? height : width
        let displayedHeight = rotated ? width : height
        let box: (width: Double, height: Double)
        switch self {
        // 416 pt panel − 2×14 pt list padding − 2×12 pt card padding,
        // with a 122 pt row image height, at a conservative 2× display scale.
        case .list: box = (728, 244)
        case .preview: box = (600, 600)
        }
        let scale = min(1, min(box.width / Double(displayedWidth), box.height / Double(displayedHeight)))
        return max(1, Int((Double(max(displayedWidth, displayedHeight)) * scale).rounded(.down)))
    }
}

@MainActor
protocol ThumbnailProviding: AnyObject {
    var onChange: (() -> Void)? { get set }
    var totalCost: Int { get }
    var invalidationID: UUID { get }
    func image(forKey key: String, at url: URL, variant: ThumbnailVariant) -> NSImage?
    func remove(forKey key: String)
    func removeAll()
    func setActive(_ active: Bool)
}

extension ThumbnailProviding {
    func image(forKey key: String, at url: URL) -> NSImage? {
        image(forKey: key, at: url, variant: .list)
    }
}

/// CGImage is immutable here. NSImage creation and all cache ownership stay on the main actor.
struct DecodedThumbnail: @unchecked Sendable {
    let image: CGImage
    let cost: Int
}

/// Limits retained work as well as decoded cache bytes; a cache miss never blocks the UI.
@MainActor
final class ThumbnailPipeline: ThumbnailProviding {
    typealias Loader = @Sendable (URL, ThumbnailVariant) -> DecodedThumbnail?
    enum MemoryPressure { case normal, warning, critical }

    var onChange: (() -> Void)?
    var totalCost: Int { cache.totalCost }
    var invalidationID: UUID { generation }
    // Includes cancelled operations until their completion has been consumed on the main actor.
    var pendingRequestCount: Int { requests.count }

    private let cache: ThumbnailCache
    private let loader: Loader
    private let maxPending: Int
    private let maxFailedKeys = 256
    private let queue: OperationQueue
    private var requests: [UUID: DecodeOperation] = [:]
    private var currentRequests: [String: UUID] = [:]
    private var failedKeys: Set<String> = []
    private var generation = UUID()
    private var active = true
    private var underMemoryPressure = false
    private var pressureSource: DispatchSourceMemoryPressure?

    init(
        cache: ThumbnailCache? = nil, maxPending: Int = 8,
        observesMemoryPressure: Bool = true,
        loader: @escaping Loader = { ThumbnailPipeline.loadThumbnail(at: $0, variant: $1) }
    ) {
        self.cache = cache ?? ThumbnailCache()
        self.maxPending = max(1, maxPending)
        self.loader = loader
        queue = OperationQueue()
        queue.name = "ClipboardDeck.thumbnail-decoding"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        if observesMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical], queue: .main)
            pressureSource = source
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let events = self.pressureSource?.data else { return }
                    if events.contains(.critical) {
                        self.handleMemoryPressure(.critical)
                    } else if events.contains(.warning) {
                        self.handleMemoryPressure(.warning)
                    } else if events.contains(.normal) {
                        self.handleMemoryPressure(.normal)
                    }
                }
            }
            source.resume()
        }
    }

    deinit {
        pressureSource?.cancel()
        queue.cancelAllOperations()
    }

    func image(forKey sourceKey: String, at url: URL, variant: ThumbnailVariant) -> NSImage? {
        guard active, !underMemoryPressure else { return nil }
        let key = variant.cacheKey(for: sourceKey)
        if let image = cache.image(forKey: key) { return image }
        guard currentRequests[key] == nil, !failedKeys.contains(key),
            failedKeys.count < maxFailedKeys, requests.count < maxPending
        else { return nil }

        let token = UUID()
        let requestGeneration = generation
        let operation = DecodeOperation(url: url, variant: variant, loader: loader)
        operation.completionBlock = { [weak self, weak operation] in
            // OperationQueue invokes this after main() returns, so the immutable result is ready.
            let result = operation?.decoded
            DispatchQueue.main.async { [weak self] in
                self?.finish(key: key, token: token, generation: requestGeneration, result: result)
            }
        }
        requests[token] = operation
        currentRequests[key] = token
        queue.addOperation(operation)
        return nil
    }

    func remove(forKey key: String) {
        for variant in ThumbnailVariant.allCases {
            let variantKey = variant.cacheKey(for: key)
            cache.remove(forKey: variantKey)
            failedKeys.remove(variantKey)
            if let token = currentRequests.removeValue(forKey: variantKey) { requests[token]?.cancel() }
        }
    }

    func removeAll() {
        invalidate()
        onChange?()
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if !active { invalidate() }
        onChange?()
    }

    /// Also used by deterministic self-tests; production events use the same transition path.
    func handleMemoryPressure(_ pressure: MemoryPressure) {
        switch pressure {
        case .warning, .critical:
            underMemoryPressure = true
            invalidate()
            onChange?()
        case .normal:
            guard underMemoryPressure else { return }
            underMemoryPressure = false
            if active { onChange?() }
        }
    }

    private func invalidate() {
        generation = UUID()
        currentRequests.removeAll()
        failedKeys.removeAll()
        cache.removeAll()
        queue.cancelAllOperations()
        // Keep outstanding operations counted until completion. In particular, ImageIO work
        // already running cannot be interrupted, and rapid close/reopen must not grow the queue.
    }

    private func finish(
        key: String, token: UUID, generation requestGeneration: UUID,
        result: DecodedThumbnail?
    ) {
        guard requests.removeValue(forKey: token) != nil else { return }
        guard currentRequests[key] == token, generation == requestGeneration,
            active, !underMemoryPressure
        else {
            // A discarded old request may have occupied the last slot when the panel reopened.
            if active && !underMemoryPressure { onChange?() }
            return
        }
        currentRequests.removeValue(forKey: key)
        if let result, result.cost > 0 {
            let image = NSImage(
                cgImage: result.image,
                size: NSSize(width: result.image.width, height: result.image.height))
            cache.insert(image, forKey: key, cost: result.cost)
        }
        if cache.image(forKey: key) == nil {
            // A failed/oversized image must not cause a redraw → retry loop. This set is bounded;
            // after 256 failures, further misses wait for the next clear/presentation generation.
            if failedKeys.count < maxFailedKeys { failedKeys.insert(key) }
        }
        onChange?()
    }

    nonisolated static func loadThumbnail(at url: URL, variant: ThumbnailVariant = .list) -> DecodedThumbnail? {
        guard url.isFileURL,
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, let size = values.fileSize,
            size > 0, size <= HistoryStore.maxImageBytes,
            let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [
                    kCGImageSourceShouldCache: false
                ] as CFDictionary),
            CGImageSourceGetStatus(source) == .statusComplete,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 20_000, height <= 20_000,
            Int64(width) * Int64(height) <= 40_000_000
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let maximumPixelSize = variant.maximumPixelSize(width: width, height: height, orientation: orientation)
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary),
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { return nil }
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, cost > 0 else { return nil }
        return DecodedThumbnail(image: image, cost: cost)
    }
}

private final class DecodeOperation: Operation, @unchecked Sendable {
    private let url: URL
    private let variant: ThumbnailVariant
    private let loader: ThumbnailPipeline.Loader
    private(set) var decoded: DecodedThumbnail?

    init(url: URL, variant: ThumbnailVariant, loader: @escaping ThumbnailPipeline.Loader) {
        self.url = url
        self.variant = variant
        self.loader = loader
        super.init()
    }

    override func main() {
        guard !isCancelled else { return }
        decoded = autoreleasepool { loader(url, variant) }
        if isCancelled { decoded = nil }
    }
}
