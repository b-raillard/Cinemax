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

    /// « Givre » — the artifact « Noël JellyGlass » (theme Givre, chosen by the
    /// owner on 2026-11-20, replacing « Sapin de Noël »): a film watched
    /// through a frosted window while it snows outside. Midnight blue, ice
    /// white, engraved serif capitals; frost in the corners and on the heroes'
    /// edges, snow. The window wraps the New Year, to Epiphany.
    static let christmas = SeasonalTheme(
        id: "christmas",
        nameKey: "season.christmas.name",
        window: SeasonWindow(start: MonthDay(month: 12, day: 1), end: MonthDay(month: 1, day: 6)),
        dark: SeasonPalette(
            surface: 0x0A1220,                 // Nuit d'hiver
            surfaceContainerLowest: 0x060C16,
            surfaceContainerLow: 0x101B2C,
            surfaceContainer: 0x172437,
            surfaceContainerHigh: 0x1F2E45,
            surfaceContainerHighest: 0x283A55,
            surfaceVariant: 0x283A55,
            onSurface: 0xEEF4FB,               // Glace
            onSurfaceVariant: 0xB6C5D8,
            onSurfaceMuted: 0x97A8BE,
            outline: 0x6D7E96,                 // strokes only
            outlineVariant: 0x34455E           // strokes only
        ),
        // A frosty winter day: an ICE-BLUE ground, never white (owner,
        // 2026-11-20: « ne le laisse pas blanc »); the frost a whiter veil on it.
        light: SeasonPalette(
            surface: 0xD6E2F0,                 // Bleu glace
            surfaceContainerLowest: 0xE6EEF7,
            surfaceContainerLow: 0xCCD9EA,
            surfaceContainer: 0xC3D2E5,
            surfaceContainerHigh: 0xB9CADF,
            surfaceContainerHighest: 0xAEC1D9,
            surfaceVariant: 0xB9CADF,
            onSurface: 0x101E34,               // Encre de nuit
            onSurfaceVariant: 0x31415A,
            onSurfaceMuted: 0x3C4C65,
            outline: 0x8596AE,                 // strokes only
            outlineVariant: 0xA9B9CE           // strokes only
        ),
        // Ice white buttons with a navy label at night, navy ones by day.
        accent: AccentOption.Palette(
            accentLight: 0x1F3A60, accentDark: 0xCFE1F6,
            containerLight: 0x1F3A60, containerDark: 0xE6EFFA,
            dimLight: 0x182E4D, dimDark: 0xA9C6E8,
            onAccentLight: 0xFFFFFF, onAccentDark: 0x0F1D33
        ),
        titleFont: SeasonFont(
            postScriptName: "CormorantGaramond-Bold", fileName: "CormorantGaramond-Bold.ttf",
            uppercase: true, tracking: 0.08, sizeScale: 1.2
        ),
        ambiance: [.snow, .focusGlow],
        row: nil,
        backdrop: nil,
        decor: .frost
    )

    static let all: [SeasonalTheme] = [halloween, christmas]

    private static let byID: [String: SeasonalTheme] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func theme(id: String?) -> SeasonalTheme? {
        id.flatMap { byID[$0] }
    }
}
