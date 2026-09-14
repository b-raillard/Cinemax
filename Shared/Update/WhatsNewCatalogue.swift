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
}

/// The pages one released version introduced.
struct WhatsNewRelease: Equatable, Sendable {
    let version: ServerVersion
    let pages: [WhatsNewPage]
}

/// What each version of Cinemax announced about itself.
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
        WhatsNewRelease(version: ServerVersion(2, 1, 0), pages: [
            WhatsNewPage(id: "watchTogether", illustration: .watchTogether),
            WhatsNewPage(id: "playOn", illustration: .playOn),
            WhatsNewPage(id: "playlists", illustration: .playlists),
            WhatsNewPage(id: "subtitles", illustration: .subtitles)
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

    /// Every page the app can show, newest first — what Réglages → Nouveautés
    /// replays, independently of what this user has already seen.
    static func allPages(in catalogue: [WhatsNewRelease] = releases) -> [WhatsNewPage] {
        Array(catalogue.sorted { $0.version > $1.version }.flatMap(\.pages).prefix(maxPages))
    }
}
