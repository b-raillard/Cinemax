import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - Cast Section

/// Horizontal carousel of cast members below the action buttons. Equatable so
/// season / episode mutations on the parent view model don't re-evaluate this
/// row when the people array hasn't actually changed.
struct MediaDetailCastSection: View, Equatable {
    let people: [BaseItemPerson]

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // SwiftUI's view diffing runs on the main actor; `assumeIsolated`
        // unblocks reading the main-actor-isolated stored properties (the
        // people array's element type isn't `Sendable`, so straight access
        // from a `nonisolated` context warns).
        MainActor.assumeIsolated {
            guard lhs.people.count == rhs.people.count else { return false }
            for (a, b) in zip(lhs.people, rhs.people) {
                if a.id != b.id || a.name != b.name || a.role != b.role { return false }
            }
            return true
        }
    }

    var body: some View {
        ContentRow(
            title: loc.localized("detail.castCrew"),
            data: Array(people.prefix(20)),
            id: \.id
        ) { person in
            CastCircle(
                name: person.name ?? "",
                role: person.role,
                imageURL: person.id.map {
                    appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 200)
                }
            )
        }
    }
}
