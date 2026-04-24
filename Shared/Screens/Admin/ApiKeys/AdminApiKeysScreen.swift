#if os(iOS)
import SwiftUI
import CinemaxKit
import UniformTypeIdentifiers
@preconcurrency import JellyfinAPI

/// API Keys admin. Security-sensitive — tokens grant full admin access to
/// the server, so the UI treats them like passwords:
///
/// - Masked by default (first 4 + last 4 chars, dots in between)
/// - Tap row to toggle reveal; revealed text is `.privacySensitive()` so the
///   system redacts it in Screen Mirroring / Control Center capture
/// - All reveal state is transient — cleared on screen dismiss
/// - Copy button per row (the ONLY path to pasting the token; no share
///   sheet to minimise surface area)
/// - Revoke requires confirmation and is hidden for the current session's key
/// - Create flow refetches the list, identifies the new key by id delta, and
///   opens a dedicated "copy this now" modal so the user never has to hunt
///   for the new entry
///
/// We never log token values or include them in analytics/error reports.
struct AdminApiKeysScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    @State private var viewModel = AdminApiKeysViewModel()

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && viewModel.keys.isEmpty,
            errorMessage: viewModel.errorMessage,
            isEmpty: viewModel.isEmpty,
            emptyIcon: "key.slash",
            emptyTitle: loc.localized("admin.apiKeys.empty.title"),
            emptySubtitle: loc.localized("admin.apiKeys.empty.subtitle"),
            emptyActionTitle: loc.localized("admin.apiKeys.create"),
            onRetry: { Task { await viewModel.load(using: appState.apiClient) } },
            onEmptyAction: { viewModel.showCreateSheet = true }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                    warningBanner

                    AdminSectionGroup(loc.localized("admin.apiKeys.list")) {
                        ForEach(Array(viewModel.keys.enumerated()), id: \.element.id) { index, key in
                            keyRow(key)
                            if index < viewModel.keys.count - 1 {
                                iOSSettingsDivider
                            }
                        }
                    }
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.top, CinemaSpacing.spacing4)
                .padding(.bottom, CinemaSpacing.spacing8)
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.apiKeys.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .tint(themeManager.accent)
            }
        }
        .refreshable { await viewModel.load(using: appState.apiClient) }
        .task {
            if viewModel.keys.isEmpty {
                await viewModel.load(using: appState.apiClient)
            }
        }
        .onDisappear { viewModel.hideAll() }
        .sheet(isPresented: $viewModel.showCreateSheet) { createSheet }
        .sheet(item: freshlyCreatedBinding) { wrapper in
            revealOnCreateSheet(for: wrapper.key)
        }
        .confirmationDialog(
            loc.localized("admin.apiKeys.revoke.title"),
            isPresented: Binding(
                get: { viewModel.pendingRevoke != nil },
                set: { if !$0 { viewModel.pendingRevoke = nil } }
            ),
            titleVisibility: .visible,
            presenting: viewModel.pendingRevoke
        ) { key in
            Button(loc.localized("admin.apiKeys.revoke.confirm"), role: .destructive) {
                Task {
                    let ok = await viewModel.revoke(key, using: appState.apiClient)
                    if ok {
                        toasts.success(loc.localized("admin.apiKeys.revoke.success"))
                    } else if let err = viewModel.errorMessage {
                        toasts.error(err)
                    }
                    viewModel.pendingRevoke = nil
                }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {
                viewModel.pendingRevoke = nil
            }
        } message: { key in
            Text(String(
                format: loc.localized("admin.apiKeys.revoke.message"),
                key.appName ?? ""
            ))
        }
    }

    // MARK: - Warning banner

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: CinemaScale.pt(20)))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(loc.localized("admin.apiKeys.warning.title"))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Text(loc.localized("admin.apiKeys.warning.message"))
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            Spacer()
        }
        .padding(CinemaSpacing.spacing4)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
    }

    // MARK: - Row

    @ViewBuilder
    private func keyRow(_ key: AuthenticationInfo) -> some View {
        let isCurrentSession = key.accessToken == appState.accessToken && key.accessToken != nil
        let isRevealed = viewModel.isRevealed(key)

        iOSSettingsRow {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                HStack(spacing: CinemaSpacing.spacing2) {
                    iOSRowIcon(
                        systemName: "key.fill",
                        color: isCurrentSession ? themeManager.accent : CinemaColor.onSurfaceVariant
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: CinemaSpacing.spacing2) {
                            Text(key.appName ?? "—")
                                .font(CinemaFont.label(.large))
                                .foregroundStyle(CinemaColor.onSurface)
                            if isCurrentSession {
                                Text(loc.localized("admin.apiKeys.thisSession"))
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(0.5)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(themeManager.accent))
                            }
                        }
                        if let date = key.dateCreated {
                            Text(String(
                                format: loc.localized("admin.apiKeys.createdOn"),
                                date.formatted(date: .abbreviated, time: .shortened)
                            ))
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                    }
                    Spacer()
                }

                tokenDisplay(for: key, isRevealed: isRevealed, isCurrentSession: isCurrentSession)
            }
        }
    }

    @ViewBuilder
    private func tokenDisplay(for key: AuthenticationInfo, isRevealed: Bool, isCurrentSession: Bool) -> some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            Text(isRevealed ? (key.accessToken ?? "—") : viewModel.maskedDisplay(for: key))
                .font(.system(size: CinemaScale.pt(12), weight: .medium, design: .monospaced))
                .foregroundStyle(CinemaColor.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
                .privacySensitive()
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.toggleReveal(key)
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.localized(isRevealed ? "admin.apiKeys.hide" : "admin.apiKeys.reveal"))

            Button {
                copyToken(key)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.localized("admin.apiKeys.copy"))

            if !isCurrentSession {
                Menu {
                    Button(role: .destructive) {
                        viewModel.pendingRevoke = key
                    } label: {
                        Label(loc.localized("admin.apiKeys.revoke"), systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .frame(width: 32, height: 32)
                }
            }
        }
        .padding(.leading, 40) // align under icon+label
    }

    // MARK: - Create sheet

    private var createSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    GlassTextField(
                        label: loc.localized("admin.apiKeys.create.appName"),
                        text: $viewModel.newAppName,
                        placeholder: loc.localized("admin.apiKeys.create.appNamePlaceholder")
                    )

                    Text(loc.localized("admin.apiKeys.create.hint"))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)

                    if let err = viewModel.createErrorMessage {
                        Text(err)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.error)
                    }

                    CinemaButton(
                        title: loc.localized("admin.apiKeys.create.submit"),
                        style: .accent,
                        isLoading: viewModel.isCreating
                    ) {
                        Task {
                            let ok = await viewModel.createKey(using: appState.apiClient)
                            if ok {
                                viewModel.showCreateSheet = false
                            }
                        }
                    }
                    .disabled(viewModel.newAppName.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isCreating)
                    .padding(.top, CinemaSpacing.spacing3)
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(loc.localized("admin.apiKeys.create.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel")) { viewModel.showCreateSheet = false }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Reveal-on-create sheet

    /// Dedicated modal that fires right after a successful create. The
    /// token is auto-revealed (we just created it — the user expects to
    /// see it) with a prominent copy button and a "store it securely"
    /// reminder. User must explicitly dismiss — no tap-outside-to-dismiss
    /// for this one (presentationDetents without .large disables indicator).
    private func revealOnCreateSheet(for key: AuthenticationInfo) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    HStack(spacing: CinemaSpacing.spacing3) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: CinemaScale.pt(28)))
                            .foregroundStyle(CinemaColor.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc.localized("admin.apiKeys.created.title"))
                                .font(CinemaFont.headline(.small))
                                .foregroundStyle(CinemaColor.onSurface)
                            if let name = key.appName {
                                Text(name)
                                    .font(CinemaFont.label(.medium))
                                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                            }
                        }
                    }

                    Text(loc.localized("admin.apiKeys.created.message"))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                        Text(loc.localized("admin.apiKeys.created.tokenLabel"))
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)

                        Text(key.accessToken ?? "—")
                            .font(.system(size: CinemaScale.pt(13), design: .monospaced))
                            .foregroundStyle(CinemaColor.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(CinemaSpacing.spacing3)
                            .background(CinemaColor.surfaceContainerHigh)
                            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
                            .textSelection(.enabled)
                            .privacySensitive()
                    }

                    CinemaButton(
                        title: loc.localized("admin.apiKeys.created.copy"),
                        style: .accent,
                        icon: "doc.on.doc"
                    ) {
                        copyToken(key)
                    }
                    .padding(.top, CinemaSpacing.spacing2)

                    Text(loc.localized("admin.apiKeys.created.reminder"))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(.orange)
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.localized("action.done")) { viewModel.freshlyCreatedKey = nil }
                        .font(.system(size: CinemaScale.pt(16), weight: .semibold))
                        .foregroundStyle(themeManager.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(false)
    }

    // MARK: - Helpers

    private var freshlyCreatedBinding: Binding<IdentifiableKey?> {
        Binding(
            get: { viewModel.freshlyCreatedKey.map { IdentifiableKey(key: $0) } },
            set: { viewModel.freshlyCreatedKey = $0?.key }
        )
    }

    private func copyToken(_ key: AuthenticationInfo) {
        guard let token = key.accessToken else { return }
        // Use `setItems(_:options:)` rather than `UIPasteboard.general.string =`
        // so the token (a) never leaves the local device via Universal Clipboard
        // and (b) expires after 60 s — long enough to paste once, short enough
        // that a later-foregrounded app can't scrape it from the pasteboard.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: token]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(60)
            ]
        )
        toasts.success(loc.localized("admin.apiKeys.copied"))
    }
}

// `.sheet(item:)` needs Identifiable — AuthenticationInfo's `id: Int?` is
// optional, which Identifiable wants non-optional. Small wrapper keyed on
// id (falling back to a UUID for paranoia).
private struct IdentifiableKey: Identifiable {
    let key: AuthenticationInfo
    var id: String { key.id.map(String.init) ?? UUID().uuidString }
}
#endif
