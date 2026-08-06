import Foundation
import CinemaxKit
import JellyfinAPI

/// Ce qu'une carte doit connaître pour lancer une lecture : quoi ouvrir, sous
/// quel titre, et à quelle seconde reprendre.
struct CardPlayTarget: Sendable, Equatable {
    let itemId: String
    let title: String
    /// `nil` ⇒ lecture depuis le début.
    let startSeconds: Double?
}

/// Résout la cible de lecture d'une vignette.
///
/// **Ce que ce résolveur ne fait PAS** : choisir l'épisode d'une série quand
/// l'information manque. `getPlaybackInfo` résout déjà Series/Season → Episode
/// côté CinemaxKit (`resolvePlayableEpisode` — next-up d'abord, sinon premier
/// épisode de la première saison), et dupliquer cette décision créerait deux
/// autorités qui peuvent diverger. Il ne sert qu'à récupérer **la position de
/// reprise**, plus l'id de l'épisode quand le sondage next-up le donne — auquel
/// cas on cible directement l'épisode, pour que l'offset et l'item décrivent
/// forcément le même média.
///
/// Volontairement `nonisolated` et paramétré par des **scalaires** : passer un
/// `BaseItemDto` (non-`Sendable`) dans un appel async nonisolated depuis le
/// `@MainActor` est un transfert de région d'une valeur que l'acteur principal
/// détient toujours. L'appelant extrait les champs côté main actor.
enum CardPlayTargetResolver {

    static func resolve(
        itemId: String,
        type: BaseItemKind?,
        title: String,
        positionTicks: Int,
        isPlayed: Bool,
        api: any LibraryAPI,
        userId: String
    ) async -> CardPlayTarget {
        guard type == .series else {
            return CardPlayTarget(
                itemId: itemId,
                title: title,
                startSeconds: resumeSeconds(positionTicks: positionTicks, isPlayed: isPlayed)
            )
        }

        // Une carte de série ne porte pas la userData de son épisode next-up :
        // c'est le seul cas qui coûte un aller-retour. L'appel est mis en cache
        // 10 s côté client (préfixe `nextup-`), donc il est le plus souvent servi
        // localement juste après un affichage de fiche.
        guard let episode = try? await api.getNextUp(seriesId: itemId, userId: userId),
              let episodeId = episode.id else {
            return CardPlayTarget(itemId: itemId, title: title, startSeconds: nil)
        }

        return CardPlayTarget(
            itemId: episodeId,
            title: episode.name ?? title,
            startSeconds: resumeSeconds(
                positionTicks: episode.userData?.playbackPositionTicks ?? 0,
                isPlayed: episode.userData?.isPlayed ?? false
            )
        )
    }

    /// Même règle que `MediaDetailScreen.resolvedPlayTarget` : une position
    /// résiduelle sur un média déjà marqué vu ne vaut pas reprise.
    private static func resumeSeconds(positionTicks: Int, isPlayed: Bool) -> Double? {
        guard positionTicks > 0, !isPlayed else { return nil }
        return positionTicks.jellyfinSeconds
    }
}
