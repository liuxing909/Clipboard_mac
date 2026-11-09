import Foundation

@MainActor
enum PollingSelfTests {
    static func run() throws {
        let poller = RunLoopClipboardPoller(interval: 0.01, tolerance: 0)
        defer { poller.stop() }
        try check(!poller.isRunning, "a new poller has no timer")
        var originalTicks = 0
        var duplicateTicks = 0
        poller.start { originalTicks += 1 }
        poller.start { duplicateTicks += 1 }
        try check(poller.isRunning, "starting schedules polling")
        try waitUntil { originalTicks > 0 }
        try check(duplicateTicks == 0, "repeated start keeps the original callback")

        poller.stop()
        poller.stop()
        let stoppedCount = originalTicks
        runLoop(for: 0.05)
        try check(
            !poller.isRunning && originalTicks == stoppedCount && duplicateTicks == 0,
            "stop is idempotent and prevents further callbacks")

        var restartedTicks = 0
        poller.start { restartedTicks += 1 }
        try waitUntil { restartedTicks > 0 }
        try check(
            poller.isRunning && originalTicks == stoppedCount,
            "a stopped poller can restart with a new callback")
        poller.stop()

        // The run loop must not retain the poller through its scheduled timer.
        // The caller uses a weak owner capture, just as AppModel does.
        let counter = Counter()
        weak var releasedOwner: Owner?
        weak var releasedPoller: RunLoopClipboardPoller?
        autoreleasepool {
            var owner: Owner? = Owner(counter: counter)
            releasedOwner = owner
            releasedPoller = owner?.poller
            owner?.start()
            owner = nil
        }
        try check(
            releasedOwner == nil && releasedPoller == nil,
            "a scheduled timer does not keep its owner or poller alive")
        let releasedCount = counter.value
        runLoop(for: 0.05)
        try check(counter.value == releasedCount, "releasing the poller prevents later callbacks")

        // stop must release resources captured by the callback immediately,
        // even when the poller itself remains alive.
        weak var releasedCapture: Counter?
        autoreleasepool {
            let capture = Counter()
            releasedCapture = capture
            poller.start { capture.value += 1 }
        }
        try check(releasedCapture != nil, "running poller owns its callback")
        poller.stop()
        try check(releasedCapture == nil, "stop releases the callback and its captures")
        print("PASS: polling start/stop idempotence / restart / owner release / stopped callback release")
    }

    private static func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline { runLoop(for: 0.01) }
        try check(condition(), "polling callback fires on the main run loop")
    }

    private static func runLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        // Keep the loop sleeping until the deadline even after polling stops.
        let sentinel = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
        RunLoop.main.add(sentinel, forMode: .default)
        defer { sentinel.invalidate() }
        RunLoop.main.run(until: deadline)
    }

    private static func check(_ passed: Bool, _ message: String) throws {
        if !passed { throw Failure.failed(message) }
    }

    @MainActor private final class Counter { var value = 0 }

    @MainActor private final class Owner {
        let poller = RunLoopClipboardPoller(interval: 0.01, tolerance: 0)
        private let counter: Counter
        init(counter: Counter) { self.counter = counter }
        func start() {
            let counter = counter
            poller.start { [weak self] in
                // Count callback invocations independently of owner survival.
                counter.value += 1
                self?.didTick()
            }
        }
        private func didTick() {}
    }

    private enum Failure: Error { case failed(String) }
}
