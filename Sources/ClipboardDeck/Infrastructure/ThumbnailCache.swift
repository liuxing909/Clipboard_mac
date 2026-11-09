import AppKit

/// Bounds the image data retained by this cache, not the application's total memory.
/// Callers supply the decoded CGImage's bytesPerRow × height as the cost.
@MainActor
final class ThumbnailCache {
    private struct Entry {
        let image: NSImage
        let cost: Int
    }

    private let maxCost: Int
    private let maxCount: Int
    private var entries: [String: Entry] = [:]
    // At most 32 entries by default, so a small ordered array keeps the LRU simple.
    private var recency: [String] = []
    private(set) var totalCost = 0
    var count: Int { entries.count }

    init(maxCost: Int = 12 * 1024 * 1024, maxCount: Int = 32) {
        self.maxCost = max(0, maxCost)
        self.maxCount = max(0, maxCount)
    }

    func image(forKey key: String) -> NSImage? {
        guard let entry = entries[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.image
    }

    func insert(_ image: NSImage, forKey key: String, cost: Int) {
        // A replacement must not leave an older image under the same key.
        remove(forKey: key)
        guard cost > 0, cost <= maxCost, maxCount > 0 else { return }
        // Subtraction avoids overflowing Int for an unusually large supplied cost.
        while totalCost > maxCost - cost || entries.count >= maxCount {
            guard let oldest = recency.first else { break }
            remove(forKey: oldest)
        }
        entries[key] = Entry(image: image, cost: cost)
        recency.append(key)
        totalCost += cost
    }

    func remove(forKey key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalCost -= entry.cost
        recency.removeAll { $0 == key }
    }

    func removeAll() {
        entries.removeAll()
        recency.removeAll()
        totalCost = 0
    }
}
