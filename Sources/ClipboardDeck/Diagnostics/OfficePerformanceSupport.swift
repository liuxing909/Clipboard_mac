import AppKit
import ClipboardCore
import Darwin

/// Exercises the application's real asynchronous capture/copy paths with isolated,
/// synthetic content. No general pasteboard, user history or external editor is used.
@MainActor
enum OfficePerformanceSupport {
    private struct Fixture {
        let name: String
        let description: String
        let kind: ClipKind
        let representations: [NSPasteboard.PasteboardType: Data]
        var byteCount: Int { representations.values.reduce(0) { $0 + $1.count } }
    }

    static func run() throws {
        let identifier = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardDeck-office-benchmark-" + identifier, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let suiteName = "app.clipboarddeck.office-benchmark." + identifier
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw Failure.check("isolated defaults") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(200, forKey: "historyLimit")

        // Fixture generation is intentionally outside all measured intervals.
        let fixtures = try autoreleasepool { try makeFixtures() }
        var scenarios: [[String: Any]] = []
        for fixture in fixtures {
            let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
            let model = AppModel(
                directory: directory.appendingPathComponent(fixture.name),
                pasteboard: board, defaults: defaults,
                poller: ExplicitCapturePoller(), processing: scheduler,
                frontmostApplication: { nil })
            defer { model.stopMonitoring(); model.cancelPreparedCopy() }
            guard let store = model.store else { throw Failure.check("isolated history store") }
            try autoreleasepool {
                let start = Date(timeIntervalSince1970: 1_700_000_000)
                for index in 0..<200 {
                    try store.add(
                        .text("fixture-\(index) " + String(repeating: "示例文字", count: 40)),
                        sourceApp: "Benchmark", at: start.addingTimeInterval(Double(index)))
                }
                model.refresh()
            }
            model.startMonitoring()  // Establish the baseline before writing the fixture.
            var runs: [[String: Any]] = []
            for iteration in 1...3 {
                let run: [String: Any] = try autoreleasepool {
                    let item = NSPasteboardItem()
                    for (type, data) in fixture.representations {
                        guard item.setData(data, forType: type) else { throw Failure.check("fixture representation") }
                    }
                    board.clearContents()
                    guard board.writeObjects([item]) else { throw Failure.check("fixture pasteboard write") }

                    let sourceItemTypes = board.pasteboardItems?.first?.types.map(\.rawValue) ?? []
                    let sourceBoardTypes = (board.types ?? []).map(\.rawValue)
                    let samples = try Sampler()
                    defer { samples.stop() }
                    let captureStart = uptime()
                    model.capturePendingCopy()
                    let captureReturn = uptime()
                    guard SelfTestWait.until(timeout: 15, { scheduler.outstandingCount == 0 }),
                        let entry = model.entries.first,
                        entry.kind == fixture.kind, entry.copyCount == iteration
                    else {
                        throw Failure.check(
                            "capture did not persist expected fixture: \(fixture.name), \(model.toast ?? "no error")")
                    }
                    let captureFinished = uptime()
                    if fixture.name == "rtfd_inline_image" {
                        guard entry.richTextTypes?.contains(HistoryStore.rtfdType) == true else {
                            throw Failure.check("RTFD attachment representation was not retained")
                        }
                    }
                    var pasteSucceeded: Bool?
                    let pasteStart = uptime()
                    model.copyPrepared(entry) { pasteSucceeded = $0 }
                    let pasteReturn = uptime()
                    guard SelfTestWait.until(timeout: 15, { pasteSucceeded != nil }), pasteSucceeded == true else {
                        throw Failure.check("prepared copy failed: \(fixture.name), \(model.toast ?? "no error")")
                    }
                    let pasteFinished = uptime()
                    guard scheduler.outstandingCount == 0, !model.isPreparingCopy else {
                        throw Failure.check("worker did not release completed work")
                    }
                    samples.stop()
                    let metrics = try samples.metrics()
                    return [
                        "iteration": iteration,
                        "source_item_types": sourceItemTypes,
                        "source_board_types": sourceBoardTypes,
                        "capture_main_call_ms": (captureReturn - captureStart) * 1_000,
                        "capture_until_persisted_ms": (captureFinished - captureStart) * 1_000,
                        "copy_main_call_ms": (pasteReturn - pasteStart) * 1_000,
                        "copy_until_commit_ms": (pasteFinished - pasteStart) * 1_000,
                        "history_entries": model.entries.count,
                        "stored_payload_bytes": entry.byteCount,
                        "restored_representations": (board.types ?? []).map(\.rawValue).sorted(),
                        "sampling": metrics,
                    ]
                }
                runs.append(run)
            }
            scenarios.append([
                "name": fixture.name,
                "description": fixture.description,
                "source_representation_bytes": fixture.byteCount,
                "runs": runs,
            ])
        }
        let results: [String: Any] = [
            "scope":
                "synthetic model; 200 short history entries; explicit capture; no external editor, application window, general clipboard, global hotkeys or user history",
            "repeats_per_scenario": 3,
            "timer_interval_ms": 5,
            "memory_metric": "process task_vm_info.phys_footprint; 5 ms main-run-loop samples plus boundary samples",
            "limitations": [
                "Not a Microsoft Word/WPS compatibility test and not a full GUI memory benchmark.",
                "Sampled peak is a lower bound: brief allocations or allocations during a blocked main thread can be missed.",
                "Baselines include fixtures and warmed AppKit/runtime state; scenarios run sequentially in one process.",
                "Timer gaps include the 5 ms timer interval, run-loop scheduling and sampling overhead; they are not frame render times.",
                "Completion times include up to approximately 5 ms of run-loop polling granularity; fixture generation and initial history seeding are excluded.",
            ],
            "configured_limits": [
                "max_outstanding_jobs": 2,
                "worker_concurrency": 1,
                "retained_input_budget_mib": 50,
                "snapshot_limit_mib": ClipboardAccess.maxSnapshotBytes / 1_048_576,
                "prepared_output_limit_mib": ClipboardAccess.maxPreparedWriteBytes / 1_048_576,
                "rich_text_limit_mib": HistoryStore.maxRichTextBytes / 1_048_576,
                "image_pixel_limit": HistoryStore.maxImagePixels,
            ],
            "scenarios": scenarios,
        ]
        let output = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }

    private static func makeFixtures() throws -> [Fixture] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.firstLineHeadIndent = 12
        paragraph.lineSpacing = 4
        let text = String(repeating: "办公文档格式测试：中文 English，粗体、字号和段落。\n", count: 30)
        let rich = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 19),
                .foregroundColor: NSColor(srgbRed: 0.2, green: 0.3, blue: 0.7, alpha: 1),
                .paragraphStyle: paragraph,
            ])
        guard let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) else {
            throw Failure.check("RTF fixture")
        }
        let html = Data(
            ("<html><body><p style=\"font-size:19pt;color:#334db3\"><b>"
                + text.replacingOccurrences(of: "\n", with: "<br>") + "</b></p></body></html>").utf8)
        let office = Fixture(
            name: "rtf_html",
            description: "30 Chinese/English paragraphs, 19 pt bold font, paragraph spacing, RTF + HTML + plain text",
            kind: .richText, representations: [.rtf: rtf, .html: html, .string: Data(text.utf8)])

        let inlineImage = try imageData(width: 128, height: 96, type: .png)
        let wrapper = FileWrapper(regularFileWithContents: inlineImage)
        wrapper.preferredFilename = "benchmark-image.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        rich.append(NSAttributedString(attachment: attachment))
        rich.append(NSAttributedString(string: "\n图片后的文字。"))
        guard let rtfd = rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) else {
            throw Failure.check("RTFD fixture")
        }
        let attached = Fixture(
            name: "rtfd_inline_image", description: "formatted paragraphs plus one embedded 128 x 96 PNG image",
            kind: .richText, representations: [.rtfd: rtfd, .string: Data(rich.string.utf8)])

        let jpeg = try imageData(width: 2_000, height: 1_500, type: .jpeg)
        let image = Fixture(
            name: "jpeg_3mp",
            description:
                "2000 x 1500 static JPEG; capture normalizes to PNG and copy prepares supported image representations",
            kind: .image, representations: [NSPasteboard.PasteboardType("public.jpeg"): jpeg])
        return [office, attached, image]
    }

    private static func imageData(width: Int, height: Int, type: NSBitmapImageRep.FileType) throws -> Data {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData
        else {
            throw Failure.check("image fixture allocation")
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = UInt8(x % 256)
                pixels[offset + 1] = UInt8(y % 256)
                pixels[offset + 2] = UInt8((x + y) % 256)
                pixels[offset + 3] = 255
            }
        }
        guard let bytes = bitmap.representation(using: type, properties: [.compressionFactor: 0.85]) else {
            throw Failure.check("image fixture encoding")
        }
        return bytes
    }

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func footprintBytes() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw Failure.memoryMeasurement(result) }
        return info.phys_footprint
    }

    @MainActor
    private final class Sampler {
        private let baseline: UInt64
        private var peak: UInt64
        private var end: UInt64
        private var previousTick: TimeInterval
        private var largestGap: TimeInterval = 0
        private var ticks = 0
        private var measurementError: Error?
        private var timer: Timer?

        init() throws {
            baseline = try OfficePerformanceSupport.footprintBytes()
            peak = baseline
            end = baseline
            previousTick = OfficePerformanceSupport.uptime()
            let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample(isTimerTick: true) }
            }
            self.timer = timer
            timer.tolerance = 0
            RunLoop.main.add(timer, forMode: .default)
        }

        func stop() {
            guard let timer else { return }
            timer.invalidate()
            self.timer = nil
            sample(isTimerTick: false)
        }

        private func sample(isTimerTick: Bool) {
            let now = OfficePerformanceSupport.uptime()
            largestGap = max(largestGap, now - previousTick)
            previousTick = now
            if isTimerTick { ticks += 1 }
            do { end = try OfficePerformanceSupport.footprintBytes(); peak = max(peak, end) } catch {
                measurementError = error
            }
        }

        func metrics() throws -> [String: Any] {
            if let measurementError { throw measurementError }
            return [
                "baseline_phys_footprint_mib": Double(baseline) / 1_048_576,
                "sampled_peak_phys_footprint_mib": Double(peak) / 1_048_576,
                "end_phys_footprint_mib": Double(end) / 1_048_576,
                "max_main_timer_gap_ms": largestGap * 1_000,
                "timer_samples": ticks,
            ]
        }
    }

    @MainActor
    private final class ExplicitCapturePoller: ClipboardPolling {
        private(set) var isRunning = false
        func start(_ tick: @escaping @MainActor () -> Void) { isRunning = true }
        func stop() { isRunning = false }
    }

    private enum Failure: Error {
        case check(String)
        case memoryMeasurement(kern_return_t)
    }
}
