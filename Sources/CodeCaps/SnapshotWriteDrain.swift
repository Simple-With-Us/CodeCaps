import Foundation

/// A deadline bounds how long termination waits, not the underlying disk write.
/// Unstructured waiters intentionally do not join the possibly stuck task on timeout.
@MainActor
enum SnapshotWriteDrain {
    private final class ResultGate {
        var continuation: CheckedContinuation<Bool, Never>?
        var timeoutTask: Task<Void, Never>?

        func finish(_ drained: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(returning: drained)
        }
    }

    static func wait(for chain: Task<Void, Never>?, timeout: Duration) async -> Bool {
        guard let chain else { return true }
        return await withCheckedContinuation { continuation in
            let gate = ResultGate()
            gate.continuation = continuation
            Task { @MainActor in
                await chain.value
                gate.finish(true)
            }
            gate.timeoutTask = Task { @MainActor in
                do { try await Task.sleep(for: timeout) }
                catch { return }
                gate.finish(false)
            }
        }
    }
}

/// One terminal lifecycle per process, with no cancellation or resume path.
/// Retaining the completed task is intentional: no stale callback can clear a
/// newer drain because a newer drain is never created after termination starts.
@MainActor
final class SnapshotTerminationDrain {
    private var task: Task<Bool, Never>?

    func request(stop: () -> Void,
                 flush: @escaping @MainActor () async -> Bool,
                 reply: @escaping @MainActor () -> Void) {
        if task == nil {
            stop()
            task = Task { @MainActor in await flush() }
        }
        guard let task else { return }
        Task { @MainActor in
            _ = await task.value
            reply()
        }
    }
}
