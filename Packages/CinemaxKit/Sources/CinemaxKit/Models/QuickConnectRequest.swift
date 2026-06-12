import Foundation

/// An in-flight Jellyfin Quick Connect request.
///
/// Quick Connect lets a user sign in without typing credentials on the device:
/// the app initiates a request, shows the `code` to the user, and the user
/// approves that code from an already-signed-in session (web dashboard or
/// another app). The `secret` is the opaque token the app polls with and
/// ultimately exchanges for a session — it must never be shown to the user.
public struct QuickConnectRequest: Sendable, Equatable {
    /// Six-character code the user types/approves on another device.
    public let code: String
    /// Opaque polling token. Secret — never surface in the UI.
    public let secret: String

    public init(code: String, secret: String) {
        self.code = code
        self.secret = secret
    }
}
