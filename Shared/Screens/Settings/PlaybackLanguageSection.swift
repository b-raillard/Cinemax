import SwiftUI
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "PlaybackLanguages")

/// Réglages → Lecture → Langues: the account's preferred audio language,
/// subtitle language and subtitle mode (moved from the Profile on 2026-11-24 —
/// they are playback settings). SERVER-side (`UserConfiguration`), never an
/// `@AppStorage` key: Jellyfin honours them for every client of the account,
/// and the VLC player reads them as step 2 of `TrackDefaultsPolicy`.
struct PlaybackLanguageSection: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(ToastCenter.self) private var toast

    @State private var model = PlaybackLanguageModel()

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            header
            rows
                .disabled(!model.preferencesLoaded)
                .opacity(model.preferencesLoaded ? 1 : 0.6)
            footnote
        }
        .task { await model.load(using: appState) }
    }

    /// The hint, or — when the read failed — why the rows are dimmed. On tvOS
    /// it is FOCUSABLE prose while the rows are disabled: they take no focus,
    /// and focus is the only thing that scrolls a tvOS page, so without it a
    /// failed read left the whole section and its message below the screen.
    @ViewBuilder
    private var footnote: some View {
        let text = Text(loc.localized(model.loadFailed ? "profile.preferences.unavailable" : "profile.preferences.hint"))
            .font(CinemaFont.dynamicLabel(.small))
        #if os(tvOS)
        Group {
            if model.loadFailed {
                text.foregroundStyle(CinemaColor.error)
            } else {
                text
            }
        }
        .tvFocusableProse()
        // Only while the rows are disabled: with them focusable, the last row
        // already scrolls this one-liner into view, and a focus stop on a
        // hint would be a dead press.
        .focusable(!model.preferencesLoaded)
        .padding(.horizontal, CinemaSpacing.spacing2)
        #else
        text
            .foregroundStyle(model.loadFailed ? CinemaColor.error : CinemaColor.onSurfaceVariant)
            .padding(.horizontal, CinemaSpacing.spacing2)
        #endif
    }

    @ViewBuilder
    private var header: some View {
        #if os(tvOS)
        Text(loc.localized("settings.playback.languages").uppercased())
            .font(.system(size: CinemaScale.pt(17), weight: .bold))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .tracking(1.5)
            .accessibilityAddTraits(.isHeader)
        #else
        iOSSettingsSectionHeader(loc.localized("settings.playback.languages"))
        #endif
    }

    @ViewBuilder
    private var rows: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            audioRow
            subtitleRow
            subtitleModeRow
        }
        #else
        VStack(spacing: 0) {
            audioRow
            iOSSettingsDivider
            subtitleRow
            iOSSettingsDivider
            subtitleModeRow
        }
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        #endif
    }

    private var audioRow: some View {
        valueRow(
            icon: "waveform", label: loc.localized("profile.audioLanguage"),
            options: languageOptions, selectedCode: model.preferences.audioLanguage ?? ""
        ) { code in
            save { $0.audioLanguage = code }
        }
    }

    private var subtitleRow: some View {
        valueRow(
            icon: "captions.bubble", label: loc.localized("profile.subtitleLanguage"),
            options: languageOptions, selectedCode: model.preferences.subtitleLanguage ?? ""
        ) { code in
            save { $0.subtitleLanguage = code }
        }
    }

    private var subtitleModeRow: some View {
        let mode = model.preferences.subtitleMode
        let options = UserPlaybackPreferences.SubtitleMode.allCases.map {
            ($0.rawValue, loc.localized("profile.subtitleMode.\($0.rawValue)"))
        }
        return valueRow(
            icon: "text.bubble", label: loc.localized("profile.subtitleMode"),
            options: options, selectedCode: mode.rawValue
        ) { raw in
            guard let raw, let next = UserPlaybackPreferences.SubtitleMode(rawValue: raw) else { return }
            save { $0.subtitleMode = next }
        }
    }

    /// One value row: a `Menu` with a `Picker` on iOS (the system checkmark on
    /// the current option), `LanguageTVPickerRow` and its option list on tvOS.
    /// `onSelect` gets `nil` for the empty code, « no preference ». The value
    /// shown is the current option's name — the raw code when the server's
    /// list does not carry it (an empty culture list).
    @ViewBuilder
    private func valueRow(
        icon: String, label: String, options: [(String, String)],
        selectedCode: String, onSelect: @escaping (String?) -> Void
    ) -> some View {
        // Jellyfin Web stores a language in three letters (`fra`), the
        // server's culture list offers two (`fr`): match them by language.
        let current = options.first { $0.0 == selectedCode }
            ?? options.first { !$0.0.isEmpty && LanguageKey.of($0.0) == LanguageKey.of(selectedCode) }
        // « No preference » reads « Aucune » in the row (two lines at the
        // standard size otherwise); the list keeps the full wording.
        let value = current?.0.isEmpty == true ? loc.localized("settings.playback.languages.none") : (current?.1 ?? selectedCode)
        let code = current?.0 ?? selectedCode
        #if os(tvOS)
        LanguageTVPickerRow(
            icon: icon, label: label, value: value, options: options,
            selectedCode: code, onSelect: onSelect
        )
        #else
        iOSSettingsRow {
            SettingsRowAdaptiveLayout {
                HStack(spacing: 0) {
                    iOSRowIcon(systemName: icon, color: themeManager.accent)
                    Text(label)
                        .font(CinemaFont.dynamicLabel(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                }
            } control: {
                Menu {
                    Picker(label, selection: Binding(
                        get: { code },
                        set: { onSelect($0.isEmpty ? nil : $0) }
                    )) {
                        ForEach(options, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(value)
                            .font(CinemaFont.dynamicLabel(.large))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: CinemaScale.pt(11), weight: .semibold))
                            .foregroundStyle(CinemaColor.outlineVariant)
                    }
                }
                .tint(themeManager.accent)
            }
        }
        #endif
    }

    /// "No preference" first, then every language the server knows. The empty
    /// code is what clears the preference server-side.
    private var languageOptions: [(String, String)] {
        [("", loc.localized("profile.language.none"))] + model.cultures.map { ($0.code, $0.displayName) }
    }

    private func save(_ mutate: (inout UserPlaybackPreferences) -> Void) {
        var next = model.preferences
        mutate(&next)
        Task {
            switch await model.savePreferences(next, using: appState) {
            case .saved:
                toast.success(loc.localized("profile.preferences.saved"))
            case .skipped:
                // Nothing was written, so nothing is claimed. Reached when the
                // preferences never loaded — the rows are disabled then.
                break
            case .failed(let error):
                toast.error(loc.userFacingMessage(for: error))
            }
        }
    }
}

#if os(tvOS)
/// A settings-shaped value row that opens `LanguageTVOptionList`. It was a
/// `confirmationDialog`: fine for the five subtitle modes, unusable for the ~190
/// cultures a server lists, and neither said which option was current
/// (audit §5, lot 9).
private struct LanguageTVPickerRow: View {
    let icon: String
    let label: String
    let value: String
    /// `(code, display)`. An empty code means "no preference".
    let options: [(String, String)]
    /// The current option's code (`""` = no preference).
    let selectedCode: String
    let onSelect: (String?) -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
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
                Image(systemName: "chevron.right")
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
        .fullScreenCover(isPresented: $showPicker) {
            LanguageTVOptionList(title: label, options: options, selectedCode: selectedCode) { code in
                onSelect(code.isEmpty ? nil : code)
            }
            // A presentation does not inherit the injected environment.
            .environment(themeManager)
            .environment(loc)
        }
    }
}

/// The option list behind `LanguageTVPickerRow`: the standard cover chrome
/// (title + accent Cancel, `onExitCommand`), one focusable row per option, a
/// check and `.isSelected` on the current one, and focus + scroll starting
/// THERE rather than at the top of 190 languages.
private struct LanguageTVOptionList: View {
    let title: String
    let options: [(String, String)]
    let selectedCode: String
    let onSelect: (String) -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text(title)
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer(minLength: CinemaSpacing.spacing6)
                CinemaButton(title: loc.localized("action.cancel"), style: .accent) { dismiss() }
                    .frame(width: CinemaTVLayout.ctaWidth)
            }
            .padding(.horizontal, CinemaTVLayout.pagePadding)
            .padding(.top, CinemaSpacing.spacing8)
            .padding(.bottom, CinemaSpacing.spacing5)
            .focusSection()

            ScrollViewReader { proxy in
                ScrollView {
                    // A plain `VStack`: ~190 text rows are cheap, and every row
                    // then EXISTS when `defaultFocus` / `scrollTo` look for the
                    // current one (a lazy stack may not have built it yet).
                    VStack(spacing: CinemaSpacing.spacing2) {
                        ForEach(options, id: \.0) { option in
                            row(option)
                        }
                    }
                    .padding(.horizontal, CinemaTVLayout.pagePadding)
                    .padding(.bottom, CinemaSpacing.spacing8)
                }
                .onAppear { proxy.scrollTo(selectedCode, anchor: .center) }
            }
            .focusSection()
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .defaultFocus($focused, selectedCode)
        .onExitCommand { dismiss() }
    }

    private func row(_ option: (String, String)) -> some View {
        let isSelected = option.0 == selectedCode
        return Button {
            onSelect(option.0)
            dismiss()
        } label: {
            HStack {
                Text(option.1)
                    .font(.system(size: CinemaScale.pt(20), weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: CinemaScale.pt(18), weight: .bold))
                        .foregroundStyle(themeManager.accent)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .fill(CinemaColor.surfaceContainerHigh)
            )
        }
        .buttonStyle(TVFilterRowButtonStyle(accent: themeManager.accent))
        // The validated full-width-row pattern: without these two, the system
        // focus effect draws on top of the accent stroke.
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focused, equals: option.0)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(option.0)
    }
}
#endif

@MainActor
@Observable
final class PlaybackLanguageModel {
    private(set) var cultures: [ServerCulture] = []
    private(set) var preferences = UserPlaybackPreferences()
    /// Whether `preferences` came from the server rather than from this type's
    /// own default.
    ///
    /// Load-bearing, not bookkeeping: `savePreferences` posts the WHOLE slice,
    /// so saving from an unloaded default would clear this account's audio
    /// language, subtitle language and subtitle mode — on every Jellyfin client
    /// it has — because one read failed on the way in.
    private(set) var preferencesLoaded = false
    /// The read was attempted and failed (the section says so).
    private(set) var loadFailed = false
    /// Serialises saves. Each picker fires its own task, and every save is a
    /// server-side read-modify-write: two overlapping ones let the second read
    /// the configuration before the first has written it, so the first field
    /// silently loses.
    private var saveChain: Task<Void, Never>?

    /// What a save actually did. `nil` used to mean both "saved" and "did
    /// nothing", so a save that never ran still toasted success.
    enum SaveOutcome {
        case saved
        /// Refused before reaching the server — no signed-in user, or the
        /// preferences were never read, so writing would clear them.
        case skipped
        case failed(any Error)
    }

    /// Both halves fail independently: no culture list still renders the rows.
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
            loadFailed = false
        } else {
            loadFailed = !preferencesLoaded
        }
    }

    /// Optimistic, with rollback: the rows must not keep showing a language
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
                // The player reads these from `appState.currentUser`: refresh it,
                // or the change waits for the next foreground.
                await appState.refreshCurrentUser()
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
