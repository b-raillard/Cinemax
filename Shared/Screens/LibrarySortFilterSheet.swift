import SwiftUI
@preconcurrency import JellyfinAPI

struct LibrarySortFilterSheet: View {
    @Binding var sortFilter: LibrarySortFilterState
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.motionEffectsEnabled) private var motionEffects
    let onApply: () -> Void
    var availableGenres: [String] = []

    private var sortOptions: [(label: String, value: ItemSortBy)] {
        [
            (loc.localized("sort.dateAdded"), .dateCreated),
            (loc.localized("sort.name"), .sortName),
            (loc.localized("sort.releaseYear"), .productionYear),
            (loc.localized("sort.rating"), .communityRating),
            (loc.localized("sort.runtime"), .runtime)
        ]
    }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        iOSBody
        #endif
    }

    // MARK: iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            ZStack {
                CinemaColor.surface.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                        sortSection
                        sortOrderSection
                        unwatchedSection
                        decadeSection
                        if !availableGenres.isEmpty {
                            genreSection
                        }
                        Spacer(minLength: 80)
                    }
                    .padding(.horizontal, sheetHorizontalPadding)
                    .padding(.top, CinemaSpacing.spacing4)
                }
            }
            .navigationTitle(loc.localized("movies.sortFilter"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.localized("action.apply")) {
                        onApply()
                        dismiss()
                    }
                    .font(.system(size: CinemaScale.pt(17), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.reset")) {
                        sortFilter = LibrarySortFilterState()
                        onApply()
                        dismiss()
                    }
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
    }
    #endif

    // MARK: tvOS Body
    //
    // tvOS sheets render full-screen, but `NavigationStack` toolbar items
    // come out as the broken white pills shown in the bug report. We bypass
    // that here: explicit title at the top, scrollable filter sections in
    // the middle, sticky footer with `CinemaButton` Apply (.accent) + Reset
    // (.ghost) — same look as every other admin/save screen. Dismiss via
    // the Menu remote button (default sheet behavior).

    #if os(tvOS)
    private var tvBody: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Title row
                HStack {
                    Text(loc.localized("movies.sortFilter"))
                        .font(CinemaFont.headline(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    Spacer()
                }
                .padding(.horizontal, sheetHorizontalPadding)
                .padding(.top, CinemaSpacing.spacing8)
                .padding(.bottom, CinemaSpacing.spacing4)

                // Filter sections
                ScrollView {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                        unwatchedSection
                        decadeSection
                        if !availableGenres.isEmpty {
                            genreSection
                        }
                        Spacer(minLength: CinemaSpacing.spacing6)
                    }
                    .padding(.horizontal, sheetHorizontalPadding)
                    .padding(.top, CinemaSpacing.spacing2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollClipDisabled()

                // Footer actions — same pattern as AdminFormScreen / DestructiveConfirmSheet:
                // primary accent on the right, ghost reset on the left, both `CinemaButton`.
                HStack(spacing: CinemaSpacing.spacing4) {
                    CinemaButton(title: loc.localized("action.reset"), style: .ghost, icon: "arrow.counterclockwise") {
                        sortFilter = LibrarySortFilterState()
                        onApply()
                        dismiss()
                    }
                    .frame(maxWidth: 360)

                    CinemaButton(title: loc.localized("action.apply"), style: .accent, icon: "checkmark") {
                        onApply()
                        dismiss()
                    }
                    .frame(maxWidth: 360)
                }
                .padding(.horizontal, sheetHorizontalPadding)
                .padding(.vertical, CinemaSpacing.spacing5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    #endif

    // MARK: Sort By

    private var sortSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            sectionHeader(loc.localized("sort.by"))

            VStack(spacing: 0) {
                ForEach(sortOptions, id: \.value.rawValue) { option in
                    sortRow(label: option.label, value: option.value)
                }
            }
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        }
    }

    @ViewBuilder
    private func sortRow(label: String, value: ItemSortBy) -> some View {
        let isSelected = sortFilter.sortBy == value

        Button {
            sortFilter.sortBy = value
        } label: {
            HStack {
                Text(label)
                    .font(CinemaFont.body)
                    .foregroundStyle(isSelected ? themeManager.accent : CinemaColor.onSurface)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: CinemaScale.pt(15), weight: .semibold))
                        .foregroundStyle(themeManager.accent)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
            .background(
                isSelected
                    ? themeManager.accent.opacity(0.08)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)

        if value != sortOptions.last?.value {
            Divider()
                .background(CinemaColor.outlineVariant)
                .padding(.leading, CinemaSpacing.spacing4)
        }
    }

    // MARK: Sort Order

    private var sortOrderSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            sectionHeader(loc.localized("sort.order"))

            HStack(spacing: CinemaSpacing.spacing3) {
                orderChip(label: loc.localized("sort.ascending"), icon: "arrow.up", isAscending: true)
                orderChip(label: loc.localized("sort.descending"), icon: "arrow.down", isAscending: false)
            }
        }
    }

    @ViewBuilder
    private func orderChip(label: String, icon: String, isAscending: Bool) -> some View {
        let isSelected = sortFilter.sortAscending == isAscending

        Button {
            sortFilter.sortAscending = isAscending
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: CinemaScale.pt(13), weight: .semibold))
                Text(label)
                    .font(.system(size: CinemaScale.pt(15), weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : CinemaColor.onSurfaceVariant)
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.vertical, CinemaSpacing.spacing2)
            .background(
                isSelected
                    ? themeManager.accentContainer
                    : CinemaColor.surfaceContainerHigh
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Watch Status

    private var unwatchedSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            sectionHeader(loc.localized("filter.watchStatus"))

            let row = Button {
                sortFilter.showUnwatchedOnly.toggle()
            } label: {
                HStack {
                    Text(loc.localized("filter.unwatchedOnly"))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurface)
                    Spacer()
                    CinemaToggleIndicator(
                        isOn: sortFilter.showUnwatchedOnly,
                        accent: themeManager.accent,
                        animated: motionEffects
                    )
                }
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.vertical, CinemaSpacing.spacing3)
                .background(CinemaColor.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            }

            #if os(tvOS)
            row.buttonStyle(TVFilterRowButtonStyle(accent: themeManager.accent))
                .focusEffectDisabled()
                .hoverEffectDisabled()
            #else
            row.buttonStyle(.plain)
            #endif
        }
    }

    // MARK: Decade Filter

    /// Decades offered in the UI. Starting years, most-recent-first.
    private static let decadeOptions: [Int] = [2020, 2010, 2000, 1990, 1980, 1970, 1960, 1950]

    private var decadeSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            HStack {
                sectionHeader(loc.localized("filter.byDecade"))
                Spacer()
                #if !os(tvOS)
                // iOS keeps the top-right Clear because it's tappable. On tvOS
                // the same button is unreachable via remote (right-arrow from
                // the last chip never lands on it), so it lives inline as a
                // trailing chip in the FlowLayout below.
                if !sortFilter.selectedDecades.isEmpty {
                    Button {
                        sortFilter.selectedDecades = []
                    } label: {
                        Text(loc.localized("action.clear"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(themeManager.accent)
                    }
                    .buttonStyle(.plain)
                }
                #endif
            }

            FlowLayout(spacing: CinemaSpacing.spacing2) {
                ForEach(Self.decadeOptions, id: \.self) { decade in
                    decadeChip(decade)
                }
                #if os(tvOS)
                if !sortFilter.selectedDecades.isEmpty {
                    clearChip { sortFilter.selectedDecades = [] }
                }
                #endif
            }
        }
    }

    @ViewBuilder
    private func decadeChip(_ decade: Int) -> some View {
        let isSelected = sortFilter.selectedDecades.contains(decade)

        let button = Button {
            if isSelected {
                sortFilter.selectedDecades.remove(decade)
            } else {
                sortFilter.selectedDecades.insert(decade)
            }
        } label: {
            Text(loc.localized("filter.decade", decade))
                .font(.system(size: chipFontSize, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurface)
                .padding(.horizontal, chipHorizontalPadding)
                .padding(.vertical, chipVerticalPadding)
                .background(
                    isSelected
                        ? themeManager.accentContainer
                        : CinemaColor.surfaceContainerHigh
                )
                .clipShape(Capsule())
        }

        #if os(tvOS)
        button
            .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
            .focusEffectDisabled()
            .hoverEffectDisabled()
        #else
        button.buttonStyle(.plain)
        #endif
    }

    // MARK: Genre Filter

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            HStack {
                sectionHeader(loc.localized("filter.byGenre"))
                Spacer()
                #if !os(tvOS)
                if !sortFilter.selectedGenres.isEmpty {
                    Button {
                        sortFilter.selectedGenres = []
                    } label: {
                        Text(loc.localized("action.clear"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(themeManager.accent)
                    }
                    .buttonStyle(.plain)
                }
                #endif
            }

            FlowLayout(spacing: CinemaSpacing.spacing2) {
                ForEach(availableGenres, id: \.self) { genre in
                    genreChip(genre)
                }
                #if os(tvOS)
                if !sortFilter.selectedGenres.isEmpty {
                    clearChip { sortFilter.selectedGenres = [] }
                }
                #endif
            }
        }
    }

    @ViewBuilder
    private func genreChip(_ genre: String) -> some View {
        let isSelected = sortFilter.selectedGenres.contains(genre)

        let button = Button {
            if isSelected {
                sortFilter.selectedGenres.remove(genre)
            } else {
                sortFilter.selectedGenres.insert(genre)
            }
        } label: {
            Text(genre)
                .font(.system(size: chipFontSize, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurface)
                .padding(.horizontal, chipHorizontalPadding)
                .padding(.vertical, chipVerticalPadding)
                .background(
                    isSelected
                        ? themeManager.accentContainer
                        : CinemaColor.surfaceContainerHigh
                )
                .clipShape(Capsule())
        }

        #if os(tvOS)
        button
            .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
            .focusEffectDisabled()
            .hoverEffectDisabled()
        #else
        button.buttonStyle(.plain)
        #endif
    }

    // MARK: Clear Chip (tvOS)
    //
    // Trailing chip in the FlowLayout that resets the section's selection.
    // Living inside the flow makes it remote-reachable: right-arrow from the
    // last chip lands here. Visually distinct from filter chips: ghost outline,
    // accent foreground, with an x-circle icon to read as a destructive action.

    #if os(tvOS)
    @ViewBuilder
    private func clearChip(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: chipFontSize - 2, weight: .semibold))
                Text(loc.localized("action.clear"))
                    .font(.system(size: chipFontSize, weight: .semibold))
            }
            .foregroundStyle(themeManager.accent)
            .padding(.horizontal, chipHorizontalPadding)
            .padding(.vertical, chipVerticalPadding)
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(Capsule())
        }
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
    }
    #endif

    // MARK: Section Header

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(CinemaFont.label(.large))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    /// tvOS sheets are full-screen overlays — bumping horizontal padding keeps
    /// the chip flow readable on a 1080p viewport.
    private var sheetHorizontalPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        CinemaSpacing.spacing4
        #endif
    }

    private var chipFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(18)
        #else
        14
        #endif
    }

    private var chipHorizontalPadding: CGFloat {
        #if os(tvOS)
        18
        #else
        CinemaSpacing.spacing3
        #endif
    }

    private var chipVerticalPadding: CGFloat {
        #if os(tvOS)
        10
        #else
        CinemaSpacing.spacing2
        #endif
    }
}
