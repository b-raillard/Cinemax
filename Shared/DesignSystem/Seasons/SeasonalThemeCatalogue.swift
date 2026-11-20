import Foundation

/// Every season the app knows. DATA, not code — like `WhatsNewCatalogue`.
enum SeasonalThemeCatalogue {
    /// « Nuit d'Halloween » — the design canvas « Cinemax — Logo & Halloween ».
    /// Derived tokens (not on the canvas) are marked; their contrast is locked
    /// by `SeasonalThemePolicyTests`.
    static let halloween = SeasonalTheme(
        id: "halloween",
        nameKey: "season.halloween.name",
        window: SeasonWindow(start: MonthDay(month: 10, day: 1), end: MonthDay(month: 11, day: 2)),
        dark: SeasonPalette(
            surface: 0x0C0A10,                 // Nuit
            surfaceContainerLowest: 0x07060A,  // derived
            surfaceContainerLow: 0x15111C,     // Crypte
            surfaceContainer: 0x1D1726,        // Caveau
            surfaceContainerHigh: 0x262033,    // Tombe
            surfaceContainerHighest: 0x2E2740, // derived
            surfaceVariant: 0x2E2740,          // derived
            onSurface: 0xF1E9E0,               // Parchemin
            onSurfaceVariant: 0xB3A8B8,        // Cendre
            onSurfaceMuted: 0x9A90A2,          // derived
            outline: 0x7A6F84,                 // derived (strokes only)
            outlineVariant: 0x4A4058           // derived (strokes only)
        ),
        light: nil,
        accent: AccentOption.Palette(
            accentLight: 0xA84508, accentDark: 0xFF7A1A,     // Citrouille
            containerLight: 0xE06A1A, containerDark: 0xE06A1A,
            dimLight: 0x8A3806, dimDark: 0xCC5500,
            onAccentLight: 0xFFFFFF, onAccentDark: 0x1A0D05
        ),
        // Fraunces 1.000, static 72 pt optical size, Black Italic (OFL).
        titleFont: SeasonFont(postScriptName: "Fraunces72pt-BlackItalic", fileName: "Fraunces-BlackItalic.ttf"),
        ambiance: [.bats, .pumpkins, .focusGlow],
        row: SeasonRow(
            titleKey: "season.halloween.row",
            genreCandidates: ["Horror", "Horreur", "Épouvante-horreur", "Épouvante"],
            tagCandidates: ["halloween", "haunted house", "vampire", "zombie", "gothic"]
        ),
        backdrop: .nightSky
    )

    /// « Sapin de Noël » — the design canvas « JellyGlass — Thème de Noël »,
    /// board T10 (chosen 2026-11-20). Deep fir green, holly red; fir boughs on
    /// the heroes, snow. The window wraps the New Year, to Epiphany.
    static let christmas = SeasonalTheme(
        id: "christmas",
        nameKey: "season.christmas.name",
        window: SeasonWindow(start: MonthDay(month: 12, day: 1), end: MonthDay(month: 1, day: 6)),
        dark: SeasonPalette(
            surface: 0x07100C,                 // Sapin de nuit
            surfaceContainerLowest: 0x040A07,  // derived
            surfaceContainerLow: 0x0F1B15,
            surfaceContainer: 0x17281F,
            surfaceContainerHigh: 0x1F3529,
            surfaceContainerHighest: 0x284433, // derived
            surfaceVariant: 0x284433,          // derived
            onSurface: 0xF5EFE4,               // Lin
            onSurfaceVariant: 0xAEB9AE,
            onSurfaceMuted: 0x93A094,          // derived
            outline: 0x6F7D72,                 // derived (strokes only)
            outlineVariant: 0x3C4D42           // derived (strokes only)
        ),
        // Light mode gets its own ground (owner, on device, 2026-11-20: the
        // white page « ne va pas avec » the boughs and the garlands): linen.
        light: SeasonPalette(
            surface: 0xF3ECDD,                 // Lin
            surfaceContainerLowest: 0xFBF6EC,
            surfaceContainerLow: 0xECE4D2,
            surfaceContainer: 0xE5DCC8,
            surfaceContainerHigh: 0xDCD2BC,
            surfaceContainerHighest: 0xD2C7AF,
            surfaceVariant: 0xDCD2BC,
            onSurface: 0x1B2A22,               // Sapin de nuit
            onSurfaceVariant: 0x3F4B43,
            onSurfaceMuted: 0x47534A,
            outline: 0xA89E8A,                 // strokes only
            outlineVariant: 0xC9BEA9           // strokes only
        ),
        accent: AccentOption.Palette(
            accentLight: 0x9E1F18, accentDark: 0xFF8A7A,     // Houx
            containerLight: 0xC8392F, containerDark: 0xC8392F,
            dimLight: 0x8E1D17, dimDark: 0xE0574A,
            onAccentLight: 0xFFFFFF, onAccentDark: 0x2A0907
        ),
        titleFont: SeasonFont(postScriptName: "Fraunces72pt-BlackItalic", fileName: "Fraunces-BlackItalic.ttf"),
        ambiance: [.snow, .focusGlow],
        // « Noël en famille »: TMDb has no Christmas genre, so the row is the
        // keyword `christmas` (read on TMDb for 34 titles, 2026-11-20: 21 of
        // the 22 expected ones; `holiday` brings in Thanksgiving and Coco,
        // `christmas party` Eyes Wide Shut) narrowed to the family genres —
        // which also keeps Batman Returns and Terrifier out. Genre names in
        // the three metadata languages the app ships in.
        row: SeasonRow(
            titleKey: "season.christmas.row",
            genreCandidates: ["Family", "Familial", "Familie", "Animation", "Kids", "Enfants", "Kinder"],
            tagCandidates: ["christmas"],
            requiresBoth: true
        ),
        backdrop: nil,
        decor: .firBoughs,
        // « À demander pour Noël »: the same TMDb keyword, asked of Seerr
        // (measured on the bench, 2026-11-20: 198 films with the vote floor,
        // opening on Our Little Secret, That Christmas, Dear Santa).
        requestRow: SeasonRequestRow(
            titleKey: "season.christmas.requestRow",
            keywordId: 207_317,
            minimumVotes: 300,
            excludedGenreIds: [27]
        )
    )

    static let all: [SeasonalTheme] = [halloween, christmas]

    private static let byID: [String: SeasonalTheme] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func theme(id: String?) -> SeasonalTheme? {
        id.flatMap { byID[$0] }
    }
}
