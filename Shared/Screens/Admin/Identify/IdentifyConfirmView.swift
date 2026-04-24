#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Confirm pane of the Identify wizard. Matches Jellyfin iOS's last step:
/// left-aligned poster, title + year on the right, "Remplacer les images
/// existantes" toggle, and a single OK button anchored at the bottom.
///
/// The replace-images toggle defaults to ON (same as Jellyfin iOS and the
/// existing in-app Identify tab) because the typical admin intent is
/// "replace metadata AND replace artwork". Users who hand-picked custom
/// artwork can turn it off before confirming.
struct IdentifyConfirmView: View {
    let result: RemoteSearchResult
    @Binding var replaceAllImages: Bool
    let isApplying: Bool
    let onConfirm: () -> Void

    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            HStack(alignment: .top, spacing: CinemaSpacing.spacing4) {
                poster
                    .frame(width: 140)

                VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                    Text(result.name ?? "—")
                        .font(CinemaFont.headline(.medium))
                        .foregroundStyle(CinemaColor.onSurface)
                        .multilineTextAlignment(.leading)

                    if let year = result.productionYear {
                        Text(String(year))
                            .font(CinemaFont.body)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }

                    if let provider = result.searchProviderName {
                        Text(provider)
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.outline)
                            .padding(.top, 2)
                    }

                    if let overview = result.overview, !overview.isEmpty {
                        Text(overview)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(6)
                            .padding(.top, CinemaSpacing.spacing2)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, CinemaSpacing.spacing3)

            replaceImagesRow
                .padding(.horizontal, CinemaSpacing.spacing3)

            Text(loc.localized("admin.identify.replaceImages.hint"))
                .font(CinemaFont.label(.small))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .padding(.horizontal, CinemaSpacing.spacing3)
        }
    }

    @ViewBuilder
    private var poster: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let raw = result.imageURL, let url = URL(string: raw) {
                    CinemaLazyImage(url: url, fallbackIcon: "photo")
                } else {
                    ZStack {
                        CinemaColor.surfaceContainerHigh
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
            .clipped()
    }

    private var replaceImagesRow: some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            Button {
                replaceAllImages.toggle()
            } label: {
                Image(systemName: replaceAllImages ? "checkmark.square.fill" : "square")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(replaceAllImages ? themeManager.accent : CinemaColor.outline)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.localized("admin.identify.replaceImages"))
            .accessibilityAddTraits(replaceAllImages ? .isSelected : [])

            Text(loc.localized("admin.identify.replaceImages"))
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurface)

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            replaceAllImages.toggle()
        }
    }
}
#endif
