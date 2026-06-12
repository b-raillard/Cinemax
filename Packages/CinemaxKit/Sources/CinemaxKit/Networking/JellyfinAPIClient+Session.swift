import Foundation
import JellyfinAPI

/// Outcome of an authoritative session re-check (`ServerAPI.validateSession`).
///
/// Drives the "confirm before logout" flow in `AppState`: only `.invalid`
/// (a server-confirmed revoked/expired token) tears the session down. A
/// transient network failure is `.indeterminate` and MUST keep the user
/// signed in — turning the box off and on must never disconnect the user.
public enum SessionValidity: Sendable, Equatable {
    /// 2xx — the token is still good.
    case valid
    /// Authoritative 401 — the token is genuinely revoked/expired.
    case invalid
    /// Network error / timeout / non-401 — cannot prove anything; keep session.
    case indeterminate
}

extension JellyfinAPIClient {
    /// Silently re-validates the current token against `GET /Users/Me`. Network
    /// app↔server only — no UI, no user interaction. Deliberately does NOT call
    /// `notifyIfUnauthorized` (it would re-enter the expiry flow that called us).
    public func validateSession() async -> SessionValidity {
        guard let client = getClient() else { return .indeterminate }
        do {
            _ = try await client.send(Paths.getCurrentUser)
            return .valid
        } catch {
            // Reuse the SAME precise classifier as the lazy-recovery path so
            // detection stays single-source-of-truth.
            return Self.isUnauthorized(error) ? .invalid : .indeterminate
        }
    }
}
