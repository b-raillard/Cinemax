import Foundation
import Testing
@testable import Cinemax

/// La demande de note sur l'App Store : elle ne vise que quelqu'un qui a
/// vraiment regardé quelque chose, une fois par version, et jamais deux fois
/// en trois mois.
@Suite("Demande de note — politique")
struct ReviewPromptPolicyTests {

    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    @Test("Une séance compte à partir de 600 s, pas 599")
    func qualifiesFromTenMinutes() {
        #expect(ReviewPromptPolicy.qualifies(watchedSeconds: 600))
        #expect(!ReviewPromptPolicy.qualifies(watchedSeconds: 599))
        #expect(!ReviewPromptPolicy.qualifies(watchedSeconds: 0))
    }

    @Test("Pas assez de séances : on ne demande rien")
    func notEnoughPlaybacks() {
        #expect(!ReviewPromptPolicy.shouldPrompt(
            qualifyingPlaybacks: 2, installedVersion: "2.3.0",
            lastPromptedVersion: nil, lastPromptedAt: nil, now: now
        ))
    }

    @Test("Exactement trois séances : on demande")
    func promptsAtExactlyThree() {
        #expect(ReviewPromptPolicy.shouldPrompt(
            qualifyingPlaybacks: 3, installedVersion: "2.3.0",
            lastPromptedVersion: nil, lastPromptedAt: nil, now: now
        ))
    }

    @Test("Même version déjà sollicitée : jamais une deuxième fois")
    func sameVersionBlocks() {
        #expect(!ReviewPromptPolicy.shouldPrompt(
            qualifyingPlaybacks: 10, installedVersion: "2.3.0",
            lastPromptedVersion: "2.3.0", lastPromptedAt: now.addingTimeInterval(-365 * day), now: now
        ))
    }

    @Test("Nouvelle version et dernière demande ancienne : on demande")
    func newVersionAndOldDatePrompts() {
        #expect(ReviewPromptPolicy.shouldPrompt(
            qualifyingPlaybacks: 3, installedVersion: "2.4.0",
            lastPromptedVersion: "2.3.0", lastPromptedAt: now.addingTimeInterval(-91 * day), now: now
        ))
    }

    @Test("Nouvelle version mais 89 jours seulement : on attend")
    func newVersionButTooRecentBlocks() {
        #expect(!ReviewPromptPolicy.shouldPrompt(
            qualifyingPlaybacks: 3, installedVersion: "2.4.0",
            lastPromptedVersion: "2.3.0", lastPromptedAt: now.addingTimeInterval(-89 * day), now: now
        ))
    }

    @Test("Une date de demande dans le futur (horloge reculée) ne bloque pas")
    func futureStampDoesNotBlock() {
        #expect(ReviewPromptPolicy.shouldPrompt(
            qualifyingPlaybacks: 3, installedVersion: "2.4.0",
            lastPromptedVersion: "2.3.0", lastPromptedAt: now.addingTimeInterval(10 * day), now: now
        ))
    }

    @Test("Jamais sollicité : on demande")
    func nilStampsPrompt() {
        #expect(ReviewPromptPolicy.shouldPrompt(
            qualifyingPlaybacks: 3, installedVersion: "2.3.0",
            lastPromptedVersion: nil, lastPromptedAt: nil, now: now
        ))
    }
}

#if os(iOS)
@MainActor
@Suite("Demande de note — suivi")
struct ReviewPromptTrackerTests {

    private let watched = ReviewPromptPolicy.minimumWatchedSeconds

    private func tracker(_ defaults: UserDefaults, version: String? = "2.3.0") -> ReviewPromptTracker {
        ReviewPromptTracker(defaults: defaults, installedVersion: version)
    }

    @Test("Les séances courtes ne comptent pas")
    func shortSessionsDoNotCount() {
        let sut = tracker(UserDefaults.isolatedForTesting())
        for _ in 0..<5 { sut.recordSession(watchedSeconds: watched - 1) }
        sut.playerDidClose()
        #expect(!sut.isDue)
    }

    @Test("Trois séances de 600 s puis fermeture du lecteur : la demande est due")
    func threeSessionsThenCloseIsDue() {
        let sut = tracker(UserDefaults.isolatedForTesting())
        for _ in 0..<3 { sut.recordSession(watchedSeconds: watched) }
        sut.playerDidClose()
        #expect(sut.isDue)
    }

    @Test("Lecteur encore ouvert : compter ne suffit pas à rendre la demande due")
    func recordingAloneNeverMakesItDue() {
        let sut = tracker(UserDefaults.isolatedForTesting())
        for _ in 0..<5 { sut.recordSession(watchedSeconds: watched) }
        #expect(!sut.isDue)
    }

    @Test("Un lecteur rouvert avant la demande la retire, sans rien estampiller")
    func reopeningThePlayerWithdrawsTheRequest() {
        let defaults = UserDefaults.isolatedForTesting()
        let sut = tracker(defaults)
        for _ in 0..<3 { sut.recordSession(watchedSeconds: watched) }
        sut.playerDidClose()
        #expect(sut.isDue)

        sut.playerDidOpen()
        #expect(!sut.isDue)
        #expect(defaults.integer(forKey: SettingsKey.reviewQualifyingPlaybacks) == 3)
        #expect((defaults.string(forKey: SettingsKey.reviewLastPromptedVersion) ?? "").isEmpty)

        // The next close asks again.
        sut.playerDidClose()
        #expect(sut.isDue)
    }

    @Test("didPrompt estampille, remet le compte à zéro et éteint isDue")
    func didPromptStampsAndResets() {
        let defaults = UserDefaults.isolatedForTesting()
        let sut = tracker(defaults)
        for _ in 0..<3 { sut.recordSession(watchedSeconds: watched) }
        sut.playerDidClose()
        #expect(sut.isDue)

        let promptedAt = Date(timeIntervalSince1970: 2_000_000_000)
        sut.didPrompt(now: promptedAt)
        #expect(!sut.isDue)
        #expect(defaults.string(forKey: SettingsKey.reviewLastPromptedVersion) == "2.3.0")
        #expect(defaults.double(forKey: SettingsKey.reviewLastPromptedAt) == promptedAt.timeIntervalSince1970)
        #expect(defaults.integer(forKey: SettingsKey.reviewQualifyingPlaybacks) == 0)

        sut.playerDidClose(now: promptedAt.addingTimeInterval(60))
        #expect(!sut.isDue)
    }

    @Test("Le compte survit à un nouveau suivi sur les mêmes réglages")
    func countSurvivesNewTracker() {
        let defaults = UserDefaults.isolatedForTesting()
        let first = tracker(defaults)
        for _ in 0..<2 { first.recordSession(watchedSeconds: watched) }

        let second = tracker(defaults)
        second.recordSession(watchedSeconds: watched)
        second.playerDidClose()
        #expect(second.isDue)
    }

    @Test("Version déjà sollicitée : jamais due")
    func alreadyPromptedVersionNeverDue() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("2.3.0", forKey: SettingsKey.reviewLastPromptedVersion)
        let sut = tracker(defaults)
        for _ in 0..<10 { sut.recordSession(watchedSeconds: watched) }
        sut.playerDidClose()
        #expect(!sut.isDue)
    }
}
#endif
