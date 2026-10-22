#if os(iOS)
import SwiftUI
import CinemaxKit

// MARK: - Appearance Detail View (iOS)

/// Standalone View struct so NavigationStack destination has its own `@Observable`
/// observation tracking for `ThemeManager` and `LocalizationManager`.
///
/// Extracted from `SettingsScreen+iOS.swift` to keep that file focused on layout
/// scaffolding. All rows here are Appearance-only (dark mode, accent, language).
struct IOSAppearanceDetailView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(LocalizationManager.self) var loc
    @Environment(SeasonalThemeController.self) private var seasonal
    /// The « Halloween » choice is the Pro's (lot C). Optional like
    /// `SettingsScreen`'s: a host without it leaves the choice open.
    @Environment(ProFeatureAccess.self) private var proAccess: ProFeatureAccess?
    @Environment(\.motionEffectsEnabled) private var motionEffects
    @Environment(ToastCenter.self) private var toasts
    /// `UIApplication.alternateIconName` is not observable: a copy, refreshed
    /// on appear and after each switch (lot D).
    @State private var appIconName: String?
    @AppStorage(SettingsKey.rainbowUnlocked) private var rainbowUnlocked: Bool = SettingsKey.Default.rainbowUnlocked
    @AppStorage(SettingsKey.motionEffects) private var motionEffectsStorage: Bool = SettingsKey.Default.motionEffects
    /// When on, the system wins over `motionEffectsStorage` (see
    /// `MotionEffects.isEnabled`) — the row says so rather than showing a
    /// switch that reads "on" over a screen that no longer moves.
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var fontScale: Double = UserDefaults.standard.object(forKey: SettingsKey.uiScale) as? Double ?? SettingsKey.Default.uiScale
    private let fontScaleOptions: [Double] = [0.80, 0.85, 0.90, 0.95, 1.00, 1.05, 1.10, 1.15, 1.20, 1.25, 1.30]

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            iOSSettingsSectionHeader(loc.localized("settings.personalization"))

            VStack(spacing: 0) {
                // The whole row toggles, not just the pill (same shape as `iOSToggleRow`).
                Button {
                    themeManager.darkModeEnabled.toggle()
                    Haptics.tap()
                } label: {
                    iOSSettingsRow {
                        SettingsRowAdaptiveLayout {
                            HStack {
                                iOSRowIcon(systemName: themeManager.darkModeEnabled ? "moon.fill" : "sun.max.fill", color: themeManager.accent)

                                Text(themeManager.darkModeEnabled ? loc.localized("settings.darkMode") : loc.localized("settings.lightMode"))
                                    .font(CinemaFont.dynamicLabel(.large))
                                    .foregroundStyle(CinemaColor.onSurface)
                            }
                        } control: {
                            CinemaToggleIndicator(isOn: themeManager.darkModeEnabled, accent: themeManager.accent, animated: motionEffects)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(loc.localized("settings.darkMode"))
                .accessibilityValue(loc.localized(themeManager.darkModeEnabled ? "a11y.toggle.on" : "a11y.toggle.off"))
                .accessibilityAddTraits(.isToggle)
                .accessibilityAction {
                    themeManager.darkModeEnabled.toggle()
                    Haptics.tap()
                }

                iOSSettingsDivider

                iOSSettingsRow {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                        HStack {
                            iOSRowIcon(systemName: "paintpalette.fill", color: selectedAccent.color)

                            Text(loc.localized("settings.accentColor"))
                                .font(CinemaFont.dynamicLabel(.large))
                                .foregroundStyle(CinemaColor.onSurface)

                            Spacer()
                        }

                        // Spacing 0: each swatch takes an equal share of the row, so
                        // its hit area is the whole slot (≥ 34 pt wide on the
                        // narrowest iPhone, 44 pt tall) rather than the 28 pt dot.
                        HStack(spacing: 0) {
                            ForEach(AccentOption.visibleCases(rainbowUnlocked: rainbowUnlocked)) { option in
                                accentDot(option)
                            }
                        }
                         }
                    .hoverEffectDisabled()
                }

                iOSSettingsDivider

                iOSSettingsRow {
                    SettingsRowAdaptiveLayout {
                        HStack {
                            iOSRowIcon(systemName: "globe", color: themeManager.accent)

                            Text(loc.localized("settings.language"))
                                .font(CinemaFont.dynamicLabel(.large))
                                .foregroundStyle(CinemaColor.onSurface)
                        }
                    } control: {
                        languagePicker
                    }
                }

                iOSSettingsDivider

                Button {
                    motionEffectsStorage.toggle()
                    Haptics.tap()
                } label: {
                    iOSSettingsRow {
                        SettingsRowAdaptiveLayout {
                            HStack {
                                iOSRowIcon(systemName: "sparkles", color: themeManager.accent)

                                VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                                    Text(loc.localized("settings.motionEffects"))
                                        .font(CinemaFont.dynamicLabel(.large))
                                        .foregroundStyle(CinemaColor.onSurface)
                                    if systemReduceMotion {
                                        Text(loc.localized("settings.motionEffects.systemOverride"))
                                            .font(CinemaFont.dynamicLabel(.small))
                                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        } control: {
                            CinemaToggleIndicator(isOn: motionEffectsStorage, accent: themeManager.accent, animated: motionEffects)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(loc.localized("settings.motionEffects"))
                .accessibilityValue(loc.localized(motionEffectsStorage ? "a11y.toggle.on" : "a11y.toggle.off"))
                .accessibilityHint(systemReduceMotion ? loc.localized("settings.motionEffects.systemOverride") : "")
                .accessibilityAddTraits(.isToggle)
                .accessibilityAction {
                    motionEffectsStorage.toggle()
                    Haptics.tap()
                }

                iOSSettingsDivider

                iOSSettingsRow {
                    // The stepper's own « 100% » grows with the text and is
                    // `fixedSize`: beside the label it squeezed it to one
                    // syllable per line (« Tail/le/du/tex/te »).
                    SettingsRowAdaptiveLayout {
                        HStack {
                            iOSRowIcon(systemName: "textformat.size", color: themeManager.accent)
                            Text(loc.localized("settings.fontSize"))
                                .font(CinemaFont.dynamicLabel(.large))
                                .foregroundStyle(CinemaColor.onSurface)
                        }
                    } control: {
                        Stepper(
                            "\(Int((fontScale * 100).rounded()))%", // `Int(1.15 * 100)` is 114 (M3-03)
                            onIncrement: {
                                if let idx = fontScaleOptions.firstIndex(of: fontScale), idx < fontScaleOptions.count - 1 {
                                    fontScale = fontScaleOptions[idx + 1]
                                    themeManager.uiScale = fontScale
                                }
                            },
                            onDecrement: {
                                if let idx = fontScaleOptions.firstIndex(of: fontScale), idx > 0 {
                                    fontScale = fontScaleOptions[idx - 1]
                                    themeManager.uiScale = fontScale
                                }
                            }
                        )
                        .fixedSize()
                        .tint(themeManager.accent)
                    }
                }
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)

            if AppIconSwitcher.isSupported {
                iOSSettingsSectionHeader(loc.localized("settings.appIcon.title"))
                    .padding(.top, CinemaSpacing.spacing4)

                appIconSection
                    .glassPanel(cornerRadius: CinemaRadius.extraLarge)
            }

            iOSSettingsSectionHeader(loc.localized("settings.seasonal.section"))
                .padding(.top, CinemaSpacing.spacing4)

            VStack(spacing: 0) {
                seasonalChoiceRow

                iOSSettingsDivider

                iOSToggleRow(
                    icon: "sparkles",
                    label: loc.localized("settings.seasonal.ambiance"),
                    value: Binding(get: { seasonal.ambianceEnabled }, set: { seasonal.setAmbianceEnabled($0) }),
                    accent: themeManager.accent, animated: motionEffects, loc: loc
                )

                iOSSettingsDivider

                iOSToggleRow(
                    icon: "rectangle.stack",
                    label: loc.localized("settings.seasonal.row"),
                    value: Binding(get: { seasonal.rowEnabled }, set: { seasonal.setRowEnabled($0) }),
                    accent: themeManager.accent, animated: motionEffects, loc: loc
                )
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)

            // Below the switch that shows it, and its space ALWAYS kept (hidden,
            // not removed): under the accent swatches it pushed the switch down
            // at the tap, and at the page's bottom its removal shortened the
            // scroll, which moved the switch too (recette 2026-09-29).
            seasonAccentNote
                .font(CinemaFont.dynamicLabel(.small))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CinemaSpacing.spacing2)
                .padding(.top, CinemaSpacing.spacing2)
        }
    }

    // MARK: - Appearance-specific helpers

    /// « Icône de l'app » (lot D): one tile per `AppIconCatalogue` choice, the
    /// icon shown ringed in the accent. An alternate icon is the Pro's: for a
    /// free user it stays listed, with `ProBadge` (the Administration row's
    /// language), and its tap raises the Pro sheet. The icon a user already
    /// shows is never taken back (`AppIconPickerPolicy.outcome` → `.keep`).
    var appIconSection: some View {
        let tier = proAccess?.currentTier() ?? .founder
        return iOSSettingsRow {
            HStack(alignment: .top, spacing: CinemaSpacing.spacing4) {
                ForEach(AppIconCatalogue.choices) { choice in
                    let isCurrent = choice.alternateName == appIconName
                    appIconTile(choice, isCurrent: isCurrent, isLocked: !isCurrent && AppIconPickerPolicy.isLocked(choice, tier: tier))
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear { appIconName = AppIconSwitcher.currentName }
    }

    func appIconTile(_ choice: AppIconChoice, isCurrent: Bool, isLocked: Bool) -> some View {
        let side: CGFloat = 64
        let radius = side * 0.2237 // the system's icon mask, as `recolor.py` draws it
        return Button {
            chooseAppIcon(choice)
        } label: {
            VStack(spacing: CinemaSpacing.spacing2) {
                Image(choice.previewImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                            .strokeBorder(isCurrent ? themeManager.accent : .clear, lineWidth: 2.5)
                    }
                Text(loc.localized(choice.labelKey))
                    .font(CinemaFont.dynamicLabel(.medium))
                    .foregroundStyle(isCurrent ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if isLocked {
                    ProBadge()
                }
            }
            .frame(minWidth: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized(choice.labelKey))
        .accessibilityValue(isLocked ? loc.localized("settings.appIcon.locked") : "")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// iOS shows its own « icon changed » alert on success; a failure is
    /// logged by `AppIconSwitcher` and toasted here.
    func chooseAppIcon(_ choice: AppIconChoice) {
        switch AppIconPickerPolicy.outcome(choosing: choice, current: appIconName, tier: proAccess?.currentTier() ?? .founder) {
        case .keep:
            return
        case .upsell:
            proAccess?.admit(.appIcons)
        case .apply(let name):
            Haptics.tap()
            Task {
                do {
                    try await AppIconSwitcher.set(name)
                } catch {
                    toasts.error(loc.localized("settings.appIcon.error"))
                }
                appIconName = AppIconSwitcher.currentName
            }
        }
    }

    /// Automatique / Désactivé / Halloween (lot C) — the whole row opens the
    /// menu, like the sleep-timer picker. The selection shown is the
    /// EFFECTIVE one: a forced Halloween the tier refuses reads Automatique.
    /// Halloween is the Pro's « toute l'année »: locked, its item wears a lock
    /// and its tap raises the Pro sheet (`ProFeatureAccess.admit`) instead.
    var seasonalChoiceRow: some View {
        let selected = seasonal.effectiveSetting
        let forcedLocked = proAccess?.allows(.seasonalAllYear) == false
        return Menu {
            ForEach(SeasonalSetting.choices, id: \.self) { choice in
                Button {
                    chooseSeasonal(choice)
                } label: {
                    Text(loc.localized(choice.labelKey))
                    if choice.forcedSeasonID != nil {
                        Text(loc.localized("settings.seasonal.choice.halloween.detail"))
                    }
                    if choice == selected {
                        Image(systemName: "checkmark")
                    } else if choice.forcedSeasonID != nil, forcedLocked {
                        Image(systemName: "lock.fill")
                    }
                }
            }
        } label: {
            iOSSettingsRow {
                SettingsRowAdaptiveLayout {
                    HStack {
                        iOSRowIcon(systemName: "calendar", color: themeManager.accent)
                        VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                            Text(loc.localized("settings.seasonal.toggle"))
                                .font(CinemaFont.dynamicLabel(.large))
                                .foregroundStyle(CinemaColor.onSurface)
                            Text(SeasonalSettingsText.catalogueSummary(loc: loc))
                                .font(CinemaFont.dynamicLabel(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                    }
                } control: {
                    HStack(spacing: 4) {
                        Text(loc.localized(selected.labelKey))
                            .font(CinemaFont.dynamicLabel(.large))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: CinemaScale.pt(11), weight: .semibold))
                            .foregroundStyle(CinemaColor.outlineVariant)
                    }
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .tint(themeManager.accent)
        .accessibilityLabel(loc.localized("settings.seasonal.toggle"))
        .accessibilityValue(loc.localized(selected.labelKey))
        .accessibilityHint(SeasonalSettingsText.catalogueSummary(loc: loc))
    }

    /// A refused Halloween changes nothing: the root shows the Pro sheet.
    func chooseSeasonal(_ choice: SeasonalSetting) {
        if choice.forcedSeasonID != nil, proAccess?.admit(.seasonalAllYear) == false { return }
        seasonal.setSetting(choice)
        Haptics.tap()
    }

    /// « Pendant « Nuit d'Halloween », la couleur du thème remplace la vôtre. »
    /// — visible while a season is on, invisible (space kept) otherwise, so
    /// the season switch never moves under the finger.
    var seasonAccentNote: some View {
        let theme = seasonal.activeTheme ?? SeasonalThemeCatalogue.all.first
        let name = theme.map { loc.localized($0.nameKey) } ?? ""
        return Text(loc.localized("settings.seasonal.accentNote", name))
            .opacity(seasonal.activeTheme == nil ? 0 : 1)
            .accessibilityHidden(seasonal.activeTheme == nil)
    }

    var selectedAccent: AccentOption {
        AccentOption(rawValue: themeManager.accentColorKey) ?? .green
    }

    var languagePicker: some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            ForEach(AppLanguage.supported, id: \.self) { code in
                languageButton(code, label: code.uppercased())
            }
        }
    }

    func languageButton(_ code: String, label: String) -> some View {
        let isSelected = loc.languageCode == code
        return Button {
            loc.languageCode = code
        } label: {
            Text(label)
                .font(.system(size: CinemaScale.pt(17), weight: .bold))
                .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurfaceVariant)
                .frame(width: 40, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: CinemaRadius.medium)
                        .fill(isSelected ? themeManager.accent : CinemaColor.surfaceContainerHigh)
                )
                // The pill stays 40 × 30; the tap target is the 44 pt minimum.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // « FR » read aloud is two letters, not a language.
        .accessibilityLabel(loc.localized(AppLanguage.nameKey(code)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    func accentDot(_ option: AccentOption) -> some View {
        let isSelected = option.rawValue == themeManager.accentColorKey

        Button {
            themeManager.accentColorKey = option.rawValue
        } label: {
            ZStack {
                if option == .rainbow {
                    RainbowAccentSwatch(diameter: 28)
                } else {
                    Circle()
                        .fill(option.color)
                        .frame(width: 28, height: 28)
                }

                if isSelected {
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: 28, height: 28)

                    Image(systemName: "checkmark")
                        .font(.system(size: CinemaScale.pt(13), weight: .bold))
                        .foregroundStyle(option == .rainbow ? .white : option.swatchCheckColor)
                        // The rainbow swatch sweeps every hue under the check: a shadow, not a colour.
                        .shadow(color: option == .rainbow ? .black.opacity(0.6) : .clear, radius: 1.5)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffectDisabled()
        // Nine « bouton » in a row said nothing: each swatch is its colour's
        // name, and the current one says so (audit 2026-09-22, U5).
        .accessibilityLabel(loc.localized(option.nameKey))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .scaleEffect(isSelected ? 1.1 : 1.0)
        .animation(motionEffects ? .spring(response: 0.25, dampingFraction: 0.7) : nil, value: isSelected)
    }
}
#endif
