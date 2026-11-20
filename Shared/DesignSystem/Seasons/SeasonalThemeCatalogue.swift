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
    /// through a frosted window while it snows outside. Night blue and frost
    /// blue, swapping with the mode; engraved serif capitals; frost in the corners and on the heroes'
    /// edges, snow. The window wraps the New Year, to Epiphany.
    static let christmas = SeasonalTheme(
        id: "christmas",
        nameKey: "season.christmas.name",
        window: SeasonWindow(start: MonthDay(month: 12, day: 1), end: MonthDay(month: 1, day: 6)),
        // TWO colours that swap with the mode (owner, 2026-11-20: « bleu clair
        // givré et bleu nuit … en alternant les couleurs »): Bleu nuit
        // #0B1A2E is the night ground and the day's ink and buttons; Bleu
        // givré #CFE2F5 is the day ground and the night's ink and buttons.
        // Every other tone is a step of one of the two (13.2:1 between them).
        dark: SeasonPalette(
            surface: 0x0B1A2E,                 // Bleu nuit
            surfaceContainerLowest: 0x07121F,
            surfaceContainerLow: 0x112238,
            surfaceContainer: 0x172B44,
            surfaceContainerHigh: 0x1E3552,
            surfaceContainerHighest: 0x274162,
            surfaceVariant: 0x274162,
            onSurface: 0xCFE2F5,               // Bleu givré
            onSurfaceVariant: 0xA9C2DD,
            onSurfaceMuted: 0x93ADCA,
            outline: 0x5F7896,                 // strokes only
            outlineVariant: 0x2E4664           // strokes only
        ),
        // Never a white page (owner, 2026-11-20, « ne le laisse pas blanc »).
        light: SeasonPalette(
            surface: 0xCFE2F5,                 // Bleu givré
            surfaceContainerLowest: 0xE3EFFA,
            surfaceContainerLow: 0xC4D9EF,
            surfaceContainer: 0xB9D1EA,
            surfaceContainerHigh: 0xAEC8E4,
            surfaceContainerHighest: 0xA2BFDD,
            surfaceVariant: 0xAEC8E4,
            onSurface: 0x0B1A2E,               // Bleu nuit
            onSurfaceVariant: 0x243A57,
            onSurfaceMuted: 0x30486A,
            outline: 0x7891B0,                 // strokes only
            outlineVariant: 0x9CB6D3           // strokes only
        ),
        // The buttons take the OTHER colour: frost on night, night on frost.
        accent: AccentOption.Palette(
            accentLight: 0x0B1A2E, accentDark: 0xCFE2F5,
            containerLight: 0x0B1A2E, containerDark: 0xCFE2F5,
            dimLight: 0x1B2F4C, dimDark: 0xA9C2DD,
            onAccentLight: 0xCFE2F5, onAccentDark: 0x0B1A2E,
            containerLabelLight: 0xCFE2F5, containerLabelDark: 0x0B1A2E
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
