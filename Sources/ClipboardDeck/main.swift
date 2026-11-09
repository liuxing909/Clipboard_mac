import AppKit
import Foundation

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let arguments = CommandLine.arguments

    do {
        if arguments.count == 3 && arguments[1] == "--render-preview" {
            try PreviewSupport.render(to: URL(fileURLWithPath: arguments[2]))
        } else if arguments.count == 3 && arguments[1] == "--render-legacy-preview" {
            try PreviewSupport.render(to: URL(fileURLWithPath: arguments[2]), legacy: true)
        } else if arguments.count == 3 && arguments[1] == "--render-hotkey-warning" {
            try PreviewSupport.render(to: URL(fileURLWithPath: arguments[2]), hotkeyWarning: true)
        } else if arguments.count == 3 && arguments[1] == "--make-icon" {
            try PreviewSupport.makeIcon(to: URL(fileURLWithPath: arguments[2]))
        } else if arguments.count >= 2 && arguments[1] == "--stress-test" {
            guard arguments.count <= 4, let rounds = Int(arguments.count >= 3 ? arguments[2] : "20"),
                (1...100).contains(rounds),
                let suite = StressTestSupport.Suite(rawValue: arguments.count == 4 ? arguments[3] : "all")
            else {
                throw PreviewSupport.TestError.failed(
                    "Usage: --stress-test [rounds: 1...100] ["
                        + StressTestSupport.Suite.allCases.map(\.rawValue).joined(separator: "|") + "]")
            }
            try StressTestSupport.run(rounds: rounds, suite: suite)
        } else if arguments.contains("--self-test") {
            try PreviewSupport.selfTest()
        } else if arguments.contains("--self-test-formats") {
            try FormatSelfTests.run()
        } else if arguments.contains("--self-test-hotkey-system") {
            try HotkeySelfTests.runSystemRegistration()
        } else if arguments.contains("--benchmark") {
            try PerformanceSupport.run()
        } else if arguments.contains("--benchmark-office") {
            try OfficePerformanceSupport.run()
        } else if arguments.contains("--benchmark-thumbnails") {
            try ThumbnailPerformanceSupport.run()
        } else {
            let delegate = AppController()
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        }
    } catch {
        fputs("ClipboardDeck: \(error)\n", stderr)
        exit(1)
    }
}
