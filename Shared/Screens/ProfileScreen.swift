import SwiftUI
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Profile")

/// The signed-in user's own account: password, and the playback preferences the
/// SERVER holds for them.
///
/// The preferences are deliberately server-side rather than another
/// `@AppStorage` key. Jellyfin honours `audioLanguagePreference` /
/// `subtitleLanguagePreference` when it builds `PlaybackInfo`, so setting them
/// here is setting them for every Jellyfin client this account uses — where a
/// local copy would be a second opinion that silently disagrees with all of
/// them.
///
/// Nothing here is admin: `AdminAPI.updateUserPassword` is an admin resetting
/// somebody ELSE's password and carries no proof of identity. This screen uses
/// `AuthAPI.changeOwnPassword`, which sends the current password, and is
/// therefore reachable by any signed-in user.
struct ProfileScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    @State private var model = ProfileModel()
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    var body: some View {
        content
            .task { await model.load(using: appState) }
        #if os(iOS)
            .navigationTitle(loc.localized("profile.title"))
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                #if os(tvOS)
                // tvOS draws no navigation bar, so the title rides in-scroll.
                Text(loc.localized("profile.title"))
                    .font(CinemaFont.display(.small))
                    .foregroundStyle(CinemaColor.onSurface)
                #endif

                header
                passwordSection
                preferencesSection
                Spacer(minLength: CinemaSpacing.spacing8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, pagePadding)
            .padding(.top, CinemaSpacing.spacing5)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        .background(CinemaColor.surface.ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: CinemaSpacing.spacing4) {
            UserAvatar(
                userId: appState.currentUserId,
                name: appState.currentUser?.name,
                primaryImageTag: appState.currentUser?.primaryImageTag,
                size: avatarSize
            )
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                Text(appState.currentUser?.name ?? "")
                    .font(CinemaFont.headline(.medium))
                    .foregroundStyle(CinemaColor.onSurface)
                if let server = appState.serverInfo?.name {
                    Text(server)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Password

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            sectionHeader(loc.localized("profile.password.section"))

            GlassTextField(
                label: loc.localized("profile.password.current"),
                text: $currentPassword,
                icon: "lock",
                isSecure: true
            )
            GlassTextField(
                label: loc.localized("profile.password.new"),
                text: $newPassword,
                icon: "lock.rotation",
                isSecure: true
            )
            GlassTextField(
                label: loc.localized("profile.password.confirm"),
                text: $confirmPassword,
                icon: "checkmark.shield",
                isSecure: true
            )

            CinemaButton(
                title: loc.localized("profile.password.change"),
                style: .accent,
                isLoading: model.isChangingPassword
            ) {
                Task { await changePassword() }
            }
            .frame(maxWidth: ctaWidth)
            .disabled(!canSubmitPassword)
            .opacity(canSubmitPassword ? 1 : 0.5)
        }
    }

    /// Every field filled. The match and the emptiness are checked at submit
    /// time so the user is TOLD what is wrong, rather than facing a button that
    /// is dead for a reason nothing on screen explains.
    private var canSubmitPassword: Bool {
        !model.isChangingPassword
            && !currentPassword.isEmpty
            && !newPassword.isEmpty
            && !confirmPassword.isEmpty
    }

    private func changePassword() async {
        guard newPassword == confirmPassword else {
            toast.error(loc.localized("profile.password.mismatch"))
            return
        }
        let outcome = await model.changePassword(
            current: currentPassword, new: newPassword, using: appState
        )
        switch outcome {
        case .success:
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            toast.success(loc.localized("profile.password.changed"))
        case .refused:
            toast.error(loc.localized("profile.password.rejected"))
        case .failed(let error):
            toast.error(loc.userFacingMessage(for: error))
        }
    }

    // MARK: - Server-side playback preferences

    @ViewBuilder
    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            sectionHeader(loc.localized("profile.preferences.section"))
            Text(loc.localized("profile.preferences.hint"))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
            if !model.preferencesLoaded {
                // The read failed. Saying so beats offering pickers that would
                // write this type's defaults over the account's real settings.
                Text(loc.localized("profile.preferences.unavailable"))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.error)
            }

            languageRow(
                label: loc.localized("profile.audioLanguage"),
                icon: "waveform",
                selection: model.preferences.audioLanguage
            ) { code in
                Task { await save { $0.audioLanguage = code } }
            }

            languageRow(
                label: loc.localized("profile.subtitleLanguage"),
                icon: "captions.bubble",
                selection: model.preferences.subtitleLanguage
            ) { code in
                Task { await save { $0.subtitleLanguage = code } }
            }

            subtitleModeRow
        }
        .disabled(!model.preferencesLoaded)
        .opacity(model.preferencesLoaded ? 1 : 0.6)
    }

    private func save(_ mutate: (inout UserPlaybackPreferences) -> Void) async {
        var next = model.preferences
        mutate(&next)
        switch await model.savePreferences(next, using: appState) {
        case .saved:
            toast.success(loc.localized("profile.preferences.saved"))
        case .skipped:
            // Nothing was written, so nothing is claimed. Reached when the
            // preferences never loaded — the pickers are disabled in that state,
            // so this is a belt-and-braces branch, not a user-visible path.
            break
        case .failed(let error):
            toast.error(loc.userFacingMessage(for: error))
        }
    }

    private func languageName(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return loc.localized("profile.language.none") }
        return model.cultures.first { $0.code == code }?.displayName ?? code
    }

    @ViewBuilder
    private func languageRow(
        label: String,
        icon: String,
        selection: String?,
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        // A `Menu` on iOS and a `confirmationDialog` on tvOS — the two idioms
        // this app already uses for a value picker (see the sleep-timer row).
        #if os(tvOS)
        ProfileTVPickerRow(
            icon: icon,
            label: label,
            value: languageName(selection),
            options: pickerOptions,
            onSelect: onSelect
        )
        #else
        HStack {
            Image(systemName: icon)
                .foregroundStyle(themeManager.accent)
                .frame(width: 24)
            Text(label)
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurface)
            Spacer()
            Menu {
                ForEach(pickerOptions, id: \.0) { option in
                    Button(option.1) { onSelect(option.0.isEmpty ? nil : option.0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(languageName(selection))
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: CinemaScale.pt(11), weight: .semibold))
                        .foregroundStyle(CinemaColor.outlineVariant)
                }
            }
            .tint(themeManager.accent)
        }
        .padding(CinemaSpacing.spacing3)
        .glassPanel(cornerRadius: CinemaRadius.large)
        #endif
    }

    /// "No preference" first, then every language the server knows. The empty
    /// code is what clears the preference server-side.
    private var pickerOptions: [(String, String)] {
        [("", loc.localized("profile.language.none"))]
            + model.cultures.map { ($0.code, $0.displayName) }
    }

    @ViewBuilder
    private var subtitleModeRow: some View {
        let options = UserPlaybackPreferences.SubtitleMode.allCases.map {
            ($0.rawValue, loc.localized("profile.subtitleMode.\($0.rawValue)"))
        }
        let current = loc.localized("profile.subtitleMode.\(model.preferences.subtitleMode.rawValue)")
        #if os(tvOS)
        ProfileTVPickerRow(
            icon: "text.bubble",
            label: loc.localized("profile.subtitleMode"),
            value: current,
            options: options
        ) { raw in
            guard let raw, let mode = UserPlaybackPreferences.SubtitleMode(rawValue: raw) else { return }
            Task { await save { $0.subtitleMode = mode } }
        }
        #else
        HStack {
            Image(systemName: "text.bubble")
                .foregroundStyle(themeManager.accent)
                .frame(width: 24)
            Text(loc.localized("profile.subtitleMode"))
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurface)
            Spacer()
            Menu {
                ForEach(options, id: \.0) { option in
                    Button(option.1) {
                        guard let mode = UserPlaybackPreferences.SubtitleMode(rawValue: option.0) else { return }
                        Task { await save { $0.subtitleMode = mode } }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: CinemaScale.pt(11), weight: .semibold))
                        .foregroundStyle(CinemaColor.outlineVariant)
                }
            }
            .tint(themeManager.accent)
        }
        .padding(CinemaSpacing.spacing3)
        .glassPanel(cornerRadius: CinemaRadius.large)
        #endif
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(CinemaFont.label(.large))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .textCase(.uppercase)
            .tracking(1.2)
    }

    private var pagePadding: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.pagePadding
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var avatarSize: CGFloat {
        #if os(tvOS)
        140
        #else
        64
        #endif
    }

    private var ctaWidth: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.ctaWidth
        #else
        .infinity
        #endif
    }
}

#if os(tvOS)
/// A settings-shaped value row with a `confirmationDialog` picker — the same
/// idiom as the sleep-timer and subtitle-size rows, but standalone so it can
/// own the `@FocusState` each instance needs.
private struct ProfileTVPickerRow: View {
    let icon: String
    let label: String
    let value: String
    /// `(code, display)`. An empty code means "no preference".
    let options: [(String, String)]
    let onSelect: (String?) -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEffects
    @FocusState private var isFocused: Bool
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: icon)
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)
                Text(label)
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Text(value)
                    .font(.system(size: CinemaScale.pt(17), weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                Image(systemName: "chevron.up.chevron.down")
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(
                isFocused: isFocused,
                accent: themeManager.accent,
                animated: motionEffects,
                colorScheme: themeManager.darkModeEnabled ? .dark : .light
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($isFocused)
        .confirmationDialog(label, isPresented: $showPicker) {
            ForEach(options, id: \.0) { option in
                Button(option.1) { onSelect(option.0.isEmpty ? nil : option.0) }
            }
        }
    }
}
#endif

@MainActor
@Observable
final class ProfileModel {
    private(set) var cultures: [ServerCulture] = []
    private(set) var preferences = UserPlaybackPreferences()
    private(set) var isChangingPassword = false
    /// Whether `preferences` came from the server rather than from this type's
    /// own default.
    ///
    /// Load-bearing, not bookkeeping: `savePreferences` posts the WHOLE slice,
    /// so saving from an unloaded default would clear this account's audio
    /// language, subtitle language and subtitle mode — on every Jellyfin client
    /// it has — because one read failed on the way in.
    private(set) var preferencesLoaded = false
    /// Serialises saves. Each picker fires its own task, and every save is a
    /// server-side read-modify-write: two overlapping ones let the second read
    /// the configuration before the first has written it, so the first field
    /// silently loses. Same chained-task shape as
    /// `PlaybackLiveActivityController.enqueue`.
    private var saveChain: Task<Void, Never>?

    enum PasswordOutcome {
        case success
        /// The server rejected the change — in practice, a wrong current
        /// password. Kept apart from a transport failure so the message can say
        /// which it was.
        case refused
        case failed(any Error)
    }

    /// Both halves fail independently: no culture list still leaves the
    /// password form usable, and the pickers still render.
    ///
    /// A failed preference read leaves `preferencesLoaded` false, which DISABLES
    /// saving rather than letting the user write this type's defaults over their
    /// account — see that property.
    func load(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        async let culturesTask = try? appState.apiClient.getCultures()
        async let prefsTask = try? appState.apiClient.getUserConfiguration(userId: userId)
        cultures = await culturesTask ?? []
        if let loaded = await prefsTask {
            preferences = loaded
            preferencesLoaded = true
        }
    }

    func changePassword(current: String, new: String, using appState: AppState) async -> PasswordOutcome {
        guard let userId = appState.currentUserId else { return .refused }
        isChangingPassword = true
        defer { isChangingPassword = false }
        do {
            try await appState.apiClient.changeOwnPassword(
                userId: userId, currentPassword: current, newPassword: new
            )
            return .success
        } catch {
            // Never log the error's description here: the payload carried the
            // password, and a server that echoes its request would put it in
            // the system log.
            logger.error("Password change failed")
            // The client maps the server's refusal to its own case, so this
            // layer never has to read a status code.
            if case JellyfinError.invalidCredentials = error { return .refused }
            return .failed(error)
        }
    }

    /// What a save actually did. `nil` used to mean both "saved" and "did
    /// nothing", so a save that never ran still toasted success.
    enum SaveOutcome {
        case saved
        /// Refused before reaching the server — no signed-in user, or the
        /// preferences were never read, so writing would clear them.
        case skipped
        case failed(any Error)
    }

    /// Optimistic, with rollback: the pickers must not keep showing a language
    /// the server did not record.
    ///
    /// Serialised through `saveChain`, and the rollback target is read INSIDE
    /// the chained work rather than captured at call time — a snapshot taken
    /// before an earlier save landed would, on a later failure, restore a state
    /// that predates both and discard a change the server had accepted.
    func savePreferences(_ next: UserPlaybackPreferences, using appState: AppState) async -> SaveOutcome {
        guard let userId = appState.currentUserId, preferencesLoaded else { return .skipped }
        let previous = saveChain
        let work = Task { @MainActor [weak self] () -> SaveOutcome in
            await previous?.value
            guard let self else { return .skipped }
            let snapshot = self.preferences
            self.preferences = next
            do {
                try await appState.apiClient.updateUserConfiguration(userId: userId, preferences: next)
                return .saved
            } catch {
                logger.error("Preference save failed: \(error.localizedDescription, privacy: .public)")
                self.preferences = snapshot
                return .failed(error)
            }
        }
        // The chain waits on completion, not on the outcome.
        saveChain = Task { _ = await work.value }
        return await work.value
    }
}
