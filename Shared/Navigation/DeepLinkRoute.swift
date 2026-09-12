import Foundation

/// The one reading of an inbound link, whatever carried it.
///
/// Two carriers reach `AppState.handleDeepLink`:
/// - the custom scheme `cinemax://item/{id}` / `cinemax://home`, emitted by the
///   app's own extensions (widget posters, tvOS Top Shelf). Any app can
///   register the same scheme, so it is never trusted with more than
///   navigation — see the "never add a play verb" RULE;
/// - Universal Links `https://<host>/item/{id}` / `https://<host>/home`, which
///   iOS delivers only after verifying the host's `apple-app-site-association`
///   against this app's Team ID, so a link shared outside the app (Messages,
///   Handoff, Spotlight) cannot be hijacked by another app.
///
/// Both map onto the SAME two destinations, deliberately: the Universal Link
/// form is a safer carrier, not a richer one. The item id goes through
/// `AppState.isValidItemId` for both, so a malformed link is dropped before it
/// can drive a lookup with attacker-controlled path text.
nonisolated enum DeepLinkRoute: Equatable {
    case item(id: String)
    case home

    /// The Universal Links host the iOS entitlement names (`applinks:`). One
    /// constant on purpose: the AASA lives at that host's root, and the
    /// entitlement in `project.yml` must carry the same value.
    static let universalLinkHost = "b-raillard.github.io"

    static let customScheme = "cinemax"

    static func parse(_ url: URL, isValidItemId: (String) -> Bool) -> DeepLinkRoute? {
        // Host and path are case-folded where DNS and Apple do: the scheme and
        // host are case-insensitive, the path is not — but `item` / `home` are
        // ours, so a capitalised segment is a malformed link, not a variant.
        let scheme = url.scheme?.lowercased()
        let segments: [String]
        switch scheme {
        case customScheme:
            // `cinemax://item/<id>` — the verb is the HOST of the custom form.
            guard let verb = url.host()?.lowercased() else { return nil }
            segments = [verb] + url.pathComponents.filter { $0 != "/" }
        case "https":
            guard url.host()?.lowercased() == universalLinkHost else { return nil }
            segments = url.pathComponents.filter { $0 != "/" }
        default:
            return nil
        }

        switch segments.count {
        case 1 where segments[0] == "home":
            return .home
        case 2 where segments[0] == "item":
            let id = segments[1]
            return isValidItemId(id) ? .item(id: id) : nil
        default:
            // Extra segments, a bare `/item`, an unknown verb: dropped rather
            // than guessed at. Query and fragment are simply never read.
            return nil
        }
    }
}
