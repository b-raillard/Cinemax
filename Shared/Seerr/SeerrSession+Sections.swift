import Foundation
import CinemaxKit

private enum SectionOutcome<T: Sendable>: Sendable { case answer([T]), failed, expired }

/// Resumes one continuation, once, with the first outcome — whichever of the
/// work, the timer or the caller's cancellation arrives first (also before
/// the continuation is installed).
private final class SectionRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SectionOutcome<T>, Never>?
    private var early: SectionOutcome<T>?
    private var done = false

    func install(_ continuation: CheckedContinuation<SectionOutcome<T>, Never>) {
        let ready: SectionOutcome<T>? = lock.withLock {
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func finish(_ outcome: SectionOutcome<T>) {
        let toResume: CheckedContinuation<SectionOutcome<T>, Never>? = lock.withLock {
            guard !done else { return nil }
            done = true
            if let continuation { self.continuation = nil; return continuation }
            early = outcome
            return nil
        }
        toResume?.resume(returning: outcome)
    }
}

extension SeerrSession {
    /// THE loader of every Seerr section (search, series, saga, actor): runs
    /// `op` as the active account against `deadline`, the first to finish
    /// winning.
    ///
    /// - `nil`: no account, or the answer is stale (cancelled task, account
    ///   changed) — the caller writes NOTHING.
    /// - `.hidden`: an error, or the deadline won.
    /// - `.loaded(items)`: the answer (an empty one renders nothing).
    ///
    /// Never touches UI state itself.
    func loadSection<T: Equatable & Sendable>(
        deadline: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(6)) },
        _ op: @escaping @Sendable (SeerrClient, SeerrCredential) async throws -> [T]
    ) async -> MissingSection<T>? {
        guard let snapshot = snapshot() else { return nil }
        // Two unstructured tasks, not a task group: a group awaits every child
        // after `cancelAll()`, and `perform`'s shared silent re-sign-in ignores
        // cancellation for tens of seconds, so the deadline would bound nothing.
        // The loser runs to completion unobserved — safe: `perform` drops a stale
        // answer, this method writes no UI, and the shared re-sign-in should
        // finish for the other callers.
        let race = SectionRace<T>()
        let work = Task { [self] in
            let outcome: SectionOutcome<T>
            do { outcome = .answer(try await perform(op)) } catch { outcome = .failed }
            race.finish(outcome)
        }
        let timer = Task {
            try? await deadline()
            race.finish(.expired)
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SectionOutcome<T>, Never>) in
                race.install(continuation)
            }
        } onCancel: {
            work.cancel()
            timer.cancel()
            race.finish(.failed)
        }
        work.cancel()
        timer.cancel()
        guard !Task.isCancelled, isCurrent(snapshot) else { return nil }
        switch outcome {
        case .answer(let items): return .loaded(items)
        case .failed, .expired: return .hidden
        }
    }
}
