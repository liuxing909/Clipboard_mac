import AppKit

@MainActor
enum ThumbnailCacheSelfTests {
    static func run() throws {
        let first = NSImage(size: NSSize(width: 1, height: 1))
        let second = NSImage(size: NSSize(width: 1, height: 1))
        let third = NSImage(size: NSSize(width: 1, height: 1))
        let cache = ThumbnailCache(maxCost: 8, maxCount: 3)
        cache.insert(first, forKey: "first", cost: 4)
        cache.insert(second, forKey: "second", cost: 4)
        try check(cache.totalCost == 8 && cache.count == 2, "pixel costs are counted")
        try check(cache.image(forKey: "first") === first, "cached image is returned")
        cache.insert(third, forKey: "third", cost: 4)
        try check(
            cache.image(forKey: "second") == nil && cache.image(forKey: "first") === first
                && cache.image(forKey: "third") === third && cache.totalCost == 8,
            "a hit makes the image recent, so the older image is evicted")

        cache.insert(second, forKey: "oversized", cost: 9)
        try check(
            cache.image(forKey: "oversized") == nil && cache.count == 2 && cache.totalCost == 8,
            "an oversized image is not cached and does not evict useful images")
        cache.insert(second, forKey: "third", cost: 2)
        try check(
            cache.image(forKey: "third") === second && cache.count == 2 && cache.totalCost == 6,
            "replacement updates the image and its cost without adding an entry")
        cache.insert(third, forKey: "third", cost: 9)
        try check(
            cache.image(forKey: "third") == nil && cache.count == 1 && cache.totalCost == 4,
            "an uncacheable replacement does not leave a stale image")
        cache.remove(forKey: "missing")
        cache.remove(forKey: "first")
        try check(cache.count == 0 && cache.totalCost == 0, "removal releases the recorded cost")

        let countBounded = ThumbnailCache(maxCost: 100, maxCount: 2)
        countBounded.insert(first, forKey: "first", cost: 4)
        countBounded.insert(second, forKey: "second", cost: 4)
        countBounded.insert(third, forKey: "third", cost: 4)
        try check(
            countBounded.image(forKey: "first") == nil && countBounded.count == 2 && countBounded.totalCost == 8,
            "the count bound also evicts the least recent image")
        countBounded.removeAll()
        try check(
            countBounded.count == 0 && countBounded.totalCost == 0 && countBounded.image(forKey: "third") == nil,
            "clearing releases all cached entries")

        weak var releasedImage: NSImage?
        autoreleasepool {
            let temporary = NSImage(size: NSSize(width: 1, height: 1))
            releasedImage = temporary
            cache.insert(temporary, forKey: "temporary", cost: 4)
        }
        try check(releasedImage != nil, "cache retains its image")
        cache.removeAll()
        try check(releasedImage == nil, "clearing releases the cache's image reference")

        cache.insert(first, forKey: "unknown-cost", cost: 0)
        cache.insert(first, forKey: "negative-cost", cost: -1)
        let disabled = ThumbnailCache(maxCost: 0)
        disabled.insert(first, forKey: "first", cost: 4)
        try check(
            cache.count == 0 && disabled.count == 0,
            "unknown costs and a disabled budget do not retain images")
        print(
            "PASS: thumbnail cache byte budget / LRU hits / count limit / replacement / oversized rejection / image release"
        )
    }

    private static func check(_ passed: Bool, _ message: String) throws {
        if !passed { throw Failure.failed(message) }
    }

    private enum Failure: Error { case failed(String) }
}
