import Foundation
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "RemoteControl")

/// Hands an inbound `Playstate` command — pause / unpause / seek / stop / next /
/// previous, sent by another Jellyfin session — to whichever player is on
/// screen right now.
///
/// **Why a registry and not a path through the SwiftUI layer.** Both presenters
/// are UIKit modals raised from different hosts (`VideoPlayerCoordinator` on
/// tvOS, `VideoPlayerView` / `CardActionPresenter` on iOS), and neither is
/// reachable from `RemoteControlListener` without threading a reference through
/// every one of those hosts. The player itself knows when it exists, so it
/// registers here on open and unregisters on teardown — the smallest shape that
/// reaches both engines through one door.
///
/// **One slot, guarded by a token.** At most one player is ever on screen, so
/// the latest registration wins. `unregister` only clears the slot when the
/// token it is handed is still the current one: a teardown that runs AFTER the
/// next player has registered (an episode swap on the native path, a player
/// closed while another opens) must not take the new player's slot with it.
/// And a command arriving after the teardown finds an empty slot and is
/// dropped — which is the generation guard the feature needs: nothing can be
/// applied to a player that has gone.
@MainActor
final class RemotePlaystateRouter {
    static let shared = RemotePlaystateRouter()

    /// What happened to a command. Returned for the log line and for tests.
    enum Outcome: String, Equatable {
        /// The player applied it.
        case applied
        /// No player on screen — nothing to control.
        case noPlayer
        /// The viewer is in a Watch Together group: the group owns the
        /// playhead, and a remote transport command applied locally would
        /// desynchronise this participant from everyone else.
        case ignoredSyncPlay
        /// A player is on screen but the command has nothing to act on there
        /// (no next episode, media not open yet for a seek, player tearing down).
        case notApplicable
    }

    /// Returns whether the command was actually applied.
    typealias Handler = @MainActor (RemotePlaystateCommand) -> Bool

    private var handler: Handler?
    private var activeToken = 0
    private var lastToken = 0

    init() {}

    /// Registers the player now on screen. Keep the token; hand it back to
    /// `unregister` on teardown.
    func register(_ handler: @escaping Handler) -> Int {
        lastToken &+= 1
        if lastToken == 0 { lastToken = 1 } // 0 means "no player"
        activeToken = lastToken
        self.handler = handler
        return activeToken
    }

    /// Clears the slot — only if `token` is still the live registration.
    func unregister(_ token: Int) {
        guard token != 0, token == activeToken else { return }
        handler = nil
        activeToken = 0
    }

    var hasActivePlayer: Bool { handler != nil }

    @discardableResult
    func route(_ command: RemotePlaystateCommand, inSyncPlayGroup: Bool) -> Outcome {
        let outcome: Outcome
        if inSyncPlayGroup {
            outcome = .ignoredSyncPlay
        } else if let handler {
            outcome = handler(command) ? .applied : .notApplicable
        } else {
            outcome = .noPlayer
        }
        // Permanent, like `CINEMAX-AUDIO` / `CINEMAX-SYNCPLAY`: a remote
        // command that "did nothing" is otherwise invisible from both ends.
        // Command name and ticks only — never a URL, never a token.
        let seek = command.seekPositionTicks.map { " position=\($0)" } ?? ""
        logger.notice("CINEMAX-REMOTE ▸ Playstate \(command.kind.rawValue, privacy: .public)\(seek, privacy: .public) → \(outcome.rawValue, privacy: .public)")
        return outcome
    }
}
