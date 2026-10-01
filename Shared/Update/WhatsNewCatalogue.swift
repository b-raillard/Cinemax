import Foundation
import CinemaxKit

/// One page of the reel: an illustration, a title and a line of prose.
///
/// **`id` is both the page's identity and its localization key**
/// (`whatsNew.<id>.title` / `whatsNew.<id>.body`), so adding a page is one
/// entry here plus two strings — never a new type, never a new view. A feature
/// is announced once in the app's life, so the id stays unique across releases.
struct WhatsNewPage: Identifiable, Equatable, Sendable {
    let id: String
    let illustration: WhatsNewIllustration
    /// Something the page lets the user switch on in one tap (« Activer »).
    var offer: WhatsNewOffer?
}

/// A one-tap opt-in carried by a page. Data like the rest of the page, so the
/// next season's announcement is one more entry.
enum WhatsNewOffer: Equatable, Sendable {
    /// Turns the seasonal themes on (`SeasonalSetting.automatic`); `id` names
    /// the catalogue season the page shows off — its dates and title face.
    case seasonalTheme(id: String)
    /// Switches the app to its device's language. The CATALOGUE carries this
    /// placeholder; `resolvingOffers` turns it into `.appLanguage(code:)` for
    /// an install whose device speaks a shipped language the app does not
    /// already use, and drops the page for everybody else.
    case deviceLanguage
    /// The resolved form — what the pager acts on.
    case appLanguage(code: String)
}

/// The pages one released version introduced.
struct WhatsNewRelease: Equatable, Sendable {
    let version: ServerVersion
    let pages: [WhatsNewPage]
}

/// What each version of the app announced about itself.
///
/// **Deliberately DATA, not code.** Publishing a version means writing its
/// pages here and their two strings in both catalogues — nothing else. That is
/// what stops the reel from rotting: there is no per-version view to write, and
/// therefore none to forget to update.
enum WhatsNewCatalogue {
    /// A wall of pages is not a welcome. Somebody who skipped three versions
    /// gets the newest ones and not a history lesson.
    static let maxPages = 6

    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(version: ServerVersion(2, 3, 1), pages: [
            WhatsNewPage(id: "language", illustration: .language, offer: .deviceLanguage)
        ]),
        WhatsNewRelease(version: ServerVersion(2, 3, 0), pages: [
            WhatsNewPage(id: "halloweenNight", illustration: .halloweenNight, offer: .seasonalTheme(id: "halloween"))
        ]),
        WhatsNewRelease(version: ServerVersion(2, 2, 0), pages: [
            WhatsNewPage(id: "newName", illustration: .newName),
            WhatsNewPage(id: "parentalLock", illustration: .parentalLock),
            WhatsNewPage(id: "accessibility", illustration: .accessibility)
        ]),
        WhatsNewRelease(version: ServerVersion(2, 1, 1), pages: [
            WhatsNewPage(id: "underTheHood", illustration: .underTheHood)
        ]),
        WhatsNewRelease(version: ServerVersion(2, 1, 0), pages: [
            WhatsNewPage(id: "watchTogether", illustration: .watchTogether),
            WhatsNewPage(id: "playOn", illustration: .playOn),
            WhatsNewPage(id: "playlists", illustration: .playlists)
        ])
    ]

    /// Every page introduced after `lastSeen` and no later than `installed`,
    /// **newest release first**, capped at `maxPages`.
    ///
    /// Three properties worth stating:
    ///
    /// - `lastSeen == nil` takes everything up to `installed`. That is an
    ///   install upgrading from a build that predates the reel, and showing it
    ///   what changed is the point; a genuine first run never reaches here
    ///   (`WhatsNewPolicy` answers `.stampOnly` for it).
    /// - Releases **newer than this build are excluded**, so a catalogue entry
    ///   written while preparing the next version — the ordinary way a version
    ///   is prepared — cannot leak into the current one's reel.
    /// - Newest first, so the cap drops the OLDEST pages. Somebody who skipped
    ///   several versions is most interested in the latest.
    static func pages(
        since lastSeen: ServerVersion?,
        upTo installed: ServerVersion,
        in catalogue: [WhatsNewRelease] = releases
    ) -> [WhatsNewPage] {
        let relevant = catalogue
            .filter { release in
                guard release.version <= installed else { return false }
                guard let lastSeen else { return true }
                return release.version > lastSeen
            }
            .sorted { $0.version > $1.version }
        return Array(relevant.flatMap(\.pages).prefix(maxPages))
    }

    /// Resolves the pages whose content depends on this install: a
    /// `.deviceLanguage` page becomes an offer of the device's language when
    /// that language is shipped and not the one in use (`AppLanguage.offer`),
    /// and disappears otherwise — a page offering the language the app
    /// already speaks would be a button that does nothing. Applied BEFORE
    /// `WhatsNewPolicy` decides, so a version whose only page drops out is a
    /// silent stamp, not an empty reel.
    static func resolvingOffers(
        _ pages: [WhatsNewPage], appLanguage: String, preferredLanguages: [String]
    ) -> [WhatsNewPage] {
        pages.compactMap { page in
            guard page.offer == .deviceLanguage else { return page }
            guard let code = AppLanguage.offer(current: appLanguage, preferredLanguages: preferredLanguages) else {
                return nil
            }
            var resolved = page
            resolved.offer = .appLanguage(code: code)
            return resolved
        }
    }

    /// Every page the app can show, newest first — what Réglages → Nouveautés
    /// replays, independently of what this user has already seen.
    static func allPages(in catalogue: [WhatsNewRelease] = releases) -> [WhatsNewPage] {
        Array(catalogue.sorted { $0.version > $1.version }.flatMap(\.pages).prefix(maxPages))
    }
}
