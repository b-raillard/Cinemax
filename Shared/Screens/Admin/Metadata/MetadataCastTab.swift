#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Cast + crew editor. Renders the current `item.people` array with each
/// person's primary image (when one exists), name, role, and kind (Actor /
/// Director / etc.). Add / edit / delete are in-place — changes go back
/// into `item.people` and ship out via the shared `updateItem` save.
struct MetadataCastTab: View {
    @Bindable var viewModel: MetadataEditorViewModel

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        AdminSectionGroup(
            loc.localized("admin.metadata.cast.title"),
            footer: loc.localized("admin.metadata.cast.footer")
        ) {
            if let people = viewModel.item.people, !people.isEmpty {
                ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                    Button {
                        viewModel.editingPerson = person
                    } label: {
                        personRow(person)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            viewModel.deletePerson(at: index)
                        } label: {
                            Label(loc.localized("admin.metadata.cast.remove"), systemImage: "trash")
                        }
                    }
                    if index < people.count - 1 {
                        iOSSettingsDivider
                    }
                }
            } else {
                iOSSettingsRow {
                    Text(loc.localized("admin.metadata.cast.empty"))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }

            iOSSettingsDivider

            iOSSettingsRow {
                Button {
                    viewModel.editingPerson = BaseItemPerson(
                        id: nil,
                        name: "",
                        role: "",
                        type: .actor
                    )
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: CinemaScale.pt(16)))
                            .foregroundStyle(themeManager.accent)
                        Text(loc.localized("admin.metadata.cast.addPerson"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(themeManager.accent)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: editingPersonBinding) { wrapper in
            MetadataPersonEditor(
                person: wrapper.person,
                onSave: { updated in
                    viewModel.upsertPerson(updated)
                    viewModel.editingPerson = nil
                },
                onCancel: { viewModel.editingPerson = nil }
            )
        }
    }

    @ViewBuilder
    private func personRow(_ person: BaseItemPerson) -> some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            personAvatar(person)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name ?? "—")
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                HStack(spacing: CinemaSpacing.spacing2) {
                    Text(personKindLabel(person.type ?? .actor))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                    if let role = person.role, !role.isEmpty {
                        Text("•")
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                        Text(role)
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: CinemaScale.pt(13), weight: .semibold))
                .foregroundStyle(CinemaColor.outlineVariant)
        }
        .padding(.vertical, CinemaSpacing.spacing2)
        .padding(.horizontal, CinemaSpacing.spacing4)
    }

    @ViewBuilder
    private func personAvatar(_ person: BaseItemPerson) -> some View {
        let size: CGFloat = 44
        if let id = person.id, person.primaryImageTag != nil {
            CinemaLazyImage(
                url: appState.imageBuilder.imageURL(
                    itemId: id,
                    imageType: .primary,
                    maxWidth: 160
                ),
                fallbackIcon: "person.fill"
            )
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(CinemaColor.surfaceContainerHigh)
                    .frame(width: size, height: size)
                Text(String((person.name ?? "?").prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
        }
    }

    private func personKindLabel(_ kind: PersonKind) -> String {
        switch kind {
        case .actor: return loc.localized("admin.metadata.cast.kind.actor")
        case .director: return loc.localized("admin.metadata.cast.kind.director")
        case .writer: return loc.localized("admin.metadata.cast.kind.writer")
        case .producer: return loc.localized("admin.metadata.cast.kind.producer")
        case .composer: return loc.localized("admin.metadata.cast.kind.composer")
        case .guestStar: return loc.localized("admin.metadata.cast.kind.guestStar")
        default: return kind.rawValue
        }
    }

    private var editingPersonBinding: Binding<IdentifiablePerson?> {
        Binding(
            get: { viewModel.editingPerson.map { IdentifiablePerson(person: $0) } },
            set: { viewModel.editingPerson = $0?.person }
        )
    }
}

// `.sheet(item:)` needs Identifiable; `BaseItemPerson.id` is optional.
private struct IdentifiablePerson: Identifiable {
    let person: BaseItemPerson
    var id: String { person.id ?? "new-\(person.name ?? UUID().uuidString)" }
}

/// Add / edit sheet for a single person. Name + Role + Kind picker. We
/// scope the kinds to the common crew categories — the full `PersonKind`
/// enum has 15 cases, most of which are music-specific and don't apply
/// to movies/series.
private struct MetadataPersonEditor: View {
    let person: BaseItemPerson
    let onSave: (BaseItemPerson) -> Void
    let onCancel: () -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    @State private var name: String
    @State private var role: String
    @State private var kind: PersonKind

    private let editableKinds: [PersonKind] = [.actor, .director, .writer, .producer, .composer, .guestStar]

    init(person: BaseItemPerson, onSave: @escaping (BaseItemPerson) -> Void, onCancel: @escaping () -> Void) {
        self.person = person
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: person.name ?? "")
        _role = State(initialValue: person.role ?? "")
        _kind = State(initialValue: person.type ?? .actor)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    GlassTextField(
                        label: loc.localized("admin.metadata.cast.name"),
                        text: $name,
                        placeholder: loc.localized("admin.metadata.cast.namePlaceholder")
                    )

                    GlassTextField(
                        label: loc.localized("admin.metadata.cast.role"),
                        text: $role,
                        placeholder: loc.localized("admin.metadata.cast.rolePlaceholder")
                    )

                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                        Text(loc.localized("admin.metadata.cast.kind").uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                        Picker("", selection: $kind) {
                            ForEach(editableKinds, id: \.self) { k in
                                Text(kindLabel(k)).tag(k)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(themeManager.accent)
                    }

                    CinemaButton(
                        title: loc.localized("admin.metadata.cast.save"),
                        style: .primary
                    ) {
                        var updated = person
                        updated.name = name.trimmingCharacters(in: .whitespaces)
                        updated.role = role.trimmingCharacters(in: .whitespaces).isEmpty
                            ? nil
                            : role.trimmingCharacters(in: .whitespaces)
                        updated.type = kind
                        onSave(updated)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.top, CinemaSpacing.spacing3)
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(person.id == nil
                ? loc.localized("admin.metadata.cast.addPerson")
                : loc.localized("admin.metadata.cast.editPerson"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel"), action: onCancel)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func kindLabel(_ kind: PersonKind) -> String {
        switch kind {
        case .actor: loc.localized("admin.metadata.cast.kind.actor")
        case .director: loc.localized("admin.metadata.cast.kind.director")
        case .writer: loc.localized("admin.metadata.cast.kind.writer")
        case .producer: loc.localized("admin.metadata.cast.kind.producer")
        case .composer: loc.localized("admin.metadata.cast.kind.composer")
        case .guestStar: loc.localized("admin.metadata.cast.kind.guestStar")
        default: kind.rawValue
        }
    }
}
#endif
