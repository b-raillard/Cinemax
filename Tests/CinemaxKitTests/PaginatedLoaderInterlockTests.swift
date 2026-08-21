import Testing
import Foundation
import CinemaxKit
@testable import Cinemax

/// Verrouille le comportement de la garde `!isLoadingMore` de `PaginatedLoader`,
/// caractérisé en recette adversariale (scénarios `Rafr L2` et `Rafr L3`).
///
/// `loadMore` et `refreshLoadedSpan` partagent le drapeau `isLoadingMore` et
/// s'excluent mutuellement. Chacun le pose pour toute la durée de son
/// aller-retour réseau, et l'appel qui arrive pendant est **abandonné en
/// silence** : pas de file d'attente, pas de réarmement, aucune trace.
///
/// Ce n'est pas une régression mais un manque par construction, et il n'est
/// **pas observable par automatisation de gestes** : la fenêtre vaut un
/// aller-retour réseau (< 4 s mesuré sur appareil le 2026-08-21) là où un
/// aller-retour d'outil coûte ~7,7 s. D'où ces tests, qui tiennent la fenêtre
/// ouverte explicitement par une barrière plutôt que d'espérer la croiser.
///
/// Les conséquences produit à trancher, dans les deux sens :
///
/// - **Rafraîchissement perdu** — deux bascules « vu » rapprochées, ou une
///   bascule pendant la pagination : la seconde notification est jetée, la
///   vignette reste affichée dans une grille « non vus » que le serveur sait
///   pourtant à jour. L'écran et le serveur se contredisent sans que rien ne
///   le signale.
/// - **Pagination perdue** — un `loadMore` déclenché pendant un
///   rafraîchissement est jeté ; comme il est déclenché par l'`.onAppear` de la
///   dernière carte, et que cette carte est déjà apparue, plus rien ne le
///   relance : la pagination reste bloquée tant que l'utilisateur ne remonte
///   pas de deux écrans avant de redescendre.
@MainActor
@Suite("PaginatedLoader — exclusion mutuelle")
struct PaginatedLoaderInterlockTests {

    /// Barrière explicite : elle maintient un `fetch` suspendu pour que la
    /// fenêtre de course soit tenue ouverte au lieu d'être devinée.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class Counter {
        var value = 0
    }

    /// Amorce le chargeur avec une première page, sans quoi
    /// `refreshLoadedSpan` sort d'emblée sur `guard !items.isEmpty`.
    private func seededLoader(total: Int = 100) async -> PaginatedLoader<String> {
        let loader = PaginatedLoader<String>(pageSize: 40)
        await loader.loadMore { _ in (items: ["a", "b"], total: total) }
        return loader
    }

    /// Rend la main jusqu'à ce que la passe suspendue ait bien posé le drapeau,
    /// plutôt que de parier sur un `Task.yield()` unique.
    private func waitUntilLoading(_ loader: PaginatedLoader<String>) async {
        while !loader.isLoadingMore { await Task.yield() }
    }

    @Test("Un rafraîchissement de portée arrivé pendant un autre est jeté sans rattrapage")
    func concurrentSpanRefreshIsDropped() async {
        let loader = await seededLoader()
        let gate = Gate()
        let secondFetches = Counter()

        let first = Task {
            await loader.refreshLoadedSpan { _, _ in
                await gate.wait()
                return (items: ["premier", "premier2"], total: 100)
            }
        }
        await waitUntilLoading(loader)

        // Deuxième bascule « vu » pendant que la première est en vol.
        await loader.refreshLoadedSpan { _, _ in
            secondFetches.value += 1
            return (items: ["second", "second2"], total: 100)
        }

        // Elle n'a même pas atteint le réseau.
        #expect(secondFetches.value == 0)

        gate.open()
        await first.value

        // Et rien ne la rejoue : la portée porte les données du premier appel.
        #expect(loader.items == ["premier", "premier2"])
        #expect(secondFetches.value == 0)
        #expect(loader.isLoadingMore == false)
    }

    @Test("Une pagination déclenchée pendant un rafraîchissement est jetée, et rien ne la relance")
    func loadMoreDuringSpanRefreshIsDropped() async {
        let loader = await seededLoader()
        let gate = Gate()
        let pageFetches = Counter()

        let refresh = Task {
            await loader.refreshLoadedSpan { _, _ in
                await gate.wait()
                return (items: ["a", "b"], total: 100)
            }
        }
        await waitUntilLoading(loader)

        // L'`.onAppear` de la dernière carte pendant le rafraîchissement.
        await loader.loadMore { _ in
            pageFetches.value += 1
            return (items: ["c", "d"], total: 100)
        }
        #expect(pageFetches.value == 0)

        gate.open()
        await refresh.value

        // La page suivante n'est jamais arrivée. Sur l'écran, la carte
        // déclencheuse est déjà apparue : son `.onAppear` ne se rejouera pas,
        // donc la pagination reste bloquée jusqu'à un aller-retour de
        // défilement.
        #expect(loader.items.count == 2)
        #expect(loader.hasLoadedAll == false)
    }

    @Test("Un rafraîchissement arrivé pendant une pagination est jeté")
    func spanRefreshDuringLoadMoreIsDropped() async {
        let loader = await seededLoader()
        let gate = Gate()
        let refreshFetches = Counter()

        let paging = Task {
            await loader.loadMore { _ in
                await gate.wait()
                return (items: ["c", "d"], total: 100)
            }
        }
        await waitUntilLoading(loader)

        // La bascule « vu » pendant que la roue de pied de page tourne.
        await loader.refreshLoadedSpan { _, _ in
            refreshFetches.value += 1
            return (items: ["frais"], total: 99)
        }
        #expect(refreshFetches.value == 0)

        gate.open()
        await paging.value

        // La page est bien arrivée, mais la bascule n'a laissé aucune trace :
        // le total reste celui d'avant.
        #expect(loader.items == ["a", "b", "c", "d"])
        #expect(loader.totalCount == 100)
    }

    @Test("Après relâchement de la garde, un nouvel appel repasse normalement")
    func guardReleasesAfterCompletion() async {
        let loader = await seededLoader()
        let gate = Gate()

        let first = Task {
            await loader.refreshLoadedSpan { _, _ in
                await gate.wait()
                return (items: ["premier", "premier2"], total: 100)
            }
        }
        await waitUntilLoading(loader)
        gate.open()
        await first.value

        // Rien n'est latché : la garde protège la seule durée de l'appel.
        await loader.refreshLoadedSpan { _, _ in
            (items: ["second", "second2"], total: 100)
        }
        #expect(loader.items == ["second", "second2"])
    }
}
