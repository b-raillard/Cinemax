#if os(iOS)
import SwiftUI

// MARK: - App icon page (iPhone + iPad, design « A », 2026-10-22)

/// Réglages → Apparence → « Icône de l'app ». A hero card shows the icon being
/// PREVIEWED; the sections Classique / Halloween / Couleurs list every
/// `AppIconCatalogue` choice. USER RULE: a tile only previews
/// (`AppIconPickerPolicy.tileTap`) — `setAlternateIconName` and its system
/// alert happen once, on the one button (`apply(previewing:…)`): sticky at the
/// bottom on iPhone, inside the hero on iPad (regular width). A standalone
/// `View` struct with its own environment (root RULE on pushed destinations).
struct AppIconPickerScreen: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    /// Optional like the Settings screens': a host without it leaves every icon open.
    @Environment(ProFeatureAccess.self) private var proAccess: ProFeatureAccess?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motionEffectsEnabled) private var motionEffects

    /// `UIApplication.alternateIconName` is not observable: a copy, read on
    /// appear and after each apply.
    @State private var current: String?
    /// The tile last touched; `nil` = the current icon.
    @State private var preview: AppIconChoice?
    @State private var applying = false

    private var tier: ProTier { proAccess?.currentTier() ?? .founder }
    private var isRegular: Bool { sizeClass == .regular }
    private var previewed: AppIconChoice {
        preview ?? AppIconCatalogue.choice(alternateName: current) ?? AppIconCatalogue.primary
    }
    private var state: AppIconPickerPolicy.PreviewState {
        AppIconPickerPolicy.previewState(previewed, current: current, tier: tier)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                hero
                if let count = AppIconPickerPolicy.proBannerCount(tier: tier) {
                    proBanner(count)
                }
                ForEach(AppIconCatalogue.sections) { section in
                    sectionView(section)
                }
            }
            .padding(.horizontal, isRegular ? CinemaSpacing.spacing8 : CinemaSpacing.spacing4)
            .padding(.top, CinemaSpacing.spacing2)
            .padding(.bottom, CinemaSpacing.spacing8)
        }
        .safeAreaInset(edge: .bottom) {
            if !isRegular {
                applyButton
                    .padding(.horizontal, CinemaSpacing.spacing4)
                    .padding(.top, CinemaSpacing.spacing3)
                    .padding(.bottom, CinemaSpacing.spacing2)
                    // Opaque under the button (a ghost « Icône actuelle » is
                    // translucent: the grid showed through), fading above it.
                    .background(CinemaColor.surface)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [CinemaColor.surface.opacity(0), CinemaColor.surface],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: CinemaSpacing.spacing6)
                            .offset(y: -CinemaSpacing.spacing6)
                            .allowsHitTesting(false)
                    }
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("settings.appIcon.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { current = AppIconSwitcher.currentName }
    }

    // MARK: Hero

    private var hero: some View {
        let side: CGFloat = isRegular ? 80 : 72
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: CinemaSpacing.spacing4) {
                heroIdentity(side: side)
                if isRegular {
                    applyButton.frame(width: 320)
                }
            }
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                heroIdentity(side: side)
                if isRegular { applyButton }
            }
        }
        .padding(CinemaSpacing.spacing4)
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }

    private func heroIdentity(side: CGFloat) -> some View {
        HStack(spacing: CinemaSpacing.spacing4) {
            AppIconThumbnail(choice: previewed, side: side)
            VStack(alignment: .leading, spacing: 3) {
                Text(loc.localized(state == .current ? "settings.appIcon.caption.current" : "settings.appIcon.caption.preview"))
                    .font(CinemaFont.dynamicLabel(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                Text(loc.localized(previewed.labelKey))
                    .font(CinemaFont.dynamicSystem(20, weight: .bold, relativeTo: .title3))
                    .foregroundStyle(CinemaColor.onSurface)
            }
            Spacer(minLength: 0)
            if state == .locked {
                ProBadge()
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Pro banner (free tier only)

    private func proBanner(_ count: Int) -> some View {
        Button {
            proAccess?.admit(.appIcons)
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                ProBadge()
                Text(loc.counted("settings.appIcon.proBanner", count))
                    .font(CinemaFont.dynamicLabel(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
            .background(themeManager.accent.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Sections

    private func sectionView(_ section: AppIconSection) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing3, alignment: .top),
                            count: isRegular ? 7 : 4)
        return VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            iOSSettingsSectionHeader(loc.localized(section.titleKey))
            LazyVGrid(columns: columns, alignment: .leading, spacing: CinemaSpacing.spacing4) {
                ForEach(section.choices) { choice in
                    tile(choice)
                }
            }
        }
    }

    private func tile(_ choice: AppIconChoice) -> some View {
        let isCurrent = choice.alternateName == current
        let isLocked = !isCurrent && AppIconPickerPolicy.isLocked(choice, tier: tier)
        let isPreviewed = choice == previewed
        let side: CGFloat = isRegular ? 76 : 62
        return Button {
            switch AppIconPickerPolicy.tileTap(choice) {
            case .preview(let shown):
                preview = shown
                Haptics.tap()
            }
        } label: {
            VStack(spacing: CinemaSpacing.spacing2) {
                AppIconThumbnail(choice: choice, side: side)
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: side * AppIconThumbnail.cornerRatio + 3, style: .continuous)
                            .strokeBorder(isPreviewed ? themeManager.accent : .clear, lineWidth: 2.5)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isLocked { tileBadge(systemName: "lock.fill", fill: CinemaColor.surfaceContainerHigh, ink: themeManager.accent) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent { tileBadge(systemName: "checkmark", fill: themeManager.accent, ink: themeManager.onAccent) }
                    }
                Text(loc.localized(choice.labelKey))
                    .font(CinemaFont.dynamicLabel(.small))
                    .foregroundStyle(isPreviewed ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized(choice.labelKey))
        .accessibilityValue([
            isCurrent ? loc.localized("settings.appIcon.caption.current") : nil,
            isLocked ? loc.localized("settings.appIcon.locked") : nil
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isPreviewed ? [.isButton, .isSelected] : .isButton)
    }

    private func tileBadge(systemName: String, fill: Color, ink: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: CinemaScale.pt(10), weight: .heavy))
            .foregroundStyle(ink)
            .frame(width: 22, height: 22)
            .background(Circle().fill(fill))
            .background(Circle().fill(CinemaColor.surface).padding(-2))
            .offset(x: 4, y: 0)
            .accessibilityHidden(true)
    }

    // MARK: The one button

    @ViewBuilder
    private var applyButton: some View {
        switch state {
        case .current:
            CinemaButton(title: loc.localized("settings.appIcon.caption.current"), style: .ghost) {}
                .disabled(true)
        case .available:
            CinemaButton(title: loc.localized("settings.appIcon.apply"), style: .accent, isLoading: applying) {
                applyPreview()
            }
            .disabled(applying)
        case .locked:
            CinemaButton(title: loc.localized("settings.appIcon.unlock"), style: .accent, icon: "lock.fill") {
                applyPreview()
            }
        }
    }

    private func applyPreview() {
        switch AppIconPickerPolicy.apply(previewing: previewed, current: current, tier: tier) {
        case .keep:
            return
        case .upsell:
            proAccess?.admit(.appIcons)
        case .apply(let name):
            applying = true
            Task {
                do {
                    try await AppIconSwitcher.set(name)
                } catch {
                    toasts.error(loc.localized("settings.appIcon.error"))
                }
                current = AppIconSwitcher.currentName
                preview = nil
                applying = false
            }
        }
    }
}

/// One icon's thumbnail under the system's mask (`recolor.py` draws the
/// same 22.37 % continuous corner).
struct AppIconThumbnail: View {
    static let cornerRatio: CGFloat = 0.2237
    let choice: AppIconChoice
    let side: CGFloat

    var body: some View {
        Image(choice.previewImage)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * Self.cornerRatio, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - The Apparence row that opens the page

/// « Icône de l'app » in Réglages → Apparence: the current icon, its name and
/// a chevron. The caller pushes `AppIconPickerScreen`.
struct AppIconSettingsRow: View {
    @Environment(LocalizationManager.self) private var loc
    let current: String?
    let action: () -> Void

    var body: some View {
        let choice = AppIconCatalogue.choice(alternateName: current) ?? AppIconCatalogue.primary
        Button(action: action) {
            iOSSettingsRow {
                HStack(spacing: CinemaSpacing.spacing3) {
                    AppIconThumbnail(choice: choice, side: 32)
                    Text(loc.localized("settings.appIcon.title"))
                        .font(CinemaFont.dynamicLabel(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    Spacer(minLength: CinemaSpacing.spacing2)
                    Text(loc.localized(choice.labelKey))
                        .font(CinemaFont.dynamicLabel(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                    Image(systemName: "chevron.right")
                        .font(.system(size: CinemaScale.pt(15), weight: .semibold))
                        .foregroundStyle(CinemaColor.outlineVariant)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized("settings.appIcon.title"))
        .accessibilityValue(loc.localized(choice.labelKey))
        .accessibilityAddTraits(.isButton)
    }
}
#endif
