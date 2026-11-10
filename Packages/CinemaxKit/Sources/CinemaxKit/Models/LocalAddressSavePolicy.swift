import Foundation

/// What saving a typed LAN address came to — the toast / message the UI shows.
public enum LocalAddressSaveOutcome: Equatable, Sendable {
    /// The field was blank: the local address is gone.
    case removed
    /// The same server answered on the LAN address: saved.
    case reachable
    /// Nothing answered (typed away from home), its host already pinned: saved.
    case savedUnreachable
    /// The system refused the local-network access: saved, unusable until allowed.
    case savedLocalNetworkDenied
    /// Not a LAN address, or the connection did not land on a local peer.
    case refusedNotLocal
    /// A different Jellyfin server (`Id`) answered: nothing saved.
    case refusedOtherServer
    /// Neither the public URL nor the LAN address could say which server this
    /// is (no known `serverID`): nothing saved.
    case needsSignIn
    /// `http://` typed: the LAN address is https only (owner amendment).
    case refusedNotHTTPS
    /// The LAN certificate is unpinned or CHANGED: nothing saved, approval offered.
    case needsCertificateApproval
    /// Saved while unreachable, its host not pinned yet: usable once its
    /// certificate is approved (save again from home).
    case savedNeedsApproval
}

/// The LAN certificate's standing when the probe failed.
public enum LocalCertificateState: Equatable, Sendable {
    /// The host carries a pin.
    case trusted
    /// The trust delegate refused a leaf for that host and holds its summary.
    case pendingApproval
    /// No pin and nothing pending (nothing answered).
    case unknown
}

public struct LocalAddressSaveDecision: Equatable, Sendable {
    public let outcome: LocalAddressSaveOutcome
    public let saves: Bool
    /// The Jellyfin `Id` to record on an entry that had none.
    public let serverIDToAdopt: String?

    public init(outcome: LocalAddressSaveOutcome, saves: Bool, serverIDToAdopt: String?) {
        self.outcome = outcome
        self.saves = saves
        self.serverIDToAdopt = serverIDToAdopt
    }
}

/// The owner's decision table for saving a LAN address (spec « Missing
/// `serverID` » and « Amendment — HTTPS only, pinned certificate »). The
/// expected id is the entry's own, else the one the public URL just reported;
/// with neither, the LAN `Id` is adopted on a one-time, hand-typed setup.
public enum LocalAddressSavePolicy {
    public static func decide(
        knownServerID: String?,
        publicServerID: String?,
        probe: LocalProbeOutcome,
        certificate: LocalCertificateState
    ) -> LocalAddressSaveDecision {
        let known = nonEmpty(knownServerID)
        let learned = nonEmpty(publicServerID)
        // Adopted on every saving row when the entry had no id: without one,
        // the route owner never dials the LAN address.
        let adoptable = known == nil ? learned : nil
        switch probe {
        case .answered(let serverID, let connectedAddressIsLocal):
            return answered(serverID: serverID, isLocal: connectedAddressIsLocal,
                            expected: known ?? learned, adoptable: adoptable)
        case .failed(let localNetworkDenied):
            return failed(denied: localNetworkDenied, certificate: certificate,
                          expected: known ?? learned, adoptable: adoptable)
        }
    }

    private static func answered(serverID: String, isLocal: Bool, expected: String?, adoptable: String?) -> LocalAddressSaveDecision {
        guard isLocal else { return refusal(.refusedNotLocal) }
        guard let expected else {
            return LocalAddressSaveDecision(outcome: .reachable, saves: true, serverIDToAdopt: serverID)
        }
        guard serverID == expected else { return refusal(.refusedOtherServer) }
        return LocalAddressSaveDecision(outcome: .reachable, saves: true, serverIDToAdopt: adoptable)
    }

    private static func failed(
        denied: Bool, certificate: LocalCertificateState, expected: String?, adoptable: String?
    ) -> LocalAddressSaveDecision {
        // A refused leaf comes first, whatever is known: approving it is what
        // makes the save pass.
        if certificate == .pendingApproval { return refusal(.needsCertificateApproval) }
        guard expected != nil else { return refusal(.needsSignIn) }
        let outcome: LocalAddressSaveOutcome
        if denied {
            outcome = .savedLocalNetworkDenied
        } else {
            outcome = certificate == .unknown ? .savedNeedsApproval : .savedUnreachable
        }
        return LocalAddressSaveDecision(outcome: outcome, saves: true, serverIDToAdopt: adoptable)
    }

    private static func refusal(_ outcome: LocalAddressSaveOutcome) -> LocalAddressSaveDecision {
        LocalAddressSaveDecision(outcome: outcome, saves: false, serverIDToAdopt: nil)
    }

    private static func nonEmpty(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return id
    }
}
