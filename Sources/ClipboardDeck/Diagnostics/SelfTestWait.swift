import Foundation

/// Bounded run-loop pumping for isolated command-line probes, never used by the UI.
@MainActor
enum SelfTestWait {
    static func until(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.005)))
        }
        return true
    }
}
