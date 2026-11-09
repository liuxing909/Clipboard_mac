import AppKit
import Darwin

/// Repeats isolated behavioral checks in one process to exercise teardown and reuse.
/// Memory samples describe this synthetic test process, not normal application usage.
@MainActor
enum StressTestSupport {
    enum Suite: String, CaseIterable {
        case all, formats, office, model, ui, worker, thumbnails, hotkeys
        case formatFuzz = "format-fuzz"
    }

    static func run(rounds: Int, suite: Suite = .all) throws {
        let started = ProcessInfo.processInfo.systemUptime
        var samples: [[String: Any]] = []
        for round in 1...rounds {
            let roundStart = ProcessInfo.processInfo.systemUptime
            try autoreleasepool {
                try runSuite(suite)
            }
            // Drain deferred AppKit and cancellation callbacks before the next round.
            autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            var heap = malloc_statistics_t()
            malloc_zone_statistics(nil, &heap)
            let sample: [String: Any] = [
                "round": round,
                "elapsed_seconds": ProcessInfo.processInfo.systemUptime - roundStart,
                "physical_footprint_mib": Double(try footprintBytes()) / 1_048_576,
                "appkit_window_count": NSApplication.shared.windows.count,
                "malloc_in_use_bytes": heap.size_in_use,
                "malloc_allocated_bytes": heap.size_allocated,
                "malloc_live_blocks": heap.blocks_in_use,
            ]
            samples.append(sample)
            print("STRESS ROUND \(round)/\(rounds): PASS")
            fflush(stdout)
        }
        let summary: [String: Any] = [
            "scope": "repeated isolated self-tests in one process; synthetic content and private pasteboards",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "development",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "rounds": rounds,
            "suite": suite.rawValue,
            "elapsed_seconds": ProcessInfo.processInfo.systemUptime - started,
            "memory_metric": "task_vm_info.phys_footprint after each round; not a GUI memory limit or leak proof",
            "samples": samples,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print("STRESS SUMMARY\n" + String(decoding: data, as: UTF8.self))
    }

    private static func runSuite(_ suite: Suite) throws {
        switch suite {
        case .all: try PreviewSupport.selfTest()
        case .formats: try FormatSelfTests.run()
        case .formatFuzz: try FormatStressSelfTests.run()
        case .office: try OfficeFormatSelfTests.run()
        case .ui: try LegacyHistoryView.selfTest()
        case .worker: try ClipboardWorkSchedulerSelfTests.run()
        case .thumbnails: try ThumbnailPipelineSelfTests.run()
        case .hotkeys: try HotkeySelfTests.run()
        case .model:
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ClipboardDeck-model-probe-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            try AppModelSelfTests.run(directory: directory, board: board)
        }
    }

    private static func footprintBytes() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw PreviewSupport.TestError.failed("stress memory sampling failed: \(status)")
        }
        return info.phys_footprint
    }
}
