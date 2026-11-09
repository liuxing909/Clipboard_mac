import Foundation

/// Shares a bounded, serial worker between capture parsing and paste preparation.
/// Byte costs describe retained inputs, not a hard limit on a decoder's working memory.
@MainActor
final class ClipboardWorkScheduler {
    var onCancel: ((UUID) -> Void)?
    var canSubmit: Bool {
        !underMemoryPressure && requests.count < maxOutstanding && retainedBytes < maxRetainedBytes
    }
    var outstandingCount: Int { requests.count }
    private(set) var retainedBytes = 0

    private struct Request {
        let operation: Operation
        let byteCount: Int
        var deliver: (@MainActor () -> Void)?
        var cancelled = false
    }

    private let maxOutstanding: Int
    private let maxRetainedBytes: Int
    private let queue: OperationQueue
    private var requests: [UUID: Request] = [:]
    private var submissionOrder: [UUID] = []
    private var completed: Set<UUID> = []
    private weak var lastOperation: Operation?
    private var underMemoryPressure = false
    private var pressureSource: DispatchSourceMemoryPressure?

    init(
        maxOutstanding: Int = 2, maxRetainedBytes: Int = 50 * 1_048_576,
        observesMemoryPressure: Bool = true
    ) {
        self.maxOutstanding = max(1, maxOutstanding)
        self.maxRetainedBytes = max(1, maxRetainedBytes)
        queue = OperationQueue()
        queue.name = "ClipboardDeck.clipboard-work"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated

        if observesMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical], queue: .main)
            pressureSource = source
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let events = self.pressureSource?.data else { return }
                    if events.contains(.warning) || events.contains(.critical) {
                        self.setMemoryPressure(isElevated: true)
                    } else if events.contains(.normal) {
                        self.setMemoryPressure(isElevated: false)
                    }
                }
            }
            source.resume()
        }
    }

    deinit {
        pressureSource?.cancel()
        queue.cancelAllOperations()
    }

    /// Rejection retains neither work nor completion. Cancelled running operations continue
    /// occupying their count and byte budget until OperationQueue reports actual completion.
    @discardableResult
    func submit<Value: Sendable>(
        byteCount: Int,
        work: @escaping @Sendable () throws -> Value,
        completion: @escaping @MainActor (Result<Value, Error>) -> Void
    ) -> UUID? {
        guard canSubmit, byteCount >= 0, byteCount <= maxRetainedBytes - retainedBytes else {
            return nil
        }
        let id = UUID()
        let operation = ClipboardWorkOperation(work: work)
        // A serial OperationQueue alone does not promise submission order.
        if let previous = lastOperation, !previous.isFinished {
            operation.addDependency(previous)
        }
        operation.completionBlock = { [weak self] in
            // Runs even when cancellation prevents Operation.main() from being called.
            DispatchQueue.main.async { [weak self] in self?.finish(id) }
        }
        requests[id] = Request(
            operation: operation, byteCount: byteCount,
            deliver: {
                if let result = operation.takeResult() { completion(result) }
            })
        retainedBytes += byteCount
        submissionOrder.append(id)
        lastOperation = operation
        queue.addOperation(operation)
        return id
    }

    func cancel(_ id: UUID) {
        guard var request = requests[id], !request.cancelled else { return }
        request.cancelled = true
        // Release UI captures immediately instead of retaining them until slow work finishes.
        request.deliver = nil
        requests[id] = request
        request.operation.cancel()
        onCancel?(id)
    }

    func cancelAll() {
        // onCancel may re-enter the scheduler, so iterate a stable snapshot of identifiers.
        for id in Array(requests.keys) { cancel(id) }
    }

    /// Production pressure events and deterministic self-tests use the same transition.
    func setMemoryPressure(isElevated: Bool) {
        underMemoryPressure = isElevated
        if isElevated { cancelAll() }
    }

    private func finish(_ id: UUID) {
        guard requests[id] != nil else { return }
        completed.insert(id)
        // Operation dependencies order the work, but completionBlock callbacks
        // themselves may arrive out of order. Commit delivery in submission order.
        while let first = submissionOrder.first, completed.contains(first) {
            submissionOrder.removeFirst()
            completed.remove(first)
            guard let request = requests.removeValue(forKey: first) else { continue }
            retainedBytes -= request.byteCount
            request.deliver?()
        }
    }
}

/// Owns its input closure only while queued/running, and its result only until delivery.
/// OperationQueue provides the completion callback even for operations cancelled while queued.
private final class ClipboardWorkOperation<Value: Sendable>: Operation, @unchecked Sendable {
    private let stateLock = NSLock()
    private var work: (@Sendable () throws -> Value)?
    private var result: Result<Value, Error>?

    init(work: @escaping @Sendable () throws -> Value) {
        self.work = work
        super.init()
    }

    override func main() {
        stateLock.lock()
        let task = isCancelled ? nil : work
        work = nil
        stateLock.unlock()
        guard let task else { return }

        let output = autoreleasepool { Result(catching: task) }
        stateLock.lock()
        if !isCancelled { result = output }
        stateLock.unlock()
    }

    override func cancel() {
        super.cancel()
        stateLock.lock()
        let discardedWork = work
        let discardedResult = result
        work = nil
        result = nil
        stateLock.unlock()
        // Any captured resources are destroyed outside the state lock. An already running
        // task owns its local closure until it returns, and remains included in the budget.
        withExtendedLifetime((discardedWork, discardedResult)) {}
    }

    func takeResult() -> Result<Value, Error>? {
        stateLock.lock()
        let output = result
        result = nil
        stateLock.unlock()
        return output
    }
}
