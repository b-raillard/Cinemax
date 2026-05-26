import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// User-facing editor for the main tab bar.
///
/// Renders differently on iOS (native `List` + `.onMove` + EditButton) and
/// tvOS (focus-driven list with Move Up / Move Down buttons). Both platforms
/// share the same `MenuConfigStore` model and persist through it.
struct MenuSettingsScreen: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(LocalizationManager.self) var loc
    @Environment(ToastCenter.self) var toasts
    @Environment(MenuConfigStore.self) var store

    #if os(tvOS)
    /// Focus lane for tvOS rows. iOS doesn't render any of the tvOS-specific
    /// pill/move buttons that read this state, so the field stays unused there.
    @FocusState var focusedItem: SettingsFocus?
    #endif

    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        tvBody
        #endif
    }

    // MARK: - Display helpers (shared)

    /// Resolves the human-readable label for an entry. Built-in entries use
    /// their tab localization key; library entries fall back to the cached
    /// view's `name`, or the raw id if the view has vanished server-side.
    @MainActor
    func entryLabel(_ entry: MenuEntry) -> String {
        switch entry.id {
        case MenuEntry.homeID:     return loc.localized("tab.home")
        case MenuEntry.searchID:   return loc.localized("tab.search")
        case MenuEntry.settingsID: return loc.localized("tab.settings")
        case MenuEntry.moviesID:   return loc.localized("tab.movies")
        case MenuEntry.seriesID:   return loc.localized("tab.tvShows")
        default:
            if let vid = entry.libraryViewID,
               let view = store.availableViews.first(where: { $0.id == vid }) {
                return view.name
            }
            return entry.id
        }
    }

    @MainActor
    func entryIcon(_ entry: MenuEntry) -> String {
        switch entry.id {
        case MenuEntry.homeID:     return "house.fill"
        case MenuEntry.searchID:   return "magnifyingglass"
        case MenuEntry.settingsID: return "gearshape"
        case MenuEntry.moviesID:   return "film"
        case MenuEntry.seriesID:   return "tv.fill"
        default:
            if let vid = entry.libraryViewID,
               let view = store.availableViews.first(where: { $0.id == vid }) {
                switch view.collectionType {
                case "movies":     return "film"
                case "tvshows":    return "tv.fill"
                case "homevideos": return "video"
                default:           return "rectangle.stack"
                }
            }
            return "rectangle.stack"
        }
    }

    /// Active list driven by `customKind`.
    var activeEntries: [MenuEntry] {
        store.customKind == .contentType ? store.contentTypeEntries : store.libraryEntries
    }

    var enabledCount: Int {
        activeEntries.filter { $0.enabled }.count
    }
}
