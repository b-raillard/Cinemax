import SwiftUI

// MARK: - Card → fiche zoom transition (iOS)

/// One card's end of the zoom navigation transition into `MediaDetailScreen`:
/// the HOST screen's namespace plus a source id that is unique on that screen.
///
/// The id is `surface|itemId`, never the bare item id: the same title routinely
/// sits in several rails of one screen (Home's Recently Added, Favorites and
/// genre rows; a film under two library genres), and two sources sharing an id
/// in one namespace make the zoom start from whichever SwiftUI picks — often a
/// card that isn't the one tapped, or one scrolled off screen.
///
/// The namespace must belong to the screen that pushes the fiche. Cards live in
/// lazy containers (see the lazy-container RULE), so they cannot own it; the
/// host declares `@Namespace` and hands it down — explicitly for its own card
/// helpers, through `cardZoomScope(_:surface:)` for reusable cards
/// (`LibraryPosterCard`, `SearchResultCard`, `MediaDetailSimilarSection`).
struct CardZoom: Equatable {
    let namespace: Namespace.ID
    let sourceID: String

    /// `nil` when the item has no id — such a card pushes nothing anyway.
    init?(_ namespace: Namespace.ID, surface: String, itemId: String?) {
        guard let itemId else { return nil }
        self.namespace = namespace
        self.sourceID = "\(surface)|\(itemId)"
    }
}

/// What a host publishes to the reusable cards below it: its namespace and the
/// surface they sit on.
struct CardZoomScope: Equatable {
    let namespace: Namespace.ID
    let surface: String

    func zoom(for itemId: String?) -> CardZoom? {
        CardZoom(namespace, surface: surface, itemId: itemId)
    }
}

extension EnvironmentValues {
    /// Set by `cardZoomScope(_:surface:)`; `nil` everywhere else, which is
    /// what keeps an un-scoped card on the default push.
    @Entry var cardZoomScope: CardZoomScope? = nil
}

extension View {
    /// Publishes the host's namespace to the reusable cards in this subtree.
    /// A no-op on tvOS, which has no zoom transition.
    func cardZoomScope(_ namespace: Namespace.ID, surface: String) -> some View {
        #if os(iOS)
        environment(\.cardZoomScope, CardZoomScope(namespace: namespace, surface: surface))
        #else
        self
        #endif
    }

    /// Marks a card's ARTWORK as the zoom's origin — the artwork alone, never
    /// the title under it, for the same reason the context-menu preview lifts
    /// the artwork alone. Rounded to the card's own corner radius.
    @ViewBuilder
    func cardZoomSource(_ zoom: CardZoom?) -> some View {
        #if os(iOS)
        if let zoom {
            matchedTransitionSource(id: zoom.sourceID, in: zoom.namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Applied to the pushed `MediaDetailScreen`. Falls back to the default
    /// push when `motionEffectsEnabled` is off, or when there is no source.
    func cardZoomDestination(_ zoom: CardZoom?) -> some View {
        modifier(CardZoomDestinationModifier(zoom: zoom))
    }
}

private struct CardZoomDestinationModifier: ViewModifier {
    let zoom: CardZoom?

    #if os(iOS)
    @Environment(\.motionEffectsEnabled) private var motionEnabled
    /// The motion setting as it stood when this fiche was pushed. The two
    /// branches below are different view identities, so re-reading the live
    /// setting would REBUILD a fiche still alive in a tab's stack (fresh view
    /// model, reload, lost scroll) the moment the user flipped Motion Effects
    /// in Settings. The transition only matters at push and pop anyway.
    @State private var motionAtPush: Bool?
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        let zoomOn = motionAtPush ?? motionEnabled
        Group {
            if zoomOn, let zoom {
                content.navigationTransition(.zoom(sourceID: zoom.sourceID, in: zoom.namespace))
            } else {
                content
            }
        }
        .onAppear {
            if motionAtPush == nil { motionAtPush = motionEnabled }
        }
        #else
        content
        #endif
    }
}
