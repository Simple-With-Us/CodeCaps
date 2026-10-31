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
