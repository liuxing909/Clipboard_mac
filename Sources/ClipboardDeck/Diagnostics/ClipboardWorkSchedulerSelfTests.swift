import Foundation

@MainActor
enum ClipboardWorkSchedulerSelfTests {
    static func run() throws {
        try checkAdmissionAndFIFO()
        try checkRunningCancellation()
        try checkQueuedCaptureRelease()
        try checkPressureAndRecovery()
        try checkErrorsAndResultRelease()
        try checkOwnerRelease()
        try checkRepeatedCancellation()
        print(
            "PASS: clipboard worker FIFO / single concurrency / count and byte budgets / cancellation accounting / capture release / pressure recovery / errors / owner release"
        )
    }

    private static func checkAdmissionAndFIFO() throws {
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        let probe = WorkProbe()
        defer { probe.release.signal(); scheduler.cancelAll() }
        var completed: [Int] = []
        var callbacksOnMain = true
        let callback: @MainActor (Result<Int, Error>) -> Void = { result in
            callbacksOnMain = callbacksOnMain && Thread.isMainThread
            if case .success(let value) = result { completed.append(value) }
        }
        let mib = 1_048_576
        try check(
            scheduler.canSubmit && scheduler.outstandingCount == 0 && scheduler.retainedBytes == 0,
            "a new worker is idle")
        try check(
            scheduler.submit(byteCount: -1, work: { 0 }, completion: callback) == nil
                && scheduler.submit(byteCount: Int.max, work: { 0 }, completion: callback) == nil,
            "negative and overflowing byte estimates are rejected without accounting changes")
        try check(
            scheduler.submit(
                byteCount: 30 * mib, work: { probe.run(1, blocked: true) },
                completion: callback) != nil, "first task is admitted")
        try check(SelfTestWait.until { probe.started == [1] }, "first task starts off the main thread")
        try check(
            scheduler.submit(
                byteCount: 21 * mib, work: { probe.run(99) },
                completion: callback) == nil,
            "retained inputs cannot exceed the default 50 MiB budget")
        try check(
            scheduler.submit(
                byteCount: 20 * mib, work: { probe.run(2) },
                completion: callback) != nil,
            "a second task may consume the remaining byte budget exactly")
        try check(
            scheduler.outstandingCount == 2 && scheduler.retainedBytes == 50 * mib && !scheduler.canSubmit
                && scheduler.submit(byteCount: 0, work: { probe.run(3) }, completion: callback) == nil,
            "default admission includes one running and one queued task, even for zero-cost work")
        try check(probe.started == [1], "queued work does not run concurrently")
        probe.release.signal()
        try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "the queue drains")
        try check(
            probe.started == [1, 2] && probe.peak == 1 && !probe.ranOnMain && completed == [1, 2] && callbacksOnMain
                && scheduler.retainedBytes == 0 && scheduler.canSubmit,
            "work is FIFO and serial, callbacks run on main, and all budgets recover")

        let bytesOnly = ClipboardWorkScheduler(
            maxOutstanding: 4, maxRetainedBytes: 10,
            observesMemoryPressure: false)
        let byteProbe = WorkProbe()
        defer { byteProbe.release.signal(); bytesOnly.cancelAll() }
        _ = bytesOnly.submit(byteCount: 10, work: { byteProbe.run(1, blocked: true) }) { _ in }
        try check(SelfTestWait.until { byteProbe.started == [1] }, "small-budget task starts")
        try check(
            !bytesOnly.canSubmit && bytesOnly.outstandingCount == 1
                && bytesOnly.submit(byteCount: 1, work: { 0 }) { _ in } == nil,
            "the byte bound applies independently of the operation-count bound")
        byteProbe.release.signal()
        try check(SelfTestWait.until { bytesOnly.outstandingCount == 0 }, "small-budget task finishes")
    }

    private static func checkRunningCancellation() throws {
        let scheduler = ClipboardWorkScheduler(
            maxOutstanding: 1, maxRetainedBytes: 10,
            observesMemoryPressure: false)
        let probe = WorkProbe()
        defer { probe.release.signal(); scheduler.cancelAll() }
        var callbacks = 0
        var cancellations: [UUID] = []
        var cancellationsOnMain = true
        scheduler.onCancel = {
            cancellations.append($0)
            cancellationsOnMain = cancellationsOnMain && Thread.isMainThread
        }
        weak var runningInput: Resource?
        var id: UUID?
        autoreleasepool {
            let input = Resource()
            runningInput = input
            id = scheduler.submit(
                byteCount: 10,
                work: {
                    withExtendedLifetime(input) { probe.run(1, blocked: true) }
                }
            ) { _ in callbacks += 1 }
        }
        guard let id else { throw Failure.failed("running cancellation task was rejected") }
        try check(SelfTestWait.until { probe.started == [1] }, "cancellable task is running")
        scheduler.cancel(id)
        scheduler.cancel(id)
        scheduler.cancel(UUID())
        scheduler.cancelAll()
        try check(
            cancellations == [id] && cancellationsOnMain,
            "cancellation notification fires once per task, on main")
        try check(
            scheduler.outstandingCount == 1 && scheduler.retainedBytes == 10 && runningInput != nil
                && !scheduler.canSubmit && scheduler.submit(byteCount: 0, work: { 2 }) { _ in callbacks += 1 } == nil,
            "cancellation never frees the budget or input of work that is still executing")
        probe.release.signal()
        try check(
            SelfTestWait.until { scheduler.outstandingCount == 0 && runningInput == nil },
            "a cancelled task releases its running capture and budget after actual completion")
        try check(
            callbacks == 0 && scheduler.retainedBytes == 0,
            "cancelled work has no late completion callback")
        try check(
            scheduler.submit(byteCount: 1, work: { 2 }) { _ in callbacks += 1 } != nil,
            "new work is accepted after a cancelled task drains")
        try check(
            SelfTestWait.until { callbacks == 1 && scheduler.outstandingCount == 0 },
            "new work completes after cancellation")
    }

    private static func checkQueuedCaptureRelease() throws {
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        let probe = WorkProbe()
        defer { probe.release.signal(); scheduler.cancelAll() }
        _ = scheduler.submit(byteCount: 1, work: { probe.run(1, blocked: true) }) { _ in }
        try check(SelfTestWait.until { probe.started == [1] }, "blocking task starts before queued capture")
        weak var queuedInput: Resource?
        weak var queuedCompletionCapture: Resource?
        var queuedID: UUID?
        var callbacks = 0
        autoreleasepool {
            let input = Resource()
            let callbackCapture = Resource()
            queuedInput = input
            queuedCompletionCapture = callbackCapture
            queuedID = scheduler.submit(
                byteCount: 1,
                work: {
                    withExtendedLifetime(input) { probe.run(2) }
                }
            ) { _ in
                withExtendedLifetime(callbackCapture) { callbacks += 1 }
            }
        }
        guard let queuedID else { throw Failure.failed("queued capture task was rejected") }
        try check(
            queuedInput != nil && queuedCompletionCapture != nil,
            "queued work owns its input and callback")
        scheduler.cancel(queuedID)
        try check(
            queuedInput == nil && queuedCompletionCapture == nil,
            "cancelling queued work immediately releases both captured input and callback")
        probe.release.signal()
        try check(
            SelfTestWait.until { scheduler.outstandingCount == 0 },
            "cancelled queued work still reports completion and releases accounting")
        try check(
            probe.started == [1] && callbacks == 0 && scheduler.retainedBytes == 0,
            "OperationQueue skipping cancelled work leaks neither callbacks nor byte budget")
    }

    private static func checkPressureAndRecovery() throws {
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        let probe = WorkProbe()
        defer { probe.release.signal(); scheduler.cancelAll() }
        var callbacks = 0
        var cancellationCount = 0
        scheduler.onCancel = { _ in cancellationCount += 1 }
        _ = scheduler.submit(byteCount: 1, work: { probe.run(1, blocked: true) }) { _ in callbacks += 1 }
        try check(SelfTestWait.until { probe.started == [1] }, "pressure test starts executing work")
        _ = scheduler.submit(byteCount: 1, work: { probe.run(2) }) { _ in callbacks += 1 }
        scheduler.setMemoryPressure(isElevated: true)
        scheduler.setMemoryPressure(isElevated: true)
        try check(
            cancellationCount == 2 && !scheduler.canSubmit
                && scheduler.submit(byteCount: 1, work: { probe.run(3) }) { _ in callbacks += 1 } == nil,
            "elevated pressure cancels all work once and pauses admission")
        probe.release.signal()
        try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "pressure-cancelled work drains")
        try check(
            callbacks == 0 && probe.started == [1] && !scheduler.canSubmit,
            "no cancelled result is delivered and pressure remains active after draining")
        scheduler.setMemoryPressure(isElevated: false)
        try check(
            scheduler.canSubmit
                && scheduler.submit(byteCount: 1, work: { probe.run(4) }) { _ in callbacks += 1 } != nil,
            "a normal-pressure event resumes admission")
        try check(
            SelfTestWait.until { callbacks == 1 && scheduler.outstandingCount == 0 },
            "work resumes after memory pressure ends")
    }

    private static func checkErrorsAndResultRelease() throws {
        let scheduler = ClipboardWorkScheduler(maxOutstanding: 1, observesMemoryPressure: false)
        var failed = false
        var recovered = false
        var callbackSawFreeBudget = false
        _ = scheduler.submit(
            byteCount: 1,
            work: { () throws -> Int in
                throw Failure.expected
            }
        ) { result in
            if case .failure = result { failed = true }
            callbackSawFreeBudget = scheduler.outstandingCount == 0 && scheduler.retainedBytes == 0
        }
        try check(SelfTestWait.until { failed }, "a throwing task delivers its error")
        try check(
            callbackSawFreeBudget && scheduler.canSubmit,
            "a failure releases accounting before invoking its callback")
        weak var releasedResult: Resource?
        _ = scheduler.submit(byteCount: 1, work: { Resource() }) { result in
            if case .success(let value) = result { releasedResult = value; recovered = true }
        }
        try check(
            SelfTestWait.until { recovered && scheduler.outstandingCount == 0 && releasedResult == nil },
            "successful work after an error completes without retaining its result")
    }

    private static func checkOwnerRelease() throws {
        let probe = WorkProbe()
        defer { probe.release.signal() }
        var scheduler: ClipboardWorkScheduler? = ClipboardWorkScheduler(observesMemoryPressure: true)
        let releasedScheduler = WeakScheduler(scheduler)
        var callbacks = 0
        _ = scheduler?.submit(byteCount: 1, work: { probe.run(1, blocked: true) }) { _ in callbacks += 1 }
        try check(SelfTestWait.until { probe.started == [1] }, "owner-release work starts")
        scheduler = nil
        try check(releasedScheduler.value == nil, "neither pressure listener nor work queue retains its owner")
        probe.release.signal()
        try check(
            SelfTestWait.until { probe.finished == 1 } && callbacks == 0,
            "orphaned running work finishes without delivering a callback")
    }

    private static func checkRepeatedCancellation() throws {
        let scheduler = ClipboardWorkScheduler(maxRetainedBytes: 10, observesMemoryPressure: false)
        defer { scheduler.cancelAll() }
        for round in 0..<200 {
            let probe = WorkProbe()
            defer { probe.release.signal() }
            var delivered: [Int] = []
            let first = scheduler.submit(byteCount: 6, work: { probe.run(1, blocked: true) }) { result in
                if case .success(let value) = result { delivered.append(value) }
            }
            try check(SelfTestWait.until { probe.started == [1] }, "round \(round): worker starts")
            let second = scheduler.submit(byteCount: 4, work: { probe.run(2) }) { result in
                if case .success(let value) = result { delivered.append(value) }
            }
            guard let first, let second else { throw Failure.failed("stress jobs were unexpectedly rejected") }
            for _ in 0..<100 {
                try check(
                    scheduler.submit(byteCount: 0, work: { 99 }) { _ in delivered.append(99) } == nil,
                    "round \(round): bursts cannot bypass the full queue")
            }
            switch round % 4 {
            case 0: scheduler.cancel(first)
            case 1: scheduler.cancel(second)
            case 2:
                scheduler.setMemoryPressure(isElevated: true)
                scheduler.setMemoryPressure(isElevated: false)
            default: break
            }
            probe.release.signal()
            try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "round \(round): worker drains")
            let expected: [Int]
            switch round % 4 {
            case 0: expected = [2]
            case 1: expected = [1]
            case 2: expected = []
            default: expected = [1, 2]
            }
            try check(
                delivered == expected && scheduler.retainedBytes == 0 && scheduler.canSubmit && probe.peak == 1,
                "round \(round): cancellation has no late callbacks, accounting leaks or FIFO violations")
        }
        print("STRESS CASE: 200 worker lifecycle rounds / 400 admitted jobs / 20000 rejected burst submissions")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.failed(message) }
    }

    private enum Failure: Error { case failed(String), expected }
    private final class WeakScheduler {
        weak var value: ClipboardWorkScheduler?
        init(_ value: ClipboardWorkScheduler?) { self.value = value }
    }
    private final class Resource: @unchecked Sendable {}

    private final class WorkProbe: @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var startOrder: [Int] = []
        private var activeCount = 0
        private var peakCount = 0
        private var finishedCount = 0
        private var mainThreadObserved = false

        var started: [Int] { lock.withLock { startOrder } }
        var peak: Int { lock.withLock { peakCount } }
        var finished: Int { lock.withLock { finishedCount } }
        var ranOnMain: Bool { lock.withLock { mainThreadObserved } }

        func run(_ value: Int, blocked: Bool = false) -> Int {
            lock.withLock {
                startOrder.append(value)
                activeCount += 1
                peakCount = max(peakCount, activeCount)
                mainThreadObserved = mainThreadObserved || Thread.isMainThread
            }
            if blocked { _ = release.wait(timeout: .now() + 5) }
            lock.withLock {
                activeCount -= 1; finishedCount += 1
            }
            return value
        }
    }
}
