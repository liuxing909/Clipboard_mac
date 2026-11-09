import AppKit
import ClipboardCore
import Darwin

/// A reproducible model benchmark. It never reads the general pasteboard or opens a window.
@MainActor
enum PerformanceSupport {
    static func run() throws {
        let identifier = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardDeck-benchmark-" + identifier, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: NSPasteboard.Name("ClipboardDeck-benchmark-" + identifier))
        defer { board.releaseGlobally() }
        let suiteName = "app.clipboarddeck.benchmark." + identifier
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw Failure.defaultsUnavailable }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(200, forKey: "historyLimit")
        let model = AppModel(
            directory: directory, pasteboard: board, defaults: defaults,
            frontmostApplication: { nil })
        defer { model.stopMonitoring() }
        guard let store = model.store else { throw Failure.storeUnavailable }

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try autoreleasepool {
            for index in 0..<200 {
                let prefix = String(format: "entry-%03d ", index)
                let text =
                    prefix
                    + String(repeating: "示例内容用于测量剪贴板搜索导航性能。", count: 20)
                    .prefix(256 - prefix.count)
                try store.add(.text(text), sourceApp: "Benchmark", at: fixedDate.addingTimeInterval(Double(index)))
            }
            model.refresh()
        }

        var navigationCount = 0
        let navigationStart = uptime()
        autoreleasepool {
            for index in 0..<1_000 {
                navigationCount += model.visibleEntries.count
                model.moveSelection(index % 398 < 199 ? 1 : -1)
            }
        }
        let navigationMS = (uptime() - navigationStart) * 1_000

        var searchMatches = 0
        let searchStart = uptime()
        autoreleasepool {
            for index in 0..<100 {
                // The same deterministic sequence is used in every run. Different
                // queries exercise actual filtering instead of an unchanged cache.
                model.query = String(format: "entry-%03d", index)
                searchMatches += model.visibleEntries.count
            }
            model.query = ""
        }
        let searchMS = (uptime() - searchStart) * 1_000

        model.startMonitoring()
        let idle = try measureIdle(seconds: 10)
        model.isPaused = true
        let paused = try measureIdle(seconds: 5)
        model.stopMonitoring()

        let beforeImages = try footprintBytes()
        let thumbnailStart = uptime()
        var thumbnailsLoaded = 0
        try autoreleasepool {
            for index in 0..<20 {
                let data = try syntheticPNG(index: index)
                try store.add(
                    .image(png: data, width: 600, height: 600), sourceApp: "Benchmark",
                    at: fixedDate.addingTimeInterval(Double(200 + index)))
            }
            model.refresh()
            for entry in model.entries where entry.kind == .image {
                if SelfTestWait.until({ model.image(for: entry) != nil }) { thumbnailsLoaded += 1 }
            }
        }
        let thumbnailMS = (uptime() - thumbnailStart) * 1_000
        let afterImages = try footprintBytes()

        let results: [String: Any] = [
            "scope": "synthetic model; no application window, general clipboard, or global hotkeys",
            "memory_metric":
                "process task_vm_info.phys_footprint; includes AppKit runtime, excludes a real application window",
            "cpu_metric": "process CPU seconds / elapsed seconds * 100; 100 percent equals one CPU core",
            "initial_text_entries": 200,
            "characters_per_text": 256,
            "navigation_1000_ms": navigationMS,
            "navigation_entries_observed": navigationCount,
            "search_100_distinct_queries_ms": searchMS,
            "search_matches_observed": searchMatches,
            "monitoring_idle": idle,
            "paused_idle": paused,
            "image_cache": [
                "images_added": 20,
                "source_image_pixels": "600x600",
                "thumbnails_loaded": thumbnailsLoaded,
                "capture_and_cache_ms": thumbnailMS,
                "phys_footprint_before_mib": Double(beforeImages) / 1_048_576,
                "phys_footprint_after_mib": Double(afterImages) / 1_048_576,
            ],
        ]
        let output = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }

    private static func measureIdle(seconds: TimeInterval) throws -> [String: Double] {
        let cpuStart = try processCPUSeconds()
        let wallStart = uptime()
        // A single sentinel keeps the run loop alive even when pausing removes the
        // model's polling timer. It does not add periodic benchmark wakeups.
        let sentinel = Timer(timeInterval: seconds, repeats: false) { _ in }
        RunLoop.main.add(sentinel, forMode: .default)
        defer { sentinel.invalidate() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        let elapsed = uptime() - wallStart
        let cpu = try processCPUSeconds() - cpuStart
        return [
            "elapsed_seconds": elapsed,
            "process_cpu_seconds": cpu,
            "process_cpu_percent": elapsed > 0 ? cpu / elapsed * 100 : 0,
            "phys_footprint_mib": Double(try footprintBytes()) / 1_048_576,
        ]
    }

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func processCPUSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw Failure.cpuMeasurementFailed(errno) }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func footprintBytes() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw Failure.memoryMeasurementFailed(result) }
        return info.phys_footprint
    }

    private static func syntheticPNG(index: Int) throws -> Data {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 600,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let pixels = bitmap.bitmapData
        else { throw HistoryError.invalidImage }
        for y in 0..<600 {
            for x in 0..<600 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = UInt8((x + index * 11) % 256)
                pixels[offset + 1] = UInt8((y + index * 7) % 256)
                pixels[offset + 2] = UInt8((x + y + index * 13) % 256)
                pixels[offset + 3] = 255
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw HistoryError.invalidImage }
        return data
    }

    private enum Failure: Error {
        case defaultsUnavailable, storeUnavailable
        case cpuMeasurementFailed(Int32)
        case memoryMeasurementFailed(kern_return_t)
    }
}
