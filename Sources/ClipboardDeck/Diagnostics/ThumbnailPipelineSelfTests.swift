import AppKit
import ImageIO
import ClipboardCore

@MainActor
enum ThumbnailPipelineSelfTests {
    static func run() throws {
        let decoded = try fixture()
        try checkScheduling(decoded)
        try checkCancellation(decoded)
        try checkReplacementToken(decoded)
        try checkPressureAndFailures(decoded)
        try checkPresentationFeedback(decoded)
        try checkLifetime(decoded)
        try checkDefaultLoader()
        try checkVariants()
        try checkRepeatedInvalidation(decoded)
        print(
            "PASS: background thumbnail decoding / serial bounded work / deduplication / stale-result rejection / pressure recovery / failure suppression / presentation feedback / release / input limits / display-sized decoding / variant isolation and shared budgets"
        )
    }

    private static func checkScheduling(_ decoded: DecodedThumbnail) throws {
        let probe = LoaderProbe(result: decoded, blockedNames: ["a"])
        let pipeline = ThumbnailPipeline(
            maxPending: 3, observesMemoryPressure: false,
            loader: { url, _ in probe.load(url) })
        defer { probe.release.signal(); pipeline.setActive(false) }
        var callbacks = 0
        var callbacksOnMain = true
        pipeline.onChange = {
            callbacks += 1
            callbacksOnMain = callbacksOnMain && Thread.isMainThread
        }
        for _ in 0..<10 { _ = pipeline.image(forKey: "a", at: url("a")) }
        try check(SelfTestWait.until { probe.started.count == 1 }, "the first decode starts")
        _ = pipeline.image(forKey: "b", at: url("b"))
        _ = pipeline.image(forKey: "c", at: url("c"))
        _ = pipeline.image(forKey: "d", at: url("d"))
        try check(
            pipeline.pendingRequestCount == 3,
            "running and queued work share a bound; duplicate keys do not add requests")
        try check(
            probe.started == ["a"] && !probe.ranOnMain,
            "decoding runs off the main thread and queued work stays serial")
        probe.release.signal()
        try check(SelfTestWait.until { pipeline.pendingRequestCount == 0 }, "bounded work completes")
        try check(
            Set(probe.started) == Set(["a", "b", "c"]) && probe.started.count == 3 && probe.peak == 1 && callbacks == 3
                && callbacksOnMain,
            "deduplicated work runs once, with serial decodes and main-thread notifications")
        try check(
            pipeline.image(forKey: "a", at: url("a")) != nil,
            "completed work is available synchronously from the cache")
        _ = pipeline.image(forKey: "d", at: url("d"))
        try check(
            SelfTestWait.until { pipeline.image(forKey: "d", at: url("d")) != nil },
            "a capacity-rejected request can be retried after completion")
    }

    private static func checkCancellation(_ decoded: DecodedThumbnail) throws {
        let probe = LoaderProbe(result: decoded, blockedNames: ["old", "removed", "cleared"])
        let pipeline = ThumbnailPipeline(
            maxPending: 1, observesMemoryPressure: false,
            loader: { url, _ in probe.load(url) })
        defer { probe.release.signal(); pipeline.setActive(false) }
        _ = pipeline.image(forKey: "same", at: url("old"))
        try check(SelfTestWait.until { probe.started.contains("old") }, "old decode begins")
        pipeline.setActive(false)
        pipeline.setActive(true)
        _ = pipeline.image(forKey: "same", at: url("new"))
        try check(
            pipeline.pendingRequestCount == 1 && pipeline.totalCost == 0,
            "close/reopen does not forget an in-flight operation or grow the queue")
        probe.release.signal()
        try check(
            SelfTestWait.until { pipeline.pendingRequestCount == 0 } && pipeline.totalCost == 0,
            "a result from before hiding cannot repopulate the cache")
        _ = pipeline.image(forKey: "same", at: url("new"))
        try check(
            SelfTestWait.until { pipeline.image(forKey: "same", at: url("new")) != nil },
            "reactivation allows new requests")

        pipeline.remove(forKey: "same")
        _ = pipeline.image(forKey: "same", at: url("removed"))
        try check(SelfTestWait.until { probe.started.contains("removed") }, "removed decode begins")
        pipeline.remove(forKey: "same")
        probe.release.signal()
        try check(
            SelfTestWait.until { pipeline.pendingRequestCount == 0 } && pipeline.totalCost == 0,
            "removing an individual key rejects its late result")

        _ = pipeline.image(forKey: "same", at: url("cleared"))
        try check(SelfTestWait.until { probe.started.contains("cleared") }, "cleared decode begins")
        pipeline.removeAll()
        probe.release.signal()
        try check(
            SelfTestWait.until { pipeline.pendingRequestCount == 0 } && pipeline.totalCost == 0,
            "clearing rejects results from the previous generation")
    }

    private static func checkPressureAndFailures(_ decoded: DecodedThumbnail) throws {
        let probe = LoaderProbe(result: decoded, blockedNames: ["pressure"], failedNames: ["bad"])
        let pipeline = ThumbnailPipeline(
            maxPending: 2, observesMemoryPressure: false,
            loader: { url, _ in probe.load(url) })
        defer { probe.release.signal(); pipeline.setActive(false) }
        _ = pipeline.image(forKey: "cached", at: url("cached"))
        try check(SelfTestWait.until { pipeline.totalCost > 0 }, "a cached image exists before pressure")
        weak var released: NSImage?
        autoreleasepool { released = pipeline.image(forKey: "cached", at: url("cached")) }
        _ = pipeline.image(forKey: "pressure", at: url("pressure"))
        try check(SelfTestWait.until { probe.started.contains("pressure") }, "pressure decode starts")
        _ = pipeline.image(forKey: "queued", at: url("queued"))
        pipeline.handleMemoryPressure(.warning)
        try check(pipeline.totalCost == 0 && released == nil, "pressure releases cached image references")
        _ = pipeline.image(forKey: "blocked", at: url("blocked"))
        probe.release.signal()
        try check(
            SelfTestWait.until { pipeline.pendingRequestCount == 0 } && pipeline.totalCost == 0
                && !probe.started.contains("queued") && !probe.started.contains("blocked"),
            "pressure cancels queued work, discards late results, and suppresses new work")
        pipeline.setActive(false)
        pipeline.setActive(true)
        _ = pipeline.image(forKey: "blocked", at: url("blocked"))
        try check(
            pipeline.pendingRequestCount == 0,
            "reopening cannot bypass the memory-pressure suspension")
        pipeline.handleMemoryPressure(.critical)
        pipeline.handleMemoryPressure(.normal)
        _ = pipeline.image(forKey: "recovered", at: url("recovered"))
        try check(
            SelfTestWait.until { pipeline.image(forKey: "recovered", at: url("recovered")) != nil },
            "a normal-pressure event resumes loading")

        _ = pipeline.image(forKey: "bad", at: url("bad"))
        try check(SelfTestWait.until { pipeline.pendingRequestCount == 0 }, "failed decode completes")
        for _ in 0..<20 { _ = pipeline.image(forKey: "bad", at: url("bad")) }
        try check(
            pipeline.pendingRequestCount == 0 && probe.started.filter { $0 == "bad" }.count == 1,
            "failed data cannot cause an automatic redraw/retry loop")
        pipeline.remove(forKey: "bad")
        _ = pipeline.image(forKey: "bad", at: url("bad"))
        try check(
            SelfTestWait.until { pipeline.pendingRequestCount == 0 } && probe.started.filter { $0 == "bad" }.count == 2,
            "explicit invalidation permits a failed key to be retried")
    }

    private static func checkReplacementToken(_ decoded: DecodedThumbnail) throws {
        let probe = LoaderProbe(result: decoded, blockedNames: ["old-token"])
        let pipeline = ThumbnailPipeline(
            maxPending: 2, observesMemoryPressure: false,
            loader: { url, _ in probe.load(url) })
        defer { probe.release.signal(); pipeline.setActive(false) }
        _ = pipeline.image(forKey: "same", at: url("old-token"))
        try check(SelfTestWait.until { probe.started.contains("old-token") }, "replaced decode begins")
        pipeline.remove(forKey: "same")
        _ = pipeline.image(forKey: "same", at: url("fresh-token"))
        try check(pipeline.pendingRequestCount == 2, "old and replacement requests are both accounted for")
        probe.release.signal()
        try check(
            SelfTestWait.until { pipeline.pendingRequestCount == 0 }
                && pipeline.image(forKey: "same", at: url("fresh-token")) != nil
                && probe.started == ["old-token", "fresh-token"],
            "an old completion cannot remove or supersede a replacement with the same key")
    }

    private static func checkLifetime(_ decoded: DecodedThumbnail) throws {
        let probe = LoaderProbe(result: decoded, blockedNames: ["lifetime"])
        var pipeline: ThumbnailPipeline? = ThumbnailPipeline(
            observesMemoryPressure: true,
            loader: { url, _ in probe.load(url) })
        weak var released: ThumbnailPipeline?
        released = pipeline
        _ = pipeline?.image(forKey: "lifetime", at: url("lifetime"))
        try check(SelfTestWait.until { probe.started.contains("lifetime") }, "lifetime decode starts")
        pipeline = nil
        try check(released == nil, "neither the pressure source nor pending work retains its owner")
        probe.release.signal()
        try check(SelfTestWait.until { probe.finished == 1 }, "orphaned work can finish safely")
    }

    private static func checkPresentationFeedback(_ decoded: DecodedThumbnail) throws {
        let probe = LoaderProbe(result: decoded)
        let pipeline = ThumbnailPipeline(
            cache: ThumbnailCache(maxCost: decoded.cost * 2, maxCount: 2), maxPending: 2,
            observesMemoryPressure: false, loader: { url, _ in probe.load(url) })
        let presentations = (0..<6).map { index in
            ThumbnailPresentation(provider: pipeline, key: "row-\(index)", url: url("row-\(index)"))
        }
        // Mimic the real coarse notification: every instantiated row sees every completion.
        pipeline.onChange = { presentations.forEach { $0.refresh() } }
        defer {
            pipeline.onChange = nil
            presentations.forEach { $0.disappear() }
            pipeline.setActive(false)
        }
        presentations.forEach { $0.appear() }
        try check(
            SelfTestWait.until {
                presentations.allSatisfy { $0.image != nil } && pipeline.pendingRequestCount == 0
            }, "more presented rows than cache slots can all finish loading")
        for _ in 0..<30 { presentations.forEach { $0.refresh() } }
        try check(
            probe.started.count == 6 && pipeline.pendingRequestCount == 0 && pipeline.totalCost <= decoded.cost * 2,
            "cache eviction plus coarse redraws do not create a decode/evict loop")

        weak var released: NSImage?
        released = presentations[0].image
        pipeline.handleMemoryPressure(.warning)
        try check(
            presentations.allSatisfy { $0.image == nil } && released == nil && pipeline.totalCost == 0
                && pipeline.pendingRequestCount == 0,
            "pressure invalidation also releases images held by visible presentation state")
        pipeline.handleMemoryPressure(.normal)
        try check(
            SelfTestWait.until {
                presentations.allSatisfy { $0.image != nil } && pipeline.pendingRequestCount == 0
            } && probe.started.count == 12, "presented images recover once after pressure ends")
        presentations.forEach { $0.disappear() }
        pipeline.removeAll()
        presentations.forEach { $0.refresh() }
        try check(
            presentations.allSatisfy { $0.image == nil } && pipeline.pendingRequestCount == 0,
            "disappeared rows release their images and ignore subsequent completion notifications")
    }

    private static func checkDefaultLoader() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardDeck-thumbnail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let corrupt = directory.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corrupt)
        try check(ThumbnailPipeline.loadThumbnail(at: corrupt) == nil, "invalid files are rejected")
        let oversized = directory.appendingPathComponent("oversized.png")
        _ = FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let file = try FileHandle(forWritingTo: oversized)
        try file.truncate(atOffset: UInt64(HistoryStore.maxImageBytes + 1))
        try file.close()
        try check(ThumbnailPipeline.loadThumbnail(at: oversized) == nil, "oversized source files are rejected")
        try check(
            ThumbnailPipeline.loadThumbnail(at: directory) == nil,
            "directories cannot be treated as image sources")
        try checkDisplaySizes(in: directory)
    }

    private static func checkDisplaySizes(in directory: URL) throws {
        // Exercise ImageIO output rather than mirroring the scale calculation.
        let cases: [(String, Int, Int, Int, Int, Int, Int, Int)] = [
            ("square", 1_200, 1_200, 1, 244, 244, 600, 600),
            ("portrait", 600, 1_800, 1, 81, 244, 200, 600),
            ("landscape", 2_400, 600, 1, 728, 182, 600, 150),
            ("rotated", 1_800, 600, 6, 81, 244, 200, 600),
            ("small", 80, 40, 1, 80, 40, 80, 40),
        ]
        for (name, width, height, orientation, listWidth, listHeight, previewWidth, previewHeight) in cases {
            let sourceURL = directory.appendingPathComponent(name + ".jpg")
            try autoreleasepool {
                let decoded = try fixture(width: width, height: height)
                guard
                    let destination = CGImageDestinationCreateWithURL(
                        sourceURL as CFURL, "public.jpeg" as CFString, 1, nil)
                else {
                    throw Failure.failed("sized image destination")
                }
                CGImageDestinationAddImage(
                    destination, decoded.image,
                    [kCGImagePropertyOrientation: orientation] as CFDictionary)
                try check(CGImageDestinationFinalize(destination), "sized image fixture encoding")
            }
            try autoreleasepool {
                guard let list = ThumbnailPipeline.loadThumbnail(at: sourceURL, variant: .list),
                    let preview = ThumbnailPipeline.loadThumbnail(at: sourceURL, variant: .preview)
                else {
                    throw Failure.failed("\(name) variants decode")
                }
                try check(
                    abs(list.image.width - listWidth) <= 1 && abs(list.image.height - listHeight) <= 1
                        && list.image.width <= 728 && list.image.height <= 244,
                    "\(name) list pixels fit the row without losing EXIF orientation")
                try check(
                    abs(preview.image.width - previewWidth) <= 1 && abs(preview.image.height - previewHeight) <= 1,
                    "\(name) keeps preview detail and does not upscale small inputs")
                try check(
                    list.cost == list.image.bytesPerRow * list.image.height
                        && preview.cost == preview.image.bytesPerRow * preview.image.height,
                    "\(name) cache costs use actual decoded storage")
                if name == "square" {
                    try check(
                        list.cost * 4 < preview.cost,
                        "square list thumbnails use less than one quarter of preview pixel storage")
                }
            }
        }
    }

    private static func checkVariants() throws {
        let list = try fixture()
        let preview = try fixture(width: 4, height: 4)
        let probe = VariantProbe(list: list, preview: preview)
        let budget = list.cost + preview.cost
        let pipeline = ThumbnailPipeline(
            cache: ThumbnailCache(maxCost: budget, maxCount: 2),
            maxPending: 2, observesMemoryPressure: false,
            loader: { _, variant in probe.load(variant) })
        defer { pipeline.setActive(false) }
        for _ in 0..<5 {
            _ = pipeline.image(forKey: "same", at: url("same"), variant: .list)
            _ = pipeline.image(forKey: "same", at: url("same"), variant: .preview)
        }
        try check(
            pipeline.pendingRequestCount == 2,
            "variants deduplicate independently while sharing the pending-work bound")
        _ = pipeline.image(forKey: "third", at: url("third"), variant: .preview)
        try check(pipeline.pendingRequestCount == 2, "mixed variants cannot exceed the shared request cap")
        try check(SelfTestWait.until { pipeline.pendingRequestCount == 0 }, "both variant requests complete")
        guard let listImage = pipeline.image(forKey: "same", at: url("same"), variant: .list),
            let previewImage = pipeline.image(forKey: "same", at: url("same"), variant: .preview)
        else {
            throw Failure.failed("both variants are cached independently")
        }
        try check(
            listImage.size.width == 2 && previewImage.size.width == 4 && listImage !== previewImage
                && probe.count(.list) == 1 && probe.count(.preview) == 1 && pipeline.totalCost == budget,
            "same-digest list and preview images never alias and use one combined cost budget")
        _ = pipeline.image(forKey: "third", at: url("third"), variant: .preview)
        try check(
            SelfTestWait.until { pipeline.pendingRequestCount == 0 } && pipeline.totalCost <= budget,
            "additional preview insertion evicts within the shared cache budget")

        pipeline.removeAll()
        let listPresentation = ThumbnailPresentation(provider: pipeline, key: "same", url: url("same"), variant: .list)
        let previewPresentation = ThumbnailPresentation(
            provider: pipeline, key: "same", url: url("same"), variant: .preview)
        pipeline.onChange = {
            listPresentation.refresh(); previewPresentation.refresh()
        }
        defer { pipeline.onChange = nil; listPresentation.disappear(); previewPresentation.disappear() }
        listPresentation.appear(); previewPresentation.appear()
        try check(
            SelfTestWait.until { listPresentation.image != nil && previewPresentation.image != nil },
            "presentations request the intended resolution")
        try check(
            listPresentation.image?.size.width == 2 && previewPresentation.image?.size.width == 4,
            "a list presentation cannot substitute for preview pixels")
        let beforeList = probe.count(.list), beforePreview = probe.count(.preview)
        listPresentation.disappear(); previewPresentation.disappear()
        pipeline.remove(forKey: "same")
        try check(pipeline.totalCost == 0, "removing a digest clears every cached variant")
        _ = pipeline.image(forKey: "same", at: url("same"), variant: .list)
        _ = pipeline.image(forKey: "same", at: url("same"), variant: .preview)
        try check(
            SelfTestWait.until { pipeline.pendingRequestCount == 0 } && probe.count(.list) == beforeList + 1
                && probe.count(.preview) == beforePreview + 1,
            "both removed variants decode again on explicit request")
    }

    private static func checkRepeatedInvalidation(_ decoded: DecodedThumbnail) throws {
        let probe = LoaderProbe(result: decoded, blockedNames: ["blocked"])
        let pipeline = ThumbnailPipeline(observesMemoryPressure: false, loader: { url, _ in probe.load(url) })
        defer { probe.release.signal(); pipeline.setActive(false) }
        for round in 0..<100 {
            let started = probe.started.count
            _ = pipeline.image(forKey: "running-\(round)", at: url("blocked"))
            try check(SelfTestWait.until { probe.started.count == started + 1 }, "round \(round): image decode starts")
            for index in 0..<100 {
                _ = pipeline.image(forKey: "queued-\(round)-\(index)", at: url("queued"))
            }
            try check(pipeline.pendingRequestCount == 8, "round \(round): thumbnail burst remains bounded")
            switch round % 3 {
            case 0:
                pipeline.setActive(false)
                pipeline.setActive(true)
            case 1:
                pipeline.handleMemoryPressure(.critical)
                pipeline.handleMemoryPressure(.normal)
            default: pipeline.removeAll()
            }
            _ = pipeline.image(forKey: "rejected-\(round)", at: url("rejected"))
            try check(pipeline.pendingRequestCount <= 8, "round \(round): invalidation cannot over-admit work")
            probe.release.signal()
            try check(
                SelfTestWait.until { pipeline.pendingRequestCount == 0 } && pipeline.totalCost == 0,
                "round \(round): cancelled generations cannot return stale images")
            let key = "recovered-\(round)"
            _ = pipeline.image(forKey: key, at: url(key))
            try check(
                SelfTestWait.until { pipeline.image(forKey: key, at: url(key)) != nil },
                "round \(round): image loading recovers")
            weak var image: NSImage?
            autoreleasepool { image = pipeline.image(forKey: key, at: url(key)) }
            pipeline.setActive(false)
            try check(
                image == nil && pipeline.totalCost == 0,
                "round \(round): hiding releases the recovered image")
            pipeline.setActive(true)
        }
        try check(probe.peak == 1, "repeated invalidation never creates overlapping decode work")
        print(
            "STRESS CASE: 100 thumbnail lifecycle rounds / 10000 burst requests / stale-result rejection / pressure-close-clear recovery"
        )
    }

    private static func fixture(width: Int = 2, height: Int = 2) throws -> DecodedThumbnail {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = context.makeImage()
        else { throw Failure.failed("image fixture") }
        return DecodedThumbnail(image: image, cost: image.bytesPerRow * image.height)
    }

    private static func url(_ name: String) -> URL { URL(fileURLWithPath: "/private/tmp/\(name)") }
    private static func check(_ passed: Bool, _ message: String) throws {
        if !passed { throw Failure.failed(message) }
    }
    private enum Failure: Error { case failed(String) }
}

private final class VariantProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let list: DecodedThumbnail
    private let preview: DecodedThumbnail
    private var counts: [ThumbnailVariant: Int] = [:]

    init(list: DecodedThumbnail, preview: DecodedThumbnail) {
        self.list = list
        self.preview = preview
    }

    func load(_ variant: ThumbnailVariant) -> DecodedThumbnail {
        lock.withLock { counts[variant, default: 0] += 1 }
        return variant == .list ? list : preview
    }

    func count(_ variant: ThumbnailVariant) -> Int { lock.withLock { counts[variant, default: 0] } }
}

/// A locked probe keeps test observations independent of the worker's execution timing.
private final class LoaderProbe: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let result: DecodedThumbnail
    private let blockedNames: Set<String>
    private let failedNames: Set<String>
    private var names: [String] = []
    private var activeCount = 0
    private var finishedCount = 0
    private var peakCount = 0
    private var mainThread = false

    var started: [String] { lock.withLock { names } }
    var peak: Int { lock.withLock { peakCount } }
    var finished: Int { lock.withLock { finishedCount } }
    var ranOnMain: Bool { lock.withLock { mainThread } }

    init(result: DecodedThumbnail, blockedNames: Set<String> = [], failedNames: Set<String> = []) {
        self.result = result
        self.blockedNames = blockedNames
        self.failedNames = failedNames
    }

    func load(_ url: URL) -> DecodedThumbnail? {
        let name = url.lastPathComponent
        lock.withLock {
            names.append(name)
            activeCount += 1
            peakCount = max(peakCount, activeCount)
            mainThread = mainThread || Thread.isMainThread
        }
        if blockedNames.contains(name) { _ = release.wait(timeout: .now() + 5) }
        lock.withLock {
            activeCount -= 1; finishedCount += 1
        }
        return failedNames.contains(name) ? nil : result
    }
}
