import SwiftUI
@preconcurrency import JellyfinAPI

struct LibrarySortFilterSheet: View {
    @Binding var sortFilter: LibrarySortFilterState
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
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
                    .padding(.horizontal, CinemaSpacing.spacing4)
                    .padding(.top, CinemaSpacing.spacing4)
                }
            }
            .navigationTitle(loc.localized("movies.sortFilter"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
                        .font(.system(size: 15, weight: .semibold))
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
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 15, weight: .medium))
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

            Button {
                sortFilter.showUnwatchedOnly.toggle()
            } label: {
                HStack {
                    Text(loc.localized("filter.unwatchedOnly"))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurface)
                    Spacer()
                    CinemaToggleIndicator(
                        isOn: sortFilter.showUnwatchedOnly,
                        accent: themeManager.accent
                    )
                }
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.vertical, CinemaSpacing.spacing3)
                .background(CinemaColor.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            }
            .buttonStyle(.plain)
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
            }

            FlowLayout(spacing: CinemaSpacing.spacing2) {
                ForEach(Self.decadeOptions, id: \.self) { decade in
                    decadeChip(decade)
                }
            }
        }
    }

    @ViewBuilder
    private func decadeChip(_ decade: Int) -> some View {
        let isSelected = sortFilter.selectedDecades.contains(decade)

        Button {
            if isSelected {
                sortFilter.selectedDecades.remove(decade)
            } else {
                sortFilter.selectedDecades.insert(decade)
            }
        } label: {
            Text(loc.localized("filter.decade", decade))
                .font(.system(size: 14, weight: .medium))
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

    // MARK: Genre Filter

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            HStack {
                sectionHeader(loc.localized("filter.byGenre"))
                Spacer()
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
            }

            FlowLayout(spacing: CinemaSpacing.spacing2) {
                ForEach(availableGenres, id: \.self) { genre in
                    genreChip(genre)
                }
            }
        }
    }

    @ViewBuilder
    private func genreChip(_ genre: String) -> some View {
        let isSelected = sortFilter.selectedGenres.contains(genre)

        Button {
            if isSelected {
                sortFilter.selectedGenres.remove(genre)
            } else {
                sortFilter.selectedGenres.insert(genre)
            }
        } label: {
            Text(genre)
                .font(.system(size: 14, weight: .medium))
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

    // MARK: Section Header

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(CinemaFont.label(.large))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .textCase(.uppercase)
            .tracking(0.8)
    }
}
