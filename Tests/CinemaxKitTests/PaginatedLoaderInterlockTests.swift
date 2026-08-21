import Testing
import Foundation
import CinemaxKit
@testable import Cinemax

/// Verrouille le contrat de concurrence de `PaginatedLoader` : `loadMore` et
/// `refreshLoadedSpan` s'excluent mutuellement, mais l'appel qui arrive pendant
/// qu'un autre est en vol est **mis en attente puis rejoué**, jamais abandonné.
///
/// Caractérisé en recette adversariale (scénarios `Rafr L2` et `Rafr L3`), où
/// l'ancien comportement — abandon silencieux, sans file ni réarmement —
/// produisait deux dégâts visibles :
///
/// - **rafraîchissement perdu** — deux bascules « vu » rapprochées, ou une
///   bascule pendant la pagination : la seconde était jetée, la vignette restait
///   affichée dans une grille « non vus » que le serveur savait pourtant à jour ;
/// - **pagination perdue** — un `loadMore` déclenché pendant un rafraîchissement
///   était jeté ; comme il naît de l'`.onAppear` de la dernière carte, déjà
///   apparue, plus rien ne le relançait.
///
/// La course n'est **pas observable par automatisation de gestes** : la fenêtre
/// vaut un aller-retour réseau (< 4 s mesuré sur appareil le 2026-08-21) là où un
/// aller-retour d'outil coûte ~7,7 s. D'où ces tests, qui tiennent la fenêtre
/// ouverte explicitement par une barrière plutôt que d'espérer la croiser.
@MainActor
@Suite("PaginatedLoader — file d'attente d'un cran")
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
        var lastLimit = 0
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

    /// Laisse une tâche concurrente atteindre son point de mise en attente.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test("Un rafraîchissement de portée arrivé pendant un autre est rejoué à la libération")
    func concurrentSpanRefreshIsReplayed() async {
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
        let second = Task {
            await loader.refreshLoadedSpan { _, _ in
                secondFetches.value += 1
                return (items: ["second", "second2"], total: 100)
            }
        }
        await settle()

        // Elle attend son tour : rien n'est parti sur le réseau.
        #expect(secondFetches.value == 0)

        gate.open()
        await first.value
        await second.value

        // Et elle est bien rejouée : la portée porte les données les plus fraîches.
        #expect(secondFetches.value == 1)
        #expect(loader.items == ["second", "second2"])
        #expect(loader.isLoadingMore == false)
    }

    @Test("Une pagination déclenchée pendant un rafraîchissement est rejouée")
    func loadMoreDuringSpanRefreshIsReplayed() async {
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
        let paging = Task {
            await loader.loadMore { startIndex in
                pageFetches.value += 1
                pageFetches.lastLimit = startIndex
                return (items: ["c", "d"], total: 100)
            }
        }
        await settle()
        #expect(pageFetches.value == 0)

        gate.open()
        await refresh.value
        await paging.value

        // La page suivante arrive, et son index de départ tient compte de la
        // portée rafraîchie entre-temps.
        #expect(pageFetches.value == 1)
        #expect(pageFetches.lastLimit == 2)
        #expect(loader.items == ["a", "b", "c", "d"])
    }

    @Test("Un rafraîchissement arrivé pendant une pagination couvre aussi la page qui vient d'arriver")
    func spanRefreshDuringLoadMoreIsReplayed() async {
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
        let refresh = Task {
            await loader.refreshLoadedSpan { _, limit in
                refreshFetches.value += 1
                refreshFetches.lastLimit = limit
                return (items: ["frais1", "frais2", "frais3"], total: 99)
            }
        }
        await settle()
        #expect(refreshFetches.value == 0)

        gate.open()
        await paging.value
        await refresh.value

        // La portée est lue APRÈS l'attente : elle couvre les 4 éléments,
        // page fraîchement paginée comprise.
        #expect(refreshFetches.lastLimit == 4)
        #expect(loader.items == ["frais1", "frais2", "frais3"])
        #expect(loader.totalCount == 99)
    }

    @Test("Deux rafraîchissements en attente se fondent en un seul rejeu")
    func redundantSpanRefreshCoalesces() async {
        let loader = await seededLoader()
        let gate = Gate()
        let queuedFetches = Counter()

        let first = Task {
            await loader.refreshLoadedSpan { _, _ in
                await gate.wait()
                return (items: ["premier", "premier2"], total: 100)
            }
        }
        await waitUntilLoading(loader)

        // Trois bascules « vu » d'affilée pendant la même fenêtre : une seule
        // requête doit en sortir, elles demandent toutes la même chose.
        let second = Task {
            await loader.refreshLoadedSpan { _, _ in
                queuedFetches.value += 1
                return (items: ["frais", "frais2"], total: 100)
            }
        }
        let third = Task {
            await loader.refreshLoadedSpan { _, _ in
                queuedFetches.value += 1
                return (items: ["frais", "frais2"], total: 100)
            }
        }
        await settle()

        gate.open()
        await first.value
        await second.value
        await third.value

        #expect(queuedFetches.value == 1)
        #expect(loader.items == ["frais", "frais2"])
    }

    @Test("Un `reset()` pendant l'attente annule l'appel en file plutôt que de le rejouer")
    func resetDiscardsQueuedCall() async {
        let loader = await seededLoader()
        let gate = Gate()
        let queuedFetches = Counter()

        let first = Task {
            await loader.refreshLoadedSpan { _, _ in
                await gate.wait()
                return (items: ["premier", "premier2"], total: 100)
            }
        }
        await waitUntilLoading(loader)

        let queued = Task {
            await loader.refreshLoadedSpan { _, _ in
                queuedFetches.value += 1
                return (items: ["obsolete"], total: 1)
            }
        }
        await settle()

        // L'utilisateur change de filtre : la portée en attente ne décrit plus
        // rien d'affiché.
        loader.reset()
        gate.open()
        await first.value
        await queued.value

        #expect(queuedFetches.value == 0)
        #expect(loader.items.isEmpty)
        #expect(loader.isLoadingMore == false)
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
