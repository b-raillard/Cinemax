import Foundation

/// Whether closing the player must first ask « Quitter la séance ? ».
///
/// **RULE — ask only for a close the USER asked for, and only inside a group.**
/// The player's teardown leaves the Watch Together group
/// (`SyncPlayController.playbackDidDismiss` — v1 ties the group's lifetime to
/// the player), so a swipe-down on iOS or a Menu press on tvOS used to walk the
/// viewer out of a session in silence, the lobby being the only other exit
/// (issue #175). The fix keeps that coupling and puts a question in front of
/// it: « Quitter la séance » closes exactly as before, « Annuler » leaves the
/// player — and the group — untouched.
///
/// A **system** close is never questioned: the playback is already dead or
/// over (the error alert's « Fermer », the failed-autoplay alert, a film ending
/// with no next item), so there is nothing left to stay for, and a question
/// would only stand between the viewer and a player that cannot play.
enum SyncPlayLeaveConfirmation {

    /// Who asked the player to close.
    enum CloseOrigin: Equatable, Sendable {
        /// The viewer did: iOS close button and swipe-down, tvOS Menu on bare
        /// video, the end-of-series « Terminé » (the Menu peel on that same
        /// card already counted as the user's close, and one of the card's two
        /// exits must not be the one that skips the question), and the sleep
        /// prompt's « Arrêter » — which says "stop watching", not "leave the
        /// group", so the consequence still has to be spelled out.
        case user
        /// The player closes itself because playback failed or ended.
        case system
    }

    static func mustConfirm(isInGroup: Bool, origin: CloseOrigin) -> Bool {
        isInGroup && origin == .user
    }
}
