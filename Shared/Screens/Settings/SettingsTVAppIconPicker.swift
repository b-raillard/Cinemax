import SwiftUI

#if os(tvOS)

// MARK: - tvOS App Icon (lot D, design « B », 2026-10-22)

extension SettingsScreen {
    /// Apparence → « Icône de l'app »: the current icon and its name; select
    /// opens the dedicated page (`tvAppIconPage`, a third level like an
    /// Interface sub-page). Hidden when the system has no alternate icons.
    @ViewBuilder
    var tvAppIconPicker: some View {
        if AppIconSwitcher.isSupported {
            tvAppIconEntryRow
        }
    }

    private var tvAppIconEntryRow: some View {
        let isFocused = focusedItem == .toggle("appIcon")
        let current = AppIconCatalogue.choice(alternateName: appIconName) ?? AppIconCatalogue.primary

        return Button {
            showsAppIconPage = true
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "app.badge")
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 24)

                Text(loc.localized("settings.appIcon.title"))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)

                Spacer()

                TVAppIconThumbnail(choice: current, width: 80)
                Text(loc.localized(current.labelKey))
                    .font(.system(size: CinemaScale.pt(20), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                Image(systemName: "chevron.right")
                    .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing2)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, animated: motionEffects, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized("settings.appIcon.title"))
        .accessibilityValue(loc.localized(current.labelKey))
        .focused($focusedItem, equals: .toggle("appIcon"))
        .onAppear { appIconName = AppIconSwitcher.currentName }
    }

    // MARK: The page

    /// Design B: a big preview of the FOCUSED icon on the left (name, family,
    /// status), the grid on the right (Éditions, Couleurs; 5 columns, card
    /// focus). Focus previews, select applies (`AppIconPickerPolicy`): one
    /// system alert per change, the Pro sheet on a locked icon.
    var tvAppIconPage: some View {
        let tier = proAccess?.currentTier() ?? .founder
        let focusedChoice: AppIconChoice? = {
            if case .appIcon(let id) = focusedItem {
                return AppIconCatalogue.choices.first { $0.id == id }
            }
            return nil
        }()
        let previewed = focusedChoice ?? AppIconCatalogue.choice(alternateName: appIconName) ?? AppIconCatalogue.primary

        return VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            tvAppIconBackButton

            HStack(alignment: .top, spacing: CinemaSpacing.spacing10) {
                tvAppIconPreview(previewed, tier: tier)
                    .frame(width: 560)

                VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    ForEach(AppIconCatalogue.tvSections) { section in
                        VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                            Text(loc.localized(section.titleKey).uppercased())
                                .font(CinemaFont.label(.large))
                                .tracking(1.2)
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing6), count: 5),
                                alignment: .leading,
                                spacing: CinemaSpacing.spacing6
                            ) {
                                ForEach(section.choices) { choice in
                                    tvAppIconTile(choice, tier: tier)
                                }
                            }
                        }
                    }
                }
            }
            // The preview column holds nothing focusable, and the grid sits to
            // the right of AND below the back button, out of both of its
            // straight lines: without one section spanning the whole row, Down
            // and Right from « ‹ Icône de l'app » found nothing and focus was
            // stuck on it (simulator, 2026-10-22).
            .focusSection()
        }
        .padding(.horizontal, CinemaSpacing.spacing20)
        .padding(.vertical, CinemaSpacing.spacing8)
        .onAppear { appIconName = AppIconSwitcher.currentName }
    }

    private var tvAppIconBackButton: some View {
        let backFocused = focusedItem == .back
        return Button {
            showsAppIconPage = false
        } label: {
            HStack(spacing: CinemaSpacing.spacing2) {
                Image(systemName: "chevron.left")
                    .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                Text(loc.localized("settings.appIcon.title"))
                    .font(CinemaFont.headline(.medium))
            }
            .foregroundStyle(backFocused ? themeManager.accent : CinemaColor.onSurface)
            // Row-level focus, bleeding outward — same as the other detail pages.
            .brightness(backFocused ? CinemaTVFocus.rowBrightness : 0)
            .overlay {
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(
                        themeManager.accent.opacity(backFocused ? CinemaTVFocus.strokeOpacity : 0),
                        lineWidth: CinemaTVFocus.strokeWidth
                    )
                    .padding(.horizontal, -CinemaSpacing.spacing3)
                    .padding(.vertical, -CinemaSpacing.spacing2)
            }
            .animation(motionEffects ? .easeOut(duration: CinemaTVFocus.rowDuration) : nil, value: backFocused)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .back)
    }

    private func tvAppIconPreview(_ choice: AppIconChoice, tier: ProTier) -> some View {
        let state = AppIconPickerPolicy.previewState(choice, current: appIconName, tier: tier)
        return VStack(spacing: CinemaSpacing.spacing5) {
            TVAppIconThumbnail(choice: choice, width: 480)
                .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 24)
            VStack(spacing: CinemaSpacing.spacing2) {
                Text(loc.localized(choice.labelKey))
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Text(loc.localized(choice.family.captionKey))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            HStack(spacing: CinemaSpacing.spacing2) {
                if state == .locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: CinemaScale.pt(16), weight: .bold))
                }
                Text(loc.localized(Self.tvAppIconStatusKey(state)))
                    .font(CinemaFont.label(.large))
            }
            .foregroundStyle(state == .available ? CinemaColor.onSurfaceVariant : themeManager.accent)
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing2)
            .background(Capsule().fill(state == .available ? CinemaColor.surfaceContainerHigh : themeManager.accent.opacity(0.18)))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    static func tvAppIconStatusKey(_ state: AppIconPickerPolicy.PreviewState) -> String {
        switch state {
        case .current: "settings.appIcon.caption.current"
        case .locked: "settings.appIcon.locked"
        case .available: "settings.appIcon.status.available"
        }
    }

    private func tvAppIconTile(_ choice: AppIconChoice, tier: ProTier) -> some View {
        let isCurrent = choice.alternateName == appIconName
        let isLocked = !isCurrent && AppIconPickerPolicy.isLocked(choice, tier: tier)
        return Button {
            tvApplyAppIcon(choice, tier: tier)
        } label: {
            TVAppIconThumbnail(choice: choice, width: nil)
                .overlay(alignment: .topTrailing) {
                    if isLocked { tvTileBadge("lock.fill", fill: CinemaColor.surfaceContainerHigh, ink: themeManager.accent) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent { tvTileBadge("checkmark", fill: themeManager.accent, ink: themeManager.onAccent) }
                }
                .cinemaFocus()
        }
        .buttonStyle(CinemaTVCardButtonStyle())
        .focused($focusedItem, equals: .appIcon(choice.id))
        .accessibilityLabel(loc.localized(choice.labelKey))
        .accessibilityValue([
            isCurrent ? loc.localized("settings.appIcon.caption.current") : nil,
            isLocked ? loc.localized("settings.appIcon.locked") : nil
        ].compactMap { $0 }.joined(separator: ", "))
    }

    private func tvTileBadge(_ systemName: String, fill: Color, ink: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: CinemaScale.pt(14), weight: .heavy))
            .foregroundStyle(ink)
            .frame(width: 36, height: 36)
            .background(Circle().fill(fill))
            .offset(x: 8, y: 0)
            .accessibilityHidden(true)
    }

    /// Select on a focused tile: the current one does nothing, a locked one
    /// raises the Pro sheet (nothing switches), any other applies — ONE system
    /// alert per change.
    func tvApplyAppIcon(_ choice: AppIconChoice, tier: ProTier) {
        switch AppIconPickerPolicy.apply(previewing: choice, current: appIconName, tier: tier) {
        case .keep:
            return
        case .upsell:
            proAccess?.admit(.appIcons)
        case .apply(let name):
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
}

/// An Apple TV icon thumbnail: the 400 × 240 back + front composite of
/// `recolor.py --alternates`, at the system's 5:3. `width == nil` fills the
/// grid column.
struct TVAppIconThumbnail: View {
    let choice: AppIconChoice
    let width: CGFloat?

    var body: some View {
        Image(choice.previewImage)
            .resizable()
            .aspectRatio(5 / 3, contentMode: .fit)
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large, style: .continuous))
            .accessibilityHidden(true)
    }
}

#endif
