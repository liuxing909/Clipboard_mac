import Foundation

/// Scheduling only: clipboard ownership, pause semantics and capture remain with
/// the caller. A callback that refers to its owner should capture that owner weakly.
@MainActor
protocol ClipboardPolling: AnyObject {
    var isRunning: Bool { get }
    func start(_ tick: @escaping @MainActor () -> Void)
    func stop()
}

/// A single coalescible main-run-loop timer, with no per-tick Task allocation.
@MainActor
final class RunLoopClipboardPoller: ClipboardPolling {
    private let interval: TimeInterval
    private let tolerance: TimeInterval
    private var timer: Timer?
    private var tick: (@MainActor () -> Void)?

    var isRunning: Bool { timer?.isValid == true }

    init(interval: TimeInterval = 0.6, tolerance: TimeInterval = 0.1) {
        self.interval = interval.isFinite && interval > 0 ? interval : 0.6
        self.tolerance = tolerance.isFinite && tolerance >= 0 ? tolerance : 0.1
    }

    func start(_ tick: @escaping @MainActor () -> Void) {
        // A repeated start must not create another timer or replace its callback.
        guard !isRunning else { return }
        self.tick = tick
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                autoreleasepool { self.tick?() }
            }
        }
        timer.tolerance = tolerance
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tick = nil
    }

    deinit { timer?.invalidate() }
}
