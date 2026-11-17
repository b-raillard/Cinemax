import Foundation
import Security

/// Verifies an App Store JWS that THIS app's StoreKit cannot vouch for: the
/// other app's purchase (`entitlement.pro.v1`) or founder facts
/// (`earlyAdopter.<platform>.v1`), read from the user-writable iCloud
/// key-value store (audit SEC-02). StoreKit offers no public API that checks a
/// JWS string (iOS / tvOS 27.2 SDK: `jwsRepresentation` is a getter only), so
/// this is the recipe Apple's App Store Server Library applies:
/// - the `x5c` chain must end at **Apple Root CA - G3**, pinned here — the
///   system's trust store would accept any public CA;
/// - the leaf must carry the App Store receipt-signing marker
///   (OID 1.2.840.113635.100.6.11.1) and the intermediate Apple's WWDR one
///   (1.2.840.113635.100.6.2.1) — other Apple-issued certificates, developers'
///   included, chain to the same root;
/// - ES256 over `header.payload`;
/// - the chain is evaluated at the JWS's OWN signing date (`signedDate`, or
///   an app transaction's `receiptCreationDate`), never now: leaf
///   certificates expire, a purchase does not.
/// Not checked: the device verification (it binds the JWS to the device that
/// fetched it — the OTHER app's device, by construction) and the online
/// revocation of the certificates (offline by design, like the rest of the
/// entitlement read). A genuine JWS copied from another Apple account still
/// verifies — signatures prove the App Store wrote it, not whose iCloud it is in.
nonisolated struct AppStoreSignature: Sendable {
    /// The trust anchor, DER. `appStore` pins Apple Root CA - G3; tests pass
    /// their own root.
    let anchor: Data

    /// Apple Root CA - G3 — SHA-256 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79,
    /// valid to 2039-04-30 (copied from macOS's SystemRootCertificates keychain).
    static let appleRootCAG3 = Data(base64Encoded: """
        MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==
        """, options: .ignoreUnknownCharacters) ?? Data()

    static let appStore = Self(anchor: appleRootCAG3)

    /// DER encodings (tag 06) of the two marker OIDs.
    private static let leafMarker = Data([0x06, 0x0A, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x06, 0x0B, 0x01])
    private static let intermediateMarker = Data([0x06, 0x0A, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x06, 0x02, 0x01])

    private struct Header: Decodable {
        let alg: String
        let x5c: [String]
    }

    /// When the App Store signed it. Milliseconds since 1970, like every App
    /// Store JWS date. A transaction carries `signedDate`; an app transaction
    /// does NOT — its signing date is `receiptCreationDate` (measured on the
    /// JWS local StoreKit emits, 2026-11-13).
    private struct Signed: Decodable {
        let signedDate: Double?
        let receiptCreationDate: Double?

        var date: Date? {
            (signedDate ?? receiptCreationDate).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }

    /// The payload's bytes when the JWS verifies, `nil` for anything else.
    func payload(of jws: String) -> Data? {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Self.base64URL(parts[0]),
              let payload = Self.base64URL(parts[1]),
              let signature = Self.base64URL(parts[2]), signature.count == 64,
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              header.alg == "ES256", header.x5c.count >= 2,
              let signedDate = (try? JSONDecoder().decode(Signed.self, from: payload))?.date
        else { return nil }
        let chain = header.x5c.prefix(2).compactMap { Data(base64Encoded: $0) }
        guard chain.count == 2,
              chain[0].range(of: Self.leafMarker) != nil,
              chain[1].range(of: Self.intermediateMarker) != nil,
              let leaf = SecCertificateCreateWithData(nil, chain[0] as CFData),
              let intermediate = SecCertificateCreateWithData(nil, chain[1] as CFData),
              let root = SecCertificateCreateWithData(nil, anchor as CFData)
        else { return nil }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, intermediate] as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust,
              SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustSetVerifyDate(trust, signedDate as CFDate) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil),
              let key = SecTrustCopyKey(trust)
        else { return nil }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .ecdsaSignatureMessageRFC4754SHA256, signingInput as CFData, signature as CFData, nil) else {
            return nil
        }
        return payload
    }

    private static func base64URL(_ part: Substring) -> Data? {
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
}

// MARK: - What the payloads may grant

/// The fields of a StoreKit 2 transaction JWS that decide a mirrored purchase.
nonisolated struct SignedPurchasePayload: Decodable, Sendable, Equatable {
    let bundleId: String
    let productId: String
    let originalTransactionId: String
    /// `Production` / `Sandbox` / `Xcode`.
    let environment: String
    let revocationDate: Double?
}

/// The fields of an `AppTransaction` JWS that decide a founder.
nonisolated struct SignedAppTransactionPayload: Decodable, Sendable, Equatable {
    let bundleId: String
    /// `Production` / `Sandbox` / `Xcode`.
    let receiptType: String
    let originalApplicationVersion: String
    /// Milliseconds since 1970.
    let originalPurchaseDate: Double
}

extension AppStoreSignature {
    /// Pure: the mirrored record is believed only when a verified payload
    /// vouches for EVERY field that grants — a production, non-revoked
    /// purchase of one of the two JellyGlass Pro products, by the app that
    /// sells it, with the record's own product, transaction and writer. A
    /// genuine JWS of any other app, or a record whose fields were edited
    /// around a genuine JWS, is refused.
    static func vouches(for record: CloudEntitlementRecord, payload: SignedPurchasePayload?) -> Bool {
        guard let payload,
              payload.environment == "Production",
              payload.revocationDate == nil,
              let soldHere = ProProduct.id(forBundleID: payload.bundleId),
              payload.productId == soldHere
        else { return false }
        return record.productID == payload.productId
            && record.originalTransactionID == payload.originalTransactionId
            && record.writerBundleID == payload.bundleId
    }

    func vouchesForPurchase(_ record: CloudEntitlementRecord) -> Bool {
        let payload = record.signedTransaction
            .flatMap(payload(of:))
            .flatMap { try? JSONDecoder().decode(SignedPurchasePayload.self, from: $0) }
        return Self.vouches(for: record, payload: payload)
    }

    /// Pure: the founder facts the OTHER app published, rebuilt from the
    /// verified payload alone — never from the record's sibling fields, which
    /// anyone with write access to the store could edit around a genuine JWS.
    /// `nil` unless it is a production app transaction of `expectedBundleID`.
    static func founderFacts(payload: SignedAppTransactionPayload?, jws: String, expectedBundleID: String) -> AppTransactionSnapshot? {
        guard let payload, payload.bundleId == expectedBundleID, payload.receiptType == "Production" else { return nil }
        return AppTransactionSnapshot(
            originalAppVersion: payload.originalApplicationVersion,
            originalPurchaseDate: Date(timeIntervalSince1970: payload.originalPurchaseDate / 1000),
            environment: .production,
            signedTransaction: jws
        )
    }

    func verifiedFounderFacts(_ published: AppTransactionSnapshot, expectedBundleID: String) -> AppTransactionSnapshot? {
        guard let jws = published.signedTransaction else { return nil }
        let payload = payload(of: jws).flatMap { try? JSONDecoder().decode(SignedAppTransactionPayload.self, from: $0) }
        return Self.founderFacts(payload: payload, jws: jws, expectedBundleID: expectedBundleID)
    }
}
