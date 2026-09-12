import Testing
@testable import Cinemax

/// Issue #175 — closing the player while in a Watch Together group used to
/// leave the group in silence. The decision "must we ask first?" is pure; the
/// presenter only turns a `true` into « Quitter la séance ? ».
@Suite("SyncPlayLeaveConfirmation — confirmer avant de quitter une séance")
struct SyncPlayLeaveConfirmationTests {

    @Test("Hors séance, fermer le lecteur ne demande rien — comportement inchangé")
    func outsideGroupNeverAsks() {
        #expect(!SyncPlayLeaveConfirmation.mustConfirm(isInGroup: false, origin: .user))
        #expect(!SyncPlayLeaveConfirmation.mustConfirm(isInGroup: false, origin: .system))
    }

    @Test("En séance, une fermeture demandée par l'utilisateur est confirmée")
    func userCloseInGroupAsks() {
        #expect(SyncPlayLeaveConfirmation.mustConfirm(isInGroup: true, origin: .user))
    }

    /// Le cas qui compte autant que l'autre : une lecture morte (erreur) ou
    /// terminée ne doit pas s'interposer entre l'utilisateur et la sortie.
    @Test("En séance, une fermeture système (erreur, fin de média) ne demande rien")
    func systemCloseInGroupDoesNotAsk() {
        #expect(!SyncPlayLeaveConfirmation.mustConfirm(isInGroup: true, origin: .system))
    }

    @Test("Table de vérité complète : seul (en séance, utilisateur) confirme",
          arguments: [true, false], [SyncPlayLeaveConfirmation.CloseOrigin.user, .system])
    func truthTable(isInGroup: Bool, origin: SyncPlayLeaveConfirmation.CloseOrigin) {
        let expected = isInGroup && origin == .user
        #expect(SyncPlayLeaveConfirmation.mustConfirm(isInGroup: isInGroup, origin: origin) == expected)
    }
}
