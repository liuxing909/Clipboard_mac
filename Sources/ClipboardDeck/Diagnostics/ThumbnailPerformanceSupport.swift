import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// Compares the same direct ImageIO loader with the old 600 px policy and the
/// list-specific policy. Uses generated images only, without a pasteboard or UI.
@MainActor
enum ThumbnailPerformanceSupport {
    private struct Fixture {
        let name: String
        let width: Int
        let height: Int
        let url: URL
    }

    private struct Measurement {
        let milliseconds: Double
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let cost: Int

        var json: [String: Any] {
            [
                "decode_ms": milliseconds, "output_width": width, "output_height": height,
                "bytes_per_row": bytesPerRow, "decoded_buffer_bytes": cost,
            ]
        }
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClipboardDeck-thumbnail-benchmark-" + UUID().uuidString,
                isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = [
            Fixture(name: "square", width: 2_000, height: 2_000, url: root.appendingPathComponent("square.png")),
            Fixture(name: "portrait", width: 1_200, height: 2_400, url: root.appendingPathComponent("portrait.png")),
            Fixture(name: "landscape", width: 2_400, height: 1_200, url: root.appendingPathComponent("landscape.png")),
        ]
        // Generation and encoding are deliberately outside the measured intervals.
        for fixture in fixtures { try autoreleasepool { try generate(fixture) } }

        var scenarios: [[String: Any]] = []
        for fixture in fixtures {
            // Warm both paths once, including local file access and ImageIO startup.
            _ = try measure(fixture.url, variant: .preview)
            _ = try measure(fixture.url, variant: .list)
            var baseline: [Measurement] = []
            var list: [Measurement] = []
            var runs: [[String: Any]] = []
            for iteration in 1...5 {
                let old: Measurement
                let current: Measurement
                if iteration.isMultiple(of: 2) {
                    current = try measure(fixture.url, variant: .list)
                    old = try measure(fixture.url, variant: .preview)
                } else {
                    old = try measure(fixture.url, variant: .preview)
                    current = try measure(fixture.url, variant: .list)
                }
                baseline.append(old)
                list.append(current)
                runs.append([
                    "iteration": iteration,
                    "first_policy": iteration.isMultiple(of: 2) ? "list" : "baseline_600px",
                    "baseline_600px": old.json,
                    "list": current.json,
                ])
            }
            let oldSummary = summary(baseline)
            let newSummary = summary(list)
            scenarios.append([
                "name": fixture.name,
                "source_width": fixture.width,
                "source_height": fixture.height,
                "source_png_bytes": try fixture.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                "runs": runs,
                "baseline_600px": oldSummary,
                "list": newSummary,
                "decoded_buffer_reduction_percent":
                    100 * (1 - Double(list[0].cost) / Double(baseline[0].cost)),
            ])
        }

        // Each call holds 20 distinct decode results until all costs have been
        // summed. Baseline images are released before measuring the list policy.
        let oldRetained = try retainedBatch(fixtures[0].url, variant: .preview)
        let newRetained = try retainedBatch(fixtures[0].url, variant: .list)
        let results: [String: Any] = [
            "scope":
                "direct thumbnail loader microbenchmark; generated PNG files; no application window, pasteboard, user history or cache",
            "policies": [
                "baseline_600px": "ThumbnailVariant.preview: the previous longest-edge 600 px policy",
                "list":
                    "ThumbnailVariant.list: aspect-fit to the list pixel bounds; output dimensions are read from each decoded image",
            ],
            "repeats_per_scenario": 5,
            "warmups_per_policy_per_scenario": 1,
            "scenarios": scenarios,
            "twenty_square_decodes_retained": [
                "baseline_600px": oldRetained,
                "list": newRetained,
            ],
            "twenty_key_cache_revisit": [
                "baseline_600px": try cacheRevisit(fixtures[0].url, variant: .preview),
                "list": try cacheRevisit(fixtures[0].url, variant: .list),
            ],
            "limitations": [
                "Timing measures serial direct ImageIO decoding, without production queue scheduling, cache lookup, NSImage creation or SwiftUI rendering.",
                "Generated image creation and PNG encoding are excluded. Local files and ImageIO are warmed before the five alternating-order runs.",
                "Decoded buffer cost is bytesPerRow multiplied by height; it is not process physical memory, allocator overhead or a peak-memory measurement.",
                "The retained batch decodes the same square source 20 separate times and retains all results. It does not model cache deduplication or 20 unique photos.",
                "Cache revisit uses 20 distinct synthetic keys backed by the same fixture, the production 12 MiB / 32-entry cache, and two forward passes; it excludes scheduling/UI and does not predict other scroll patterns.",
                "Different image contents, compression, bit depth, hardware and system load can change timings. The new list policy and the old policy intentionally produce different output sizes.",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func measure(_ url: URL, variant: ThumbnailVariant) throws -> Measurement {
        try autoreleasepool {
            let start = ProcessInfo.processInfo.systemUptime
            guard let result = ThumbnailPipeline.loadThumbnail(at: url, variant: variant) else {
                throw Failure.decode(variant.rawValue)
            }
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            let actualCost = result.image.bytesPerRow * result.image.height
            guard result.cost == actualCost, actualCost > 0 else { throw Failure.invalidCost }
            return Measurement(
                milliseconds: elapsed, width: result.image.width,
                height: result.image.height, bytesPerRow: result.image.bytesPerRow,
                cost: actualCost)
        }
    }

    private static func summary(_ samples: [Measurement]) -> [String: Any] {
        let sorted = samples.map(\.milliseconds).sorted()
        let first = samples[0]
        return [
            "median_decode_ms": sorted[sorted.count / 2],
            "minimum_decode_ms": sorted[0], "maximum_decode_ms": sorted[sorted.count - 1],
            "output_width": first.width, "output_height": first.height,
            "bytes_per_row": first.bytesPerRow, "decoded_buffer_bytes": first.cost,
        ]
    }

    private static func retainedBatch(_ url: URL, variant: ThumbnailVariant) throws -> [String: Any] {
        try autoreleasepool {
            var images: [CGImage] = []
            images.reserveCapacity(20)
            var total = 0
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<20 {
                let result = try autoreleasepool { () throws -> DecodedThumbnail in
                    guard let result = ThumbnailPipeline.loadThumbnail(at: url, variant: variant) else {
                        throw Failure.decode(variant.rawValue)
                    }
                    return result
                }
                total += result.image.bytesPerRow * result.image.height
                images.append(result.image)
            }
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            return withExtendedLifetime(images) {
                [
                    "decoded_images_retained": images.count, "total_decode_ms": elapsed,
                    "total_decoded_buffer_bytes": total,
                    "total_decoded_buffer_mib": Double(total) / 1_048_576,
                ]
            }
        }
    }

    private static func generate(_ fixture: Fixture) throws {
        guard
            let context = CGContext(
                data: nil, width: fixture.width, height: fixture.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw Failure.fixture
        }
        let width = CGFloat(fixture.width), height = CGFloat(fixture.height)
        context.setFillColor(CGColor(red: 0.12, green: 0.25, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for index in 0..<32 {
            let fraction = CGFloat(index) / 31
            context.setFillColor(
                CGColor(
                    red: fraction, green: 1 - fraction,
                    blue: 0.3 + fraction * 0.5, alpha: 1))
            context.fill(
                CGRect(
                    x: width * fraction * 0.8, y: height * fraction * 0.8,
                    width: width * 0.2, height: height * 0.2))
        }
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                fixture.url as CFURL,
                "public.png" as CFString, 1, nil)
        else {
            throw Failure.fixture
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.fixture }
    }

    private static func cacheRevisit(_ url: URL, variant: ThumbnailVariant) throws -> [String: Any] {
        let cache = ThumbnailCache()
        var passes: [[String: Any]] = []
        for pass in 1...2 {
            var hits = 0, decodes = 0
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<20 {
                try autoreleasepool {
                    let key = "synthetic-\(index)"
                    if cache.image(forKey: key) != nil { hits += 1; return }
                    guard let decoded = ThumbnailPipeline.loadThumbnail(at: url, variant: variant) else {
                        throw Failure.decode(variant.rawValue)
                    }
                    let image = NSImage(
                        cgImage: decoded.image,
                        size: NSSize(width: decoded.image.width, height: decoded.image.height))
                    cache.insert(image, forKey: key, cost: decoded.cost)
                    decodes += 1
                }
            }
            passes.append([
                "pass": pass, "hits": hits, "decodes": decodes,
                "elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1_000,
                "cached_items": cache.count, "cache_cost_bytes": cache.totalCost,
            ])
        }
        return ["passes": passes, "cache_budget_bytes": 12 * 1_048_576, "cache_count_limit": 32]
    }

    private enum Failure: Error { case fixture, decode(String), invalidCost }
}
