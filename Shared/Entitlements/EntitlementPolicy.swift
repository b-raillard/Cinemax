import Foundation

/// The pure resolution of Free / Pro. No state, no I/O — `EntitlementStore`
/// gathers the three inputs and `EntitlementTests` locks every branch.
nonisolated enum EntitlementPolicy {
    /// In order: a purchase recorded on this device, then the other
    /// platform's purchase read from the iCloud mirror, then — DEBUG builds
    /// only — the « Simuler Pro » switch. A Release build ignores
    /// `debugOverride` whatever the stored value says.
    static func resolve(
        localRecord: CloudEntitlementRecord?,
        cloudRecord: CloudEntitlementRecord?,
        debugOverride: Bool
    ) -> EntitlementState {
        if localRecord != nil { return .pro(.purchase) }
        if cloudRecord != nil { return .pro(.cloudMirror) }
        #if DEBUG
        if debugOverride { return .pro(.debugOverride) }
        #endif
        return .free
    }
}
