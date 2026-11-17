import SwiftUI
import CinemaxKit

/// Réglages → Demandes → a user (proposal B, owner 2026-11-08): « Peut
/// demander » (the Jellyfin side, `SeerrUserConfig`), then « Validation
/// automatique » for films and series (the Seerr side, the user's permission
/// bits). iOS pushes it; tvOS draws it in place of the Demandes page.
///
/// A standalone view with its own environment (root RULE: a pushed
/// destination built by an extension method never redraws). Everything it
/// shows comes from `activation`, an `@Observable` shared with the list.
struct SeerrAccountPage: View, SeerrSettingsChrome {
    let activation: SeerrActivationModel
    let userId: String

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(SeerrSession.self) private var seerr
    @Environment(\.motionEffectsEnabled) private var motionEffects
    /// Never read: the fonts are point sizes computed in the body, so a live
    /// text-size change must redraw the page (as `RequestsSettingsScreen`).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    #if os(tvOS)
    @FocusState private var focusedItem: SettingsFocus?
    #endif

    private var line: SeerrUserLine? { activation.lines.first { $0.id == userId } }

    /// The signed-in Seerr user: it is THEIR permission that allows a change.
    private var me: SeerrUser? {
        if case .connected(let user) = seerr.connection { user } else { nil }
    }

    var body: some View {
        #if os(iOS)
        ScrollView(showsIndicators: false) {
            content
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.bottom, CinemaSpacing.spacing8)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(line?.name ?? "")
        .navigationBarTitleDisplayMode(.large)
        #else
        content
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
            if let line {
                #if os(tvOS)
                Text(line.name)
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .accessibilityAddTraits(.isHeader)
                #endif
                noteText(SeerrActivationModel.lineText(line.kind, loc: loc))

                panel {
                    switchRow(
                        id: "seerr.account.request", label: loc.localized("seerr.user.canRequest"),
                        detail: loc.localized("seerr.user.canRequest.detail"),
                        state: (line.isEnabled, activation.togglingUserIds.contains(line.id))
                    ) {
                        Task {
                            await activation.toggle(line, appState: appState, session: seerr, toasts: toasts, loc: loc)
                        }
                    }
                }

                if let target = line.kind.seerrUser {
                    autoApproveSection(line, target: target)
                    issueReportSection(line, target: target)
                }
            }
        }
    }

    // MARK: Validation automatique

    @ViewBuilder
    private func autoApproveSection(_ line: SeerrUserLine, target: SeerrUser) -> some View {
        let access = SeerrAutoApprovalAccess.of(target, me: me)
        let saving = activation.savingAutoApprove.contains(line.id)
        // Data conditions only (the tvOS busy RULE): a write under way keeps
        // the rows focusable and the model ignores a second press.
        let locked = access != .editable || !line.isEnabled
        let permissions = target.permissions

        sectionHeader(loc.localized("seerr.user.autoApprove"))
            .padding(.top, CinemaSpacing.spacing3)
        panel {
            kindRow(.movie, label: loc.localized("seerr.user.autoApprove.movies"),
                    isOn: permissions.autoApproves(.movie), saving: saving, locked: locked)
            divider
            kindRow(.tv, label: loc.localized("seerr.user.autoApprove.series"),
                    isOn: permissions.autoApproves(.tv), saving: saving, locked: locked)
        }
        if let key = access.noteKey {
            noteText(loc.localized(key))
        } else if !line.isEnabled {
            noteText(loc.localized("seerr.user.autoApprove.enableFirst"))
        } else {
            noteText(loc.localized("seerr.user.autoApprove.note"))
        }
    }

    // MARK: Signalement

    /// The right to report an owned season's missing episodes — without it
    /// the fiche shows the missing lines but no « Signaler » button.
    @ViewBuilder
    private func issueReportSection(_ line: SeerrUserLine, target: SeerrUser) -> some View {
        let access = SeerrIssueReportAccess.of(target, me: me)
        let isOn = target.permissions.canReportIssues
        let locked = access != .editable || !line.isEnabled

        sectionHeader(loc.localized("seerr.user.report"))
            .padding(.top, CinemaSpacing.spacing3)
        panel {
            switchRow(
                id: "seerr.account.report", label: loc.localized("seerr.user.report.episodes"), detail: nil,
                state: (isOn, activation.savingAutoApprove.contains(line.id))
            ) {
                Task {
                    let saved = await activation.setIssueReporting(!isOn, userId: userId, session: seerr, appState: appState)
                    if !saved, let name = activation.lines.first(where: { $0.id == userId })?.name {
                        toasts.error(loc.localized("seerr.user.report.failed", name))
                    }
                }
            }
            .disabled(locked)
            .opacity(locked ? 0.5 : 1)
        }
        if let key = access.noteKey {
            noteText(loc.localized(key))
        } else if !line.isEnabled {
            noteText(loc.localized("seerr.user.autoApprove.enableFirst"))
        } else {
            noteText(loc.localized("seerr.user.report.note"))
        }
    }

    private func kindRow(
        _ kind: SeerrMediaKind, label: String, isOn: Bool, saving: Bool, locked: Bool
    ) -> some View {
        switchRow(id: "seerr.account.\(kind.rawValue)", label: label, detail: nil, state: (isOn, saving)) {
            Task {
                let saved = await activation.setAutoApprove(kind, !isOn, userId: userId, session: seerr, appState: appState)
                if !saved, let name = activation.lines.first(where: { $0.id == userId })?.name {
                    toasts.error(loc.localized("seerr.user.autoApprove.failed", name))
                }
            }
        }
        .disabled(locked)
        .opacity(locked ? 0.5 : 1)
    }

    // MARK: Chrome (the Demandes page's own, per platform)

    /// `state`: the switch's position, and whether its write is under way.
    private func switchRow(
        id: String, label: String, detail: String?, state: (isOn: Bool, isBusy: Bool),
        action: @escaping () -> Void
    ) -> some View {
        let isOn = state.isOn
        let isBusy = state.isBusy
        return Button(action: action) {
            rowChrome(id: id) {
                let text = VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                    Text(label)
                        .font(rowLabelFont)
                        .foregroundStyle(CinemaColor.onSurface)
                    if let detail {
                        Text(detail)
                            .font(rowDetailFont)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                let control = Group {
                    if isBusy {
                        ProgressView()
                    } else {
                        CinemaToggleIndicator(isOn: isOn, accent: themeManager.accent, animated: motionEffects)
                    }
                }
                #if os(tvOS)
                HStack(spacing: CinemaSpacing.spacing3) {
                    text.padding(.vertical, CinemaSpacing.spacing2)
                    Spacer(minLength: CinemaSpacing.spacing3)
                    control
                }
                #else
                SettingsRowAdaptiveLayout { text } control: { control }
                #endif
            }
        }
        .buttonStyle(.plain)
        .modifier(RowFocus(id: id, focus: focusBinding))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(loc.localized(isOn ? "a11y.toggle.on" : "a11y.toggle.off"))
        .accessibilityHint(detail ?? "")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { action() }
    }

    @ViewBuilder
    private func rowChrome<Content: View>(id: String, @ViewBuilder _ content: () -> Content) -> some View {
        #if os(tvOS)
        content()
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: focusedItem == .toggle(id), accent: themeManager.accent,
                                 animated: motionEffects,
                                 colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        #else
        iOSSettingsRow { content() }
        #endif
    }

    #if os(tvOS)
    private var focusBinding: FocusState<SettingsFocus?>.Binding { $focusedItem }
    #else
    private var focusBinding: Void { () }
    #endif
}
