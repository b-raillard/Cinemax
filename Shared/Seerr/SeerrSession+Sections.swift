import Foundation
import CinemaxKit

private enum SectionOutcome<T: Sendable>: Sendable { case answer([T]), failed, expired }

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
        let outcome = await withTaskGroup(of: SectionOutcome<T>.self) { group in
            group.addTask { [self] in
                do { return .answer(try await perform(op)) } catch { return .failed }
            }
            group.addTask {
                try? await deadline()
                return .expired
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
        guard !Task.isCancelled, isCurrent(snapshot) else { return nil }
        switch outcome {
        case .answer(let items): return .loaded(items)
        case .failed, .expired: return .hidden
        }
    }
}
