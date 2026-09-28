import Foundation

/// Every season the app knows. DATA, not code — like `WhatsNewCatalogue`.
enum SeasonalThemeCatalogue {
    /// « Nuit d'Halloween » — the design canvas « Cinemax — Logo & Halloween ».
    /// Derived tokens (not on the canvas) are marked; their contrast is locked
    /// by `SeasonalThemePolicyTests`.
    static let halloween = SeasonalTheme(
        id: "halloween",
        nameKey: "season.halloween.name",
        window: SeasonWindow(start: MonthDay(month: 10, day: 15), end: MonthDay(month: 11, day: 2)),
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
        ambiance: [.mist, .bats, .pumpkins, .focusGlow],
        row: SeasonRow(
            titleKey: "season.halloween.row",
            genreCandidates: ["Horror", "Horreur", "Épouvante-horreur", "Épouvante"]
        )
    )

    static let all: [SeasonalTheme] = [halloween]

    private static let byID: [String: SeasonalTheme] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func theme(id: String?) -> SeasonalTheme? {
        id.flatMap { byID[$0] }
    }
}
