#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Image management for the edited item. Singleton image types render a
/// single slot; Backdrop is indexed so we list every known index with its
/// own delete button. Adding uses the server's `downloadRemoteImage` path
/// — we hand it a URL and the server does the fetch, so we don't proxy
/// image bytes through the phone.
///
/// Raw bytes upload (PhotoKit / Files) is intentionally out of scope for
/// P3b — URL upload covers the admin workflow and sidesteps the
/// permissions + encoding complexity. Can be layered in later without
/// disrupting the existing flow.
struct MetadataImagesTab: View {
    @Bindable var viewModel: MetadataEditorViewModel

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    /// Image types we surface. Ordered by "how often an admin edits them"
    /// — Primary first, then key artwork, then rarer types.
    /// Qualified to `JellyfinAPI.ImageType` because `CinemaxKit.ImageType`
    /// (the one `ImageURLBuilder.imageURL` takes) only models 5 cases, not
    /// the 13 the admin editor needs.
    private let singletonTypes: [JellyfinAPI.ImageType] = [.primary, .logo, .thumb, .banner, .disc, .art]

    var body: some View {
        Group {
            ForEach(singletonTypes, id: \.self) { type in
                singletonSection(type)
            }

            backdropSection
        }
        .sheet(isPresented: $viewModel.showAddImageSheet) {
            addImageSheet
        }
        .confirmationDialog(
            loc.localized("admin.metadata.images.delete.title"),
            isPresented: Binding(
                get: { viewModel.pendingImageDelete != nil },
                set: { if !$0 { viewModel.pendingImageDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(loc.localized("admin.metadata.images.delete.confirm"), role: .destructive) {
                Task {
                    let ok = await viewModel.deletePendingImage(
                        using: appState.apiClient,
                        userId: appState.currentUserId ?? ""
                    )
                    if ok {
                        toasts.success(loc.localized("admin.metadata.images.delete.success"))
                    } else if let err = viewModel.errorMessage {
                        toasts.error(err)
                    }
                }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func singletonSection(_ type: JellyfinAPI.ImageType) -> some View {
        AdminSectionGroup(typeLabel(for: type)) {
            iOSSettingsRow {
                HStack(alignment: .center, spacing: CinemaSpacing.spacing3) {
                    imageSlot(type: type, index: nil, hasImage: hasImage(type))
                    Spacer()
                    actionButtons(type: type, index: nil, hasImage: hasImage(type))
                }
            }
        }
    }

    private var backdropSection: some View {
        let indices = Array(0..<(viewModel.item.backdropImageTags?.count ?? 0))
        return AdminSectionGroup(
            typeLabel(for: .backdrop),
            footer: loc.localized("admin.metadata.images.backdrop.footer")
        ) {
            if indices.isEmpty {
                iOSSettingsRow {
                    HStack {
                        Text(loc.localized("admin.metadata.images.backdrop.empty"))
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                        Spacer()
                        addButton(type: .backdrop)
                    }
                }
            } else {
                ForEach(Array(indices.enumerated()), id: \.offset) { rowIdx, backdropIdx in
                    iOSSettingsRow {
                        HStack(spacing: CinemaSpacing.spacing3) {
                            imageSlot(type: .backdrop, index: backdropIdx, hasImage: true)
                            Spacer()
                            actionButtons(type: .backdrop, index: backdropIdx, hasImage: true)
                        }
                    }
                    if rowIdx < indices.count - 1 {
                        iOSSettingsDivider
                    }
                }
                iOSSettingsDivider
                iOSSettingsRow {
                    HStack {
                        Spacer()
                        addButton(type: .backdrop)
                    }
                }
            }
        }
    }

    // MARK: - Slot + actions

    @ViewBuilder
    private func imageSlot(type: JellyfinAPI.ImageType, index: Int?, hasImage: Bool) -> some View {
        let aspect: CGFloat = switch type {
        case .primary, .disc: 2.0 / 3.0
        case .backdrop, .art, .thumb: 16.0 / 9.0
        case .logo: 2.5
        case .banner: 5.0
        default: 1.0
        }

        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .frame(width: 120)
            .overlay {
                if hasImage {
                    CinemaLazyImage(
                        url: appState.imageBuilder.imageURLRaw(
                            itemId: viewModel.item.id ?? "",
                            imageTypeRaw: type.rawValue,
                            maxWidth: 360
                        ),
                        fallbackIcon: "photo"
                    )
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: CinemaRadius.small)
                            .fill(CinemaColor.surfaceContainerHigh)
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                            .foregroundStyle(CinemaColor.onSurfaceVariant.opacity(0.5))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))
    }

    @ViewBuilder
    private func actionButtons(type: JellyfinAPI.ImageType, index: Int?, hasImage: Bool) -> some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            if !hasImage || type == .backdrop {
                // Backdrop can always add more; singletons only add when empty.
                if !hasImage {
                    addButton(type: type)
                }
            } else {
                addButton(type: type, label: loc.localized("admin.metadata.images.replace"))
            }

            if hasImage {
                Button(role: .destructive) {
                    viewModel.pendingImageDelete = (type: type, index: index)
                } label: {
                    Label(loc.localized("admin.metadata.images.delete"), systemImage: "trash")
                        .font(CinemaFont.label(.small))
                }
                .tint(CinemaColor.error)
            }
        }
    }

    @ViewBuilder
    private func addButton(type: JellyfinAPI.ImageType, label: String? = nil) -> some View {
        Button {
            viewModel.pendingImageType = type
            viewModel.showAddImageSheet = true
        } label: {
            Label(
                label ?? loc.localized("admin.metadata.images.add"),
                systemImage: "link.badge.plus"
            )
            .font(CinemaFont.label(.small))
        }
        .tint(themeManager.accent)
    }

    // MARK: - Add sheet

    private var addImageSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    Text(String(
                        format: loc.localized("admin.metadata.images.add.description"),
                        typeLabel(for: viewModel.pendingImageType)
                    ))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)

                    GlassTextField(
                        label: loc.localized("admin.metadata.images.add.urlLabel"),
                        text: $viewModel.newImageURL,
                        placeholder: "https://example.com/poster.jpg"
                    )

                    if let err = viewModel.errorMessage {
                        Text(err)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.error)
                    }

                    CinemaButton(
                        title: loc.localized("admin.metadata.images.add.submit"),
                        style: .accent
                    ) {
                        Task {
                            let ok = await viewModel.addImageFromURL(
                                using: appState.apiClient,
                                userId: appState.currentUserId ?? ""
                            )
                            if ok {
                                toasts.success(loc.localized("admin.metadata.images.add.success"))
                                viewModel.showAddImageSheet = false
                            }
                        }
                    }
                    .disabled(viewModel.newImageURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.top, CinemaSpacing.spacing2)
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(loc.localized("admin.metadata.images.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel")) {
                        viewModel.showAddImageSheet = false
                    }
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

    private func hasImage(_ type: JellyfinAPI.ImageType) -> Bool {
        viewModel.item.imageTags?[type.rawValue] != nil
    }

    private func typeLabel(for type: JellyfinAPI.ImageType) -> String {
        switch type {
        case .primary: loc.localized("admin.metadata.images.primary")
        case .backdrop: loc.localized("admin.metadata.images.backdrop")
        case .logo: loc.localized("admin.metadata.images.logo")
        case .thumb: loc.localized("admin.metadata.images.thumb")
        case .banner: loc.localized("admin.metadata.images.banner")
        case .disc: loc.localized("admin.metadata.images.disc")
        case .art: loc.localized("admin.metadata.images.art")
        default: type.rawValue
        }
    }
}
#endif
