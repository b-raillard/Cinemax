#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Four-tab user editor: Profile / Access / Parental / Password. Profile +
/// Access + Parental share a Save footer (all touch the user policy + DTO).
/// Password lives on its own endpoint with its own submit button — mirroring
/// the way Jellyfin web separates the flows.
struct AdminUserDetailScreen: View {
    let user: UserDto
    let parent: AdminUsersViewModel

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: AdminUserDetailViewModel

    init(user: UserDto, parent: AdminUsersViewModel) {
        self.user = user
        self.parent = parent
        _viewModel = State(wrappedValue: AdminUserDetailViewModel(user: user))
    }

    private var isSelf: Bool {
        viewModel.isSelf(currentUserId: appState.currentUserId)
    }

    private var tabs: [AdminTabBar<AdminUserDetailTab>.Item] {
        [
            .init(id: .profile, label: loc.localized("admin.user.tab.profile")),
            .init(id: .access, label: loc.localized("admin.user.tab.access")),
            .init(id: .parental, label: loc.localized("admin.user.tab.parental")),
            .init(id: .password, label: loc.localized("admin.user.tab.password"))
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            AdminTabBar(items: tabs, selection: $viewModel.selectedTab)

            Group {
                switch viewModel.selectedTab {
                case .profile:
                    profileTab
                case .access:
                    accessTab
                case .parental:
                    parentalTab
                case .password:
                    passwordTab
                }
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(viewModel.editedUser.name ?? loc.localized("admin.users.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isSelf {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            viewModel.showDeleteConfirm = true
                        } label: {
                            Label(loc.localized("admin.user.delete"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(themeManager.accent)
                }
            }
        }
        .task { await viewModel.loadMediaFolders(using: appState.apiClient) }
        .sheet(isPresented: $viewModel.showDeleteConfirm) {
            DestructiveConfirmSheet(
                title: loc.localized("admin.user.delete.title"),
                message: String(
                    format: loc.localized("admin.user.delete.message"),
                    viewModel.editedUser.name ?? ""
                ),
                requiredPhrase: viewModel.editedUser.name ?? "",
                confirmLabel: loc.localized("admin.user.delete.confirm"),
                onConfirm: {
                    let ok = await viewModel.deleteUser(using: appState.apiClient)
                    if ok {
                        if let id = viewModel.userId {
                            parent.removeLocally(userId: id)
                        }
                        toasts.success(loc.localized("admin.user.delete.success"))
                        dismiss()
                    } else if let err = viewModel.errorMessage {
                        toasts.error(err)
                    }
                }
            )
        }
    }

    // MARK: - Shared: Save footer (Profile / Access / Parental share this)

    private func formWithSave<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        AdminFormScreen(
            isDirty: viewModel.isDirty,
            isSaving: viewModel.isSaving,
            onSave: {
                let ok = await viewModel.save(using: appState.apiClient)
                if ok {
                    toasts.success(loc.localized("admin.user.save.success"))
                } else if let err = viewModel.errorMessage {
                    toasts.error(err)
                }
            },
            onDiscard: nil,
            content: content
        )
    }

    // MARK: - Profile tab

    private var profileTab: some View {
        formWithSave {
            AdminSectionGroup(loc.localized("admin.user.profile.identity")) {
                iOSSettingsRow {
                    HStack(spacing: CinemaSpacing.spacing3) {
                        UserAvatar(
                            userId: viewModel.editedUser.id,
                            name: viewModel.editedUser.name,
                            primaryImageTag: viewModel.editedUser.primaryImageTag,
                            size: 72
                        )
                        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                            GlassTextField(
                                label: loc.localized("admin.user.profile.name"),
                                text: Binding(
                                    get: { viewModel.editedUser.name ?? "" },
                                    set: { viewModel.editedUser.name = $0 }
                                ),
                                placeholder: ""
                            )
                        }
                    }
                }
            }

            AdminSectionGroup(loc.localized("admin.user.profile.permissions")) {
                toggleRow(
                    icon: "shield.lefthalf.filled",
                    label: loc.localized("admin.user.profile.isAdministrator"),
                    isOn: policyBinding(\.isAdministrator),
                    disabled: isSelf,
                    disabledHint: isSelf ? loc.localized("admin.user.profile.cantDemoteSelf") : nil
                )
                iOSSettingsDivider
                toggleRow(
                    icon: "eye.slash",
                    label: loc.localized("admin.user.profile.isHidden"),
                    isOn: policyBinding(\.isHidden)
                )
                iOSSettingsDivider
                toggleRow(
                    icon: "nosign",
                    label: loc.localized("admin.user.profile.isDisabled"),
                    isOn: policyBinding(\.isDisabled),
                    disabled: isSelf,
                    disabledHint: isSelf ? loc.localized("admin.user.profile.cantDisableSelf") : nil
                )
            }
        }
    }

    // MARK: - Access tab

    private var accessTab: some View {
        formWithSave {
            AdminSectionGroup(
                loc.localized("admin.user.access.libraryAccess"),
                footer: loc.localized("admin.user.access.libraryAccess.footer")
            ) {
                toggleRow(
                    icon: "folder",
                    label: loc.localized("admin.user.access.enableAllLibraries"),
                    isOn: policyBinding(\.enableAllFolders)
                )
            }

            let enableAll = viewModel.editedUser.policy?.enableAllFolders ?? false
            if !enableAll {
                AdminSectionGroup(loc.localized("admin.user.access.libraries")) {
                    if !viewModel.mediaFoldersLoaded {
                        LoadingStateView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, CinemaSpacing.spacing4)
                    } else if viewModel.allMediaFolders.isEmpty {
                        Text(loc.localized("admin.user.access.libraries.empty"))
                            .font(CinemaFont.body)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(CinemaSpacing.spacing4)
                    } else {
                        ForEach(Array(viewModel.allMediaFolders.enumerated()), id: \.element.id) { index, folder in
                            folderRow(folder)
                            if index < viewModel.allMediaFolders.count - 1 {
                                iOSSettingsDivider
                            }
                        }
                    }
                }
            }

            AdminSectionGroup(loc.localized("admin.user.access.devices")) {
                toggleRow(
                    icon: "laptopcomputer.and.iphone",
                    label: loc.localized("admin.user.access.enableAllDevices"),
                    isOn: policyBinding(\.enableAllDevices)
                )
            }
        }
    }

    @ViewBuilder
    private func folderRow(_ folder: BaseItemDto) -> some View {
        let folderId = folder.id ?? ""
        let isOn = viewModel.isFolderEnabled(folderId)
        iOSSettingsRow {
            Button {
                viewModel.toggleFolder(folderId)
            } label: {
                HStack {
                    iOSRowIcon(
                        systemName: isOn ? "checkmark.square.fill" : "square",
                        color: isOn ? themeManager.accent : CinemaColor.onSurfaceVariant
                    )
                    Text(folder.name ?? "—")
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Parental tab

    private var parentalTab: some View {
        formWithSave {
            AdminSectionGroup(
                loc.localized("admin.user.parental.rating.title"),
                footer: loc.localized("admin.user.parental.rating.footer")
            ) {
                iOSSettingsRow {
                    HStack {
                        iOSRowIcon(systemName: "person.badge.shield.checkmark", color: themeManager.accent)
                        Text(loc.localized("admin.user.parental.rating.label"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                        Spacer()
                        Menu {
                            ForEach(parentalRatingOptions, id: \.age) { option in
                                Button {
                                    setPolicy { $0.maxParentalRating = option.age == 0 ? nil : option.age }
                                } label: {
                                    if (viewModel.editedUser.policy?.maxParentalRating ?? 0) == option.age {
                                        Label(option.label, systemImage: "checkmark")
                                    } else {
                                        Text(option.label)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(currentParentalRatingLabel)
                                    .font(CinemaFont.label(.large))
                                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: CinemaScale.pt(11), weight: .semibold))
                                    .foregroundStyle(CinemaColor.outlineVariant)
                            }
                        }
                        .tint(themeManager.accent)
                    }
                }
            }
        }
    }

    private struct ParentalRatingOption {
        let age: Int
        let label: String
    }

    private var parentalRatingOptions: [ParentalRatingOption] {
        [
            .init(age: 0, label: loc.localized("privacy.age.all")),
            .init(age: 10, label: loc.localized("privacy.age.over10")),
            .init(age: 12, label: loc.localized("privacy.age.over12")),
            .init(age: 14, label: loc.localized("privacy.age.over14")),
            .init(age: 16, label: loc.localized("privacy.age.over16")),
            .init(age: 18, label: loc.localized("privacy.age.over18"))
        ]
    }

    private var currentParentalRatingLabel: String {
        let rating = viewModel.editedUser.policy?.maxParentalRating ?? 0
        return parentalRatingOptions.first { $0.age == rating }?.label
            ?? parentalRatingOptions.first!.label
    }

    // MARK: - Password tab

    private var passwordTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                AdminSectionGroup(
                    loc.localized("admin.user.password.changeTitle"),
                    footer: loc.localized("admin.user.password.changeFooter")
                ) {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                        GlassTextField(
                            label: loc.localized("admin.user.password.new"),
                            text: $viewModel.newPassword,
                            placeholder: "",
                            isSecure: true
                        )
                        GlassTextField(
                            label: loc.localized("admin.user.password.confirm"),
                            text: $viewModel.confirmPassword,
                            placeholder: "",
                            isSecure: true
                        )

                        if !viewModel.newPassword.isEmpty && !viewModel.passwordsMatch {
                            Text(loc.localized("admin.user.password.mismatch"))
                                .font(CinemaFont.label(.medium))
                                .foregroundStyle(CinemaColor.error)
                        }

                        CinemaButton(
                            title: loc.localized("admin.user.password.submit"),
                            style: .primary,
                            isLoading: viewModel.isChangingPassword
                        ) {
                            Task {
                                let ok = await viewModel.changePassword(using: appState.apiClient)
                                if ok {
                                    toasts.success(loc.localized("admin.user.password.success"))
                                } else if let err = viewModel.errorMessage {
                                    toasts.error(err)
                                }
                            }
                        }
                        .disabled(!viewModel.canChangePassword)
                        .opacity(viewModel.canChangePassword ? 1.0 : 0.5)
                    }
                    .padding(CinemaSpacing.spacing4)
                }

                AdminSectionGroup(
                    loc.localized("admin.user.password.resetTitle"),
                    footer: loc.localized("admin.user.password.resetFooter")
                ) {
                    iOSSettingsRow {
                        Button(role: .destructive) {
                            viewModel.showResetPasswordConfirm = true
                        } label: {
                            HStack {
                                iOSRowIcon(systemName: "key.slash", color: CinemaColor.error)
                                Text(loc.localized("admin.user.password.resetAction"))
                                    .font(CinemaFont.label(.large))
                                    .foregroundStyle(CinemaColor.error)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.top, CinemaSpacing.spacing4)
            .padding(.bottom, CinemaSpacing.spacing8)
        }
        .confirmationDialog(
            loc.localized("admin.user.password.resetConfirm.title"),
            isPresented: $viewModel.showResetPasswordConfirm,
            titleVisibility: .visible
        ) {
            Button(loc.localized("admin.user.password.resetAction"), role: .destructive) {
                Task {
                    let ok = await viewModel.resetPassword(using: appState.apiClient)
                    if ok {
                        toasts.success(loc.localized("admin.user.password.resetSuccess"))
                    } else if let err = viewModel.errorMessage {
                        toasts.error(err)
                    }
                }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("admin.user.password.resetConfirm.message"))
        }
    }

    // MARK: - Helpers

    /// Binding into a boolean field on the editedUser's policy. Policy is a
    /// nested struct so we can't just `$viewModel.editedUser.policy?.foo` —
    /// the path is optional-chained. This helper materialises a Binding
    /// that reads the current value (defaulted false) and writes through
    /// `setPolicy` so the policy is always lazily initialised.
    private func policyBinding(_ keyPath: WritableKeyPath<UserPolicy, Bool?>) -> Binding<Bool> {
        Binding(
            get: { viewModel.editedUser.policy?[keyPath: keyPath] ?? false },
            set: { newValue in
                setPolicy { policy in
                    policy[keyPath: keyPath] = newValue
                }
            }
        )
    }

    /// Applies a mutation to the current policy, lazily initialising if nil.
    /// A fresh UserPolicy requires two non-optional String fields — we leave
    /// them blank; the server keeps its server-configured defaults when the
    /// payload comes back unchanged.
    private func setPolicy(_ mutate: (inout UserPolicy) -> Void) {
        var policy = viewModel.editedUser.policy ?? UserPolicy(
            authenticationProviderID: "",
            passwordResetProviderID: ""
        )
        mutate(&policy)
        viewModel.editedUser.policy = policy
    }

    @ViewBuilder
    private func toggleRow(
        icon: String,
        label: String,
        isOn: Binding<Bool>,
        disabled: Bool = false,
        disabledHint: String? = nil
    ) -> some View {
        iOSSettingsRow {
            HStack {
                iOSRowIcon(systemName: icon, color: themeManager.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(disabled ? CinemaColor.onSurfaceVariant : CinemaColor.onSurface)
                    if disabled, let hint = disabledHint {
                        Text(hint)
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                }
                Spacer()
                Button { isOn.wrappedValue.toggle() } label: {
                    CinemaToggleIndicator(isOn: isOn.wrappedValue, accent: themeManager.accent, animated: true)
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1.0)
            }
        }
    }
}
#endif
