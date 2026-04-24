#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Multi-tab item editor. Shared entry point for both the settings-level
/// metadata browser and the `MediaDetailScreen` "Edit metadata" button on
/// admin-gated detail screens.
///
/// General / Images / Cast share the one save footer — all three touch
/// the item DTO. Identify and Actions have their own dedicated submit
/// buttons since those operations are server-driven and don't go through
/// `updateItem`.
///
/// On any server-side mutation (save / apply identify / refresh / delete)
/// we post `.cinemaxShouldRefreshCatalogue` so Home and Library re-fetch
/// with the new titles / artwork.
struct MetadataEditorScreen: View {
    let item: BaseItemDto

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: MetadataEditorViewModel

    init(item: BaseItemDto) {
        self.item = item
        _viewModel = State(wrappedValue: MetadataEditorViewModel(item: item))
    }

    private var tabs: [AdminTabBar<MetadataEditorTab>.Item] {
        [
            .init(id: .general, label: loc.localized("admin.metadata.tab.general")),
            .init(id: .images, label: loc.localized("admin.metadata.tab.images")),
            .init(id: .cast, label: loc.localized("admin.metadata.tab.cast")),
            .init(id: .identify, label: loc.localized("admin.metadata.tab.identify")),
            .init(id: .actions, label: loc.localized("admin.metadata.tab.actions"))
        ]
    }

    /// Tabs that share the central "save DTO" footer. Identify / Actions
    /// have their own server-driven submit controls.
    private var tabUsesSharedSave: Bool {
        switch viewModel.selectedTab {
        case .general, .images, .cast: true
        case .identify, .actions: false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AdminTabBar(items: tabs, selection: $viewModel.selectedTab)

            Group {
                if tabUsesSharedSave {
                    AdminFormScreen(
                        isDirty: viewModel.isDirty,
                        isSaving: viewModel.isSaving,
                        onSave: {
                            let ok = await viewModel.save(using: appState.apiClient)
                            if ok {
                                toasts.success(loc.localized("admin.metadata.save.success"))
                            } else if let err = viewModel.errorMessage {
                                toasts.error(err)
                            }
                        }
                    ) {
                        switch viewModel.selectedTab {
                        case .general:
                            MetadataGeneralTab(viewModel: viewModel)
                        case .images:
                            MetadataImagesTab(viewModel: viewModel)
                        case .cast:
                            MetadataCastTab(viewModel: viewModel)
                        default:
                            EmptyView()
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                            switch viewModel.selectedTab {
                            case .identify:
                                MetadataIdentifyTab(viewModel: viewModel)
                            case .actions:
                                MetadataActionsTab(viewModel: viewModel, onDeleted: {
                                    toasts.success(loc.localized("admin.metadata.delete.success"))
                                    dismiss()
                                })
                            default:
                                EmptyView()
                            }
                        }
                        .padding(.horizontal, CinemaSpacing.spacing3)
                        .padding(.top, CinemaSpacing.spacing4)
                        .padding(.bottom, CinemaSpacing.spacing8)
                    }
                }
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(viewModel.item.name ?? loc.localized("admin.metadata.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - General Tab

struct MetadataGeneralTab: View {
    @Bindable var viewModel: MetadataEditorViewModel

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Group {
            AdminSectionGroup(loc.localized("admin.metadata.general.titles")) {
                textFieldRow(loc.localized("admin.metadata.general.name"), binding: stringBinding(\.name))
                iOSSettingsDivider
                textFieldRow(loc.localized("admin.metadata.general.originalTitle"), binding: stringBinding(\.originalTitle))
                iOSSettingsDivider
                textFieldRow(loc.localized("admin.metadata.general.sortName"), binding: stringBinding(\.sortName))
                iOSSettingsDivider
                textFieldRow(loc.localized("admin.metadata.general.forcedSortName"), binding: stringBinding(\.forcedSortName))
            }

            AdminSectionGroup(loc.localized("admin.metadata.general.overview")) {
                iOSSettingsRow {
                    TextEditor(text: stringBinding(\.overview))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurface)
                        .frame(minHeight: 120, maxHeight: 300)
                        .scrollContentBackground(.hidden)
                        .background(CinemaColor.surfaceContainerHighest.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))
                }
            }

            AdminSectionGroup(loc.localized("admin.metadata.general.taglines")) {
                iOSSettingsRow {
                    ChipEditor(
                        items: arrayBinding(\.taglines),
                        placeholder: loc.localized("admin.metadata.general.addTagline")
                    )
                }
            }

            AdminSectionGroup(loc.localized("admin.metadata.general.releaseInfo")) {
                yearRow
                iOSSettingsDivider
                dateRow(loc.localized("admin.metadata.general.premiereDate"), binding: dateBinding(\.premiereDate))
                iOSSettingsDivider
                dateRow(loc.localized("admin.metadata.general.endDate"), binding: dateBinding(\.endDate))
            }

            AdminSectionGroup(loc.localized("admin.metadata.general.ratings")) {
                textFieldRow(
                    loc.localized("admin.metadata.general.officialRating"),
                    binding: stringBinding(\.officialRating),
                    placeholder: "PG-13"
                )
                iOSSettingsDivider
                textFieldRow(
                    loc.localized("admin.metadata.general.customRating"),
                    binding: stringBinding(\.customRating)
                )
                iOSSettingsDivider
                communityRatingRow
            }

            AdminSectionGroup(
                loc.localized("admin.metadata.general.genresTags"),
                footer: loc.localized("admin.metadata.general.chipHint")
            ) {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                    Text(loc.localized("admin.metadata.general.genres"))
                        .font(CinemaFont.label(.small).weight(.bold))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                    ChipEditor(
                        items: arrayBinding(\.genres),
                        placeholder: loc.localized("admin.metadata.general.addGenre")
                    )

                    Text(loc.localized("admin.metadata.general.tags"))
                        .font(CinemaFont.label(.small).weight(.bold))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .padding(.top, CinemaSpacing.spacing2)
                    ChipEditor(
                        items: arrayBinding(\.tags),
                        placeholder: loc.localized("admin.metadata.general.addTag")
                    )

                    Text(loc.localized("admin.metadata.general.studios"))
                        .font(CinemaFont.label(.small).weight(.bold))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .padding(.top, CinemaSpacing.spacing2)
                    ChipEditor(
                        items: studioNamesBinding,
                        placeholder: loc.localized("admin.metadata.general.addStudio")
                    )
                }
                .padding(CinemaSpacing.spacing4)
            }

            AdminSectionGroup(
                loc.localized("admin.metadata.general.providerIds"),
                footer: loc.localized("admin.metadata.general.providerIds.footer")
            ) {
                iOSSettingsRow {
                    KeyValueEditor(
                        dict: providerIdsBinding,
                        keyPlaceholder: "Imdb",
                        valuePlaceholder: "tt1234567"
                    )
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func textFieldRow(_ label: String, binding: Binding<String>, placeholder: String = "") -> some View {
        iOSSettingsRow {
            HStack {
                Text(label)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .frame(width: 110, alignment: .leading)
                TextField(placeholder, text: binding)
                    .textInputAutocapitalization(.sentences)
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurface)
            }
        }
    }

    private var yearRow: some View {
        iOSSettingsRow {
            HStack {
                Text(loc.localized("admin.metadata.general.year"))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .frame(width: 110, alignment: .leading)
                TextField("2024", text: yearBinding)
                    .keyboardType(.numberPad)
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurface)
            }
        }
    }

    @ViewBuilder
    private func dateRow(_ label: String, binding: Binding<Date?>) -> some View {
        iOSSettingsRow {
            HStack {
                Text(label)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .frame(width: 110, alignment: .leading)
                if let date = binding.wrappedValue {
                    DatePicker("", selection: Binding(get: { date }, set: { binding.wrappedValue = $0 }), displayedComponents: .date)
                        .labelsHidden()
                    Button {
                        binding.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(loc.localized("admin.metadata.general.setDate")) {
                        binding.wrappedValue = Date()
                    }
                    .foregroundStyle(themeManager.accent)
                    .font(CinemaFont.label(.medium))
                }
                Spacer()
            }
        }
    }

    private var communityRatingRow: some View {
        iOSSettingsRow {
            HStack {
                Text(loc.localized("admin.metadata.general.communityRating"))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .frame(width: 110, alignment: .leading)
                TextField("7.5", text: communityRatingBinding)
                    .keyboardType(.decimalPad)
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurface)
                Text("/ 10")
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
        }
    }

    // MARK: - Bindings

    private func stringBinding(_ keyPath: WritableKeyPath<BaseItemDto, String?>) -> Binding<String> {
        Binding(
            get: { viewModel.item[keyPath: keyPath] ?? "" },
            set: { viewModel.item[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func arrayBinding(_ keyPath: WritableKeyPath<BaseItemDto, [String]?>) -> Binding<[String]> {
        Binding(
            get: { viewModel.item[keyPath: keyPath] ?? [] },
            set: { viewModel.item[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func dateBinding(_ keyPath: WritableKeyPath<BaseItemDto, Date?>) -> Binding<Date?> {
        Binding(
            get: { viewModel.item[keyPath: keyPath] },
            set: { viewModel.item[keyPath: keyPath] = $0 }
        )
    }

    /// Int? ↔ String binding for the year field. Parses digits only;
    /// writes nil when cleared.
    private var yearBinding: Binding<String> {
        Binding(
            get: { viewModel.item.productionYear.map(String.init) ?? "" },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                viewModel.item.productionYear = digits.isEmpty ? nil : Int(digits)
            }
        )
    }

    /// Float? ↔ String binding for the community rating (0–10, one decimal).
    /// Accepts any decimal-parseable string; clamps to 0…10 on commit.
    private var communityRatingBinding: Binding<String> {
        Binding(
            get: {
                viewModel.item.communityRating.map { String(format: "%.1f", $0) } ?? ""
            },
            set: { newValue in
                let cleaned = newValue.replacingOccurrences(of: ",", with: ".")
                if cleaned.isEmpty {
                    viewModel.item.communityRating = nil
                } else if let value = Float(cleaned) {
                    viewModel.item.communityRating = max(0, min(10, value))
                }
            }
        )
    }

    /// Studios are `[NameGuidPair]?` but users only edit names. Round-trip
    /// preserves existing GUIDs for rows that match by name; new chips
    /// get a nil GUID which the server then fills in on save.
    private var studioNamesBinding: Binding<[String]> {
        Binding(
            get: { (viewModel.item.studios ?? []).compactMap(\.name) },
            set: { newNames in
                let existing = viewModel.item.studios ?? []
                viewModel.item.studios = newNames.map { name in
                    if let match = existing.first(where: { $0.name == name }) {
                        return match
                    }
                    return NameGuidPair(id: nil, name: name)
                }
            }
        )
    }

    /// Dict binding with empty-to-nil collapse so saving an empty map
    /// doesn't write `{}` back to the server.
    private var providerIdsBinding: Binding<[String: String]> {
        Binding(
            get: { viewModel.item.providerIDs ?? [:] },
            set: { viewModel.item.providerIDs = $0.isEmpty ? nil : $0 }
        )
    }
}
#endif
