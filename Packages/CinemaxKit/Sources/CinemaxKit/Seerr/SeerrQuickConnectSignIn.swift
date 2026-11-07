import Foundation
// For the status match in `classifyApproval` — mapping here keeps `Get` out of
// the app layer, as `JellyfinAPIClient.changeOwnPassword` does.
import Get

/// Why the one-gesture Seerr sign-in did not complete.
public enum SeerrSignInError: Error, Equatable {
    /// Seerr itself failed (unreachable, not Seerr, …).
    case seerr(SeerrError)
    /// Jellyfin does not know the code: this Seerr is linked to ANOTHER Jellyfin.
    case otherJellyfin
    /// Jellyfin refused the approval (device restriction, session limit).
    case jellyfinRefused
    /// Seerr has no account for this Jellyfin user (never imported).
    case notImported
    /// Seerr never reported the code as approved.
    case timedOut
    /// The surrounding task was cancelled. Typed throws cannot carry a
    /// `CancellationError`, so the caller maps this back to a cancellation.
    case cancelled
}

/// Signs in to Seerr without typing: Seerr issues a Quick Connect code, the
/// app approves it on Jellyfin with the user's own token, then Seerr opens its
/// session.
public struct SeerrQuickConnectSignIn: Sendable {
    private let client: SeerrClient
    private let approve: @Sendable (String) async throws -> Bool
    private let maxChecks: Int
    private let pause: @Sendable () async throws -> Void

    public init(
        client: SeerrClient,
        approve: @escaping @Sendable (String) async throws -> Bool,
        maxChecks: Int = 10,
        pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) {
        self.client = client
        self.approve = approve
        self.maxChecks = maxChecks
        self.pause = pause
    }

    /// Jellyfin answers 404 for a code it does not know and 403 for a refusal
    /// (device restriction, session limit); anything else is read as « cannot
    /// reach it ».
    public static func classifyApproval(_ error: Error) -> SeerrSignInError {
        if let apiError = error as? Get.APIError, case .unacceptableStatusCode(let code) = apiError {
            if code == 404 { return .otherJellyfin }
            if code == 403 { return .jellyfinRefused }
        }
        return .seerr(.unreachable)
    }

    public func run() async throws(SeerrSignInError) -> (cookie: String, user: SeerrUser) {
        do {
            return try await attempt()
        } catch let error as SeerrSignInError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch let error as SeerrError {
            throw .seerr(error)
        } catch {
            throw .seerr(.unreachable)
        }
    }

    private func attempt() async throws -> (cookie: String, user: SeerrUser) {
        let issued = try await client.quickConnectInitiate()

        let approved: Bool
        do {
            approved = try await approve(issued.code)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Self.classifyApproval(error)
        }
        guard approved else { throw SeerrSignInError.otherJellyfin }

        var checks = 0
        while true {
            checks += 1
            if try await client.quickConnectCheck(secret: issued.secret) { break }
            guard checks < maxChecks else { throw SeerrSignInError.timedOut }
            try await pause()
        }

        do {
            return try await client.quickConnectAuthenticate(secret: issued.secret)
        } catch SeerrError.accessDenied {
            throw SeerrSignInError.notImported
        }
    }
}
