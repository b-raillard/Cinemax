#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Form pane of the Identify wizard. Matches Jellyfin iOS's first step:
/// read-only "Chemin" row, then Nom / Année / provider-id fields, and a
/// "Rechercher" submit button.
///
/// Provider-id rows are kind-aware: movies show IMDb / TMDb Film / TMDb
/// Coffret (collection); series show IMDb / TMDb / TVDb — the set the
/// Jellyfin server actually honors for each `ItemLookupInfo` subtype.
struct IdentifyFormView: View {
    @Bindable var model: IdentifyFlowModel
    let onSearch: () -> Void

    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            Text(loc.localized("admin.identify.prompt"))
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurface)
                .padding(.horizontal, CinemaSpacing.spacing3)

            if let path = model.itemPath, !path.isEmpty {
                AdminSectionGroup(loc.localized("admin.identify.path")) {
                    iOSSettingsRow {
                        Text(path)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            AdminSectionGroup(loc.localized("admin.identify.criteriaHeader")) {
                iOSSettingsRow {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                        GlassTextField(
                            label: loc.localized("admin.identify.name"),
                            text: $model.name,
                            placeholder: model.initialItemName ?? ""
                        )
                        GlassTextField(
                            label: loc.localized("admin.identify.year"),
                            text: $model.year,
                            placeholder: "2024",
                            keyboardType: .numberPad
                        )

                        if model.itemKind == .movie {
                            GlassTextField(
                                label: loc.localized("admin.identify.imdbId"),
                                text: $model.imdbId,
                                placeholder: "tt1234567"
                            )
                            GlassTextField(
                                label: loc.localized("admin.identify.tmdbFilmId"),
                                text: $model.tmdbId,
                                placeholder: "603",
                                keyboardType: .numberPad
                            )
                            GlassTextField(
                                label: loc.localized("admin.identify.tmdbCollectionId"),
                                text: $model.tmdbCollectionId,
                                placeholder: "",
                                keyboardType: .numberPad
                            )
                        } else if model.itemKind == .series {
                            GlassTextField(
                                label: loc.localized("admin.identify.imdbId"),
                                text: $model.imdbId,
                                placeholder: "tt1234567"
                            )
                            GlassTextField(
                                label: loc.localized("admin.identify.tmdbSeriesId"),
                                text: $model.tmdbId,
                                placeholder: "",
                                keyboardType: .numberPad
                            )
                            GlassTextField(
                                label: loc.localized("admin.identify.tvdbId"),
                                text: $model.tvdbId,
                                placeholder: "",
                                keyboardType: .numberPad
                            )
                        }
                    }
                }
            }

            if let err = model.errorMessage {
                Text(err)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.error)
                    .padding(.horizontal, CinemaSpacing.spacing3)
            }

            CinemaButton(
                title: loc.localized("admin.identify.search"),
                style: .accent,
                isLoading: model.isSearching
            ) {
                onSearch()
            }
            .disabled(!model.canSearch || model.isSearching)
            .opacity((model.canSearch && !model.isSearching) ? 1.0 : 0.5)
            .padding(.horizontal, CinemaSpacing.spacing3)
        }
    }
}
#endif
