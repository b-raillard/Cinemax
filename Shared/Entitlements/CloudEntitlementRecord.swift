import Foundation

/// The proof of a Pro purchase, as stored locally (`SettingsKey.entitlementLocalRecord`)
/// and mirrored to the shared iCloud key-value store (`CloudEntitlementMirror`).
///
/// Written by the platform the purchase was made on and read by both apps, so
/// its wire format is a CONTRACT between two binaries that may not be the same
/// version: a new field is added as an optional; anything else bumps `version`,
/// and a reader that does not know a version ignores the record rather than
/// guessing (`decode(_:)` returns `nil`, never traps).
struct CloudEntitlementRecord: Codable, Sendable, Equatable {
    /// The only format this build writes and understands.
    static let currentVersion = 1

    let version: Int
    let productID: String
    let originalTransactionID: String
    let purchaseDate: Date
    /// The StoreKit 2 JWS of the transaction, kept so a future reader can
    /// verify the mirror instead of trusting it. `nil` until StoreKit lands.
    let signedTransaction: String?
    /// Bundle id of the app that wrote the record (`com.cinemax.ios` /
    /// `com.cinemax.tvos`) — tells a reader whether it is looking at its own
    /// purchase or the other platform's.
    let writerBundleID: String

    init(
        version: Int = Self.currentVersion,
        productID: String,
        originalTransactionID: String,
        purchaseDate: Date,
        signedTransaction: String? = nil,
        writerBundleID: String
    ) {
        self.version = version
        self.productID = productID
        self.originalTransactionID = originalTransactionID
        self.purchaseDate = purchaseDate
        self.signedTransaction = signedTransaction
        self.writerBundleID = writerBundleID
    }

    /// Only the version, read first so a record from a newer build is
    /// recognised as such even when the rest of its shape changed.
    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// `nil` for anything this build cannot vouch for: bytes that are not a
    /// record, a record of an unknown `version`, a record missing a field.
    /// Dates use the coder's default (`deferredToDate`), which round-trips a
    /// `Date` exactly — both apps must keep the same strategy.
    static func decode(_ data: Data) -> Self? {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data),
              probe.version == currentVersion else { return nil }
        return try? decoder.decode(Self.self, from: data)
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}
