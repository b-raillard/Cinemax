import Testing
import Foundation
import JellyfinAPI
@testable import Cinemax

/// Verrouille le saut automatique d'intro / de générique (#160).
///
/// Les deux réglages sont OPT-IN : tout éteint, la politique répond `.none`
/// quelle que soit l'entrée, et les présentateurs se comportent au bit près
/// comme avant. Le reste est ce qui empêche l'automatisme de faire pire que
/// le bouton : une seule action par segment, jamais en pause, jamais dans un
/// groupe « Regarder ensemble ».
@Suite("Saut automatique — politique")
struct AutoSkipPolicyTests {

    private func decide(
        _ type: MediaSegmentType?,
        intro: Bool = true, credits: Bool = true,
        alreadySkipped: Bool = false, isPlaying: Bool = true,
        inGroup: Bool = false, canHandOff: Bool = false,
        remaining: Double = 60, isEpisode: Bool = true
    ) -> AutoSkipPolicy.Action {
        AutoSkipPolicy.decide(
            segmentType: type, autoSkipIntro: intro, autoSkipCredits: credits,
            alreadySkipped: alreadySkipped, isPlaying: isPlaying,
            inSyncPlayGroup: inGroup,
            handOff: canHandOff ? .init(secondsRemaining: remaining, isEpisode: isEpisode) : nil
        )
    }

    @Test("Tout éteint : jamais d'action, pour aucun segment")
    func offMeansNone() {
        #expect(decide(.intro, intro: false, credits: false) == .none)
        #expect(decide(.outro, intro: false, credits: false, canHandOff: true) == .none)
    }

    @Test("Intro activée : saut à la fin du segment")
    func introSeeks() {
        #expect(decide(.intro, credits: false) == .seekToEnd)
    }

    @Test("Le réglage intro ne touche pas au générique, et réciproquement")
    func togglesAreIndependent() {
        #expect(decide(.outro, intro: true, credits: false) == .none)
        #expect(decide(.intro, intro: false, credits: true) == .none)
    }

    @Test("Générique avec épisode suivant : enchaînement immédiat")
    func creditsHandOff() {
        #expect(decide(.outro, canHandOff: true) == .handOffToNext)
    }

    @Test("Générique sans suivant : saut à la fin, la fin de lecture ordinaire prend le relais")
    func creditsWithoutNextSeeks() {
        #expect(decide(.outro, canHandOff: false) == .seekToEnd)
    }

    @Test("Générique détecté 13 min avant la fin : pas d'enchaînement, saut à la fin du segment")
    func creditsTooEarlyDoNotHandOff() {
        // Mesuré le 2026-09-04 : un générique ouvert 788 s avant la fin. Enchaîner
        // là laissait 13 minutes non vues et rapportait l'arrêt au début du segment.
        #expect(decide(.outro, canHandOff: true, remaining: 788) == .seekToEnd)
    }

    @Test("Le plafond du compte à rebours borne l'enchaînement, au même seuil")
    func handOffObeysTheCountdownCap() {
        let cap = NextUpCountdownPolicy.episodeMaxSeconds
        #expect(decide(.outro, canHandOff: true, remaining: cap) == .handOffToNext)
        #expect(decide(.outro, canHandOff: true, remaining: cap + 1) == .seekToEnd)
        // Durée inconnue ou déjà dépassée : jamais d'enchaînement anticipé.
        #expect(decide(.outro, canHandOff: true, remaining: 0) == .seekToEnd)
        #expect(decide(.outro, canHandOff: true, remaining: -5) == .seekToEnd)
    }

    @Test("Un film (« Tout lire ») n'a pas de plafond : son générique peut durer dix minutes")
    func filmCreditsHaveNoCap() {
        #expect(decide(.outro, canHandOff: true, remaining: 600, isEpisode: false) == .handOffToNext)
    }

    @Test("L'intro ne dépend pas du temps restant")
    func introIgnoresRemaining() {
        #expect(decide(.intro, credits: false, remaining: 3000) == .seekToEnd)
    }

    @Test("Un segment déjà sauté ne l'est pas deux fois (retour arrière dans l'intro)")
    func onlyOnce() {
        #expect(decide(.intro, alreadySkipped: true) == .none)
        #expect(decide(.outro, alreadySkipped: true, canHandOff: true) == .none)
    }

    @Test("En pause : rien ne bouge")
    func pausedIsSilent() {
        #expect(decide(.intro, isPlaying: false) == .none)
    }

    @Test("Dans un groupe SyncPlay : le groupe possède la tête de lecture")
    func groupIsSilent() {
        #expect(decide(.intro, inGroup: true) == .none)
        #expect(decide(.outro, inGroup: true, canHandOff: true) == .none)
    }

    @Test("Type inconnu ou absent : laissé tranquille")
    func unknownTypeIsSilent() {
        #expect(decide(nil) == .none)
        #expect(decide(.recap) == .none)
    }

    @Test("La clé d'identité distingue type et début")
    func keyIdentity() {
        #expect(AutoSkipPolicy.key(type: .intro, startTicks: 10) == AutoSkipPolicy.key(type: .intro, startTicks: 10))
        #expect(AutoSkipPolicy.key(type: .intro, startTicks: 10) != AutoSkipPolicy.key(type: .outro, startTicks: 10))
        #expect(AutoSkipPolicy.key(type: .intro, startTicks: 10) != AutoSkipPolicy.key(type: .intro, startTicks: 11))
    }

    @Test("Préférences : clé absente ⇒ défaut (éteint), clé posée ⇒ lue")
    func preferencesRead() {
        let suite = "AutoSkipPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AutoSkipPreferences.current(defaults: defaults) == .off)
        defaults.set(true, forKey: SettingsKey.autoSkipIntro)
        #expect(AutoSkipPreferences.current(defaults: defaults) == AutoSkipPreferences(intro: true, credits: false))
    }
}
