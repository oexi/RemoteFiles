import Foundation

/// Coordinates cancellation between an async provider call, its callback, and
/// an optional Foundation `Progress` object. All state transitions are
/// serialized because provider callbacks commonly arrive on their own queue.
final class ProviderCancellationState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var progress: Progress?
    private var completed = false
    private var operationStarted = false
    private var cancellationRequested = false

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    func installContinuation(_ continuation: CheckedContinuation<Value, Error>) {
        let shouldResumeCancellation: Bool
        lock.lock()
        if completed {
            shouldResumeCancellation = true
        } else {
            self.continuation = continuation
            shouldResumeCancellation = false
        }
        lock.unlock()

        if shouldResumeCancellation {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Atomically claims the right to invoke the provider operation.
    ///
    /// Cancellation before this point is completed immediately because no
    /// provider work has started. Once this returns `true`, cancellation must
    /// wait for the provider's completion callback so a late callback cannot
    /// race the caller's cleanup.
    func beginOperation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, !cancellationRequested else { return false }
        operationStarted = true
        return true
    }

    func installProgress(_ progress: Progress?) {
        guard let progress else { return }

        lock.lock()
        let shouldCancel = cancellationRequested
        if !completed {
            self.progress = progress
        }
        lock.unlock()

        if shouldCancel { progress.cancel() }
    }

    func cancel() {
        let progress: Progress?
        let continuation: CheckedContinuation<Value, Error>?
        lock.lock()
        cancellationRequested = true
        progress = self.progress
        self.progress = nil
        if completed || operationStarted {
            continuation = nil
        } else {
            completed = true
            continuation = self.continuation
            self.continuation = nil
        }
        lock.unlock()

        progress?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    func finish(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        continuation = self.continuation
        self.continuation = nil
        let wasCancelled = cancellationRequested
        lock.unlock()

        guard let continuation else { return }
        if wasCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: Self.normalizedCancellationError(error))
        }
    }

    private static func normalizedCancellationError(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
            return CancellationError()
        }
        if let posixError = error as? POSIXError, posixError.code == .ECANCELED {
            return CancellationError()
        }
        return error
    }
}

/// Bridges callback APIs that optionally return a `Progress` into async code.
/// Cancellation before provider work starts resumes immediately. Once the
/// provider has started, cancellation requests the underlying operation to
/// stop and waits for its completion callback; a late callback is consumed by
/// `ProviderCancellationState` without resuming twice.
func withProviderCancellation<Value>(
    operation: @escaping (
        @escaping (Result<Value, Error>) -> Void,
        @escaping () -> Bool
    ) -> Progress?
) async throws -> Value {
    let state = ProviderCancellationState<Value>()
    return try await withTaskCancellationHandler(operation: {
        try Task.checkCancellation()
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            state.installContinuation(continuation)
            guard state.beginOperation() else { return }
            let progress = operation(
                { result in state.finish(result) },
                { state.isCancellationRequested }
            )
            state.installProgress(progress)
        }
        return value
    }, onCancel: {
        state.cancel()
    })
}
