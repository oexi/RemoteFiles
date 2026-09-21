import Foundation
import XCTest
@testable import RemoteFiles

final class ProviderCancellationTests: XCTestCase {
    func testBridgeWaitsForProviderCallbackAfterTaskCancellation() async {
        let callback = Locked<((Result<Void, Error>) -> Void)?>(nil)
        let started = Locked(false)
        let finished = Locked(false)

        let operationTask = Task<Result<Void, Error>, Never> {
            defer { finished.set(true) }
            return await captureResult {
                try await withProviderCancellation { complete, _ -> Progress? in
                    callback.set(complete)
                    started.set(true)
                    return nil
                }
            }
        }

        for _ in 0..<1_000 where !started.get() {
            await Task.yield()
        }
        XCTAssertTrue(started.get())

        operationTask.cancel()
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertFalse(finished.get(), "Cancellation must wait for the provider callback.")

        callback.get()?(.success(()))
        let result = await operationTask.value
        assertCancellation(result)
        XCTAssertTrue(finished.get())
    }

    func testCancellationBeforeOperationStartsCompletesImmediately() async {
        let state = ProviderCancellationState<Void>()

        let result = await captureResult {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.installContinuation(continuation)
                state.cancel()
                XCTAssertFalse(state.beginOperation())
            }
        }

        assertCancellation(result)
    }

    func testCancellationAfterStartWaitsForLateSuccessAndNormalizesIt() async {
        let state = ProviderCancellationState<Void>()

        let result = await captureResult {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.installContinuation(continuation)
                XCTAssertTrue(state.beginOperation())
                state.cancel()

                // A provider may report success after its cancellation flag was
                // observed. That late callback must still finish the bridge as
                // a cancellation.
                state.finish(.success(()))
            }
        }

        assertCancellation(result)
    }

    func testCancellationCancelsProgressAndCancellationErrorFromProviderIsNormalized() async {
        let state = ProviderCancellationState<Void>()
        let progress = Progress(totalUnitCount: 1)

        let result = await captureResult {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.installContinuation(continuation)
                XCTAssertTrue(state.beginOperation())
                state.installProgress(progress)
                state.cancel()
                XCTAssertTrue(progress.isCancelled)

                // Keep the provider callback path covered even when the
                // underlying library reports a platform cancellation error.
                state.finish(.failure(URLError(.cancelled)))
            }
        }

        assertCancellation(result)
    }

    func testSuccessBeforeLateCancellationWins() async {
        let state = ProviderCancellationState<Void>()

        let result = await captureResult {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.installContinuation(continuation)
                XCTAssertTrue(state.beginOperation())
                state.finish(.success(()))
                state.cancel()
            }
        }

        guard case .success = result else {
            return XCTFail("A provider success completed before cancellation should win.")
        }
    }

    func testDuplicateProviderCallbacksResumeOnlyOnce() async {
        let state = ProviderCancellationState<Void>()

        let result = await captureResult {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.installContinuation(continuation)
                XCTAssertTrue(state.beginOperation())
                state.finish(.success(()))
                state.finish(.failure(TestError.secondCallback))
            }
        }

        guard case .success = result else {
            return XCTFail("The first provider callback should determine the result.")
        }
    }

    private func assertCancellation(
        _ result: Result<Void, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = result else {
            return XCTFail("Expected CancellationError, got success.", file: file, line: line)
        }
        XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error).", file: file, line: line)
    }
}

private enum TestError: Error {
    case secondCallback
}

private func captureResult<Value>(_ operation: () async throws -> Value) async -> Result<Value, Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}
