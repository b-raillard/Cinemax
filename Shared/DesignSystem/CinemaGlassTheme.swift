import SwiftUI

// MARK: - Color Tokens

enum CinemaColor {
    // Surface hierarchy
    static let surface = Color(hex: 0x0E0E0E)
    static let surfaceContainerLowest = Color(hex: 0x000000)
    static let surfaceContainerLow = Color(hex: 0x131313)
    static let surfaceContainer = Color(hex: 0x191A1A)
    static let surfaceContainerHigh = Color(hex: 0x1F2020)
    static let surfaceContainerHighest = Color(hex: 0x252626)
    static let surfaceVariant = Color(hex: 0x252626)
    static let surfaceBright = Color(hex: 0x2C2C2C)

    // Text
    static let onSurface = Color(hex: 0xE7E5E4)
    static let onSurfaceVariant = Color(hex: 0xACABAA)
    static let onBackground = Color(hex: 0xE7E5E4)

    // Primary
    static let primary = Color(hex: 0xC6C6C7)
    static let primaryDim = Color(hex: 0xB8B9B9)
    static let primaryContainer = Color(hex: 0x454747)
    static let onPrimary = Color(hex: 0x3F4041)

    // Secondary
    static let secondary = Color(hex: 0x9D9E9E)
    static let secondaryContainer = Color(hex: 0x3A3C3C)

    // Tertiary (accent blue)
    static let tertiary = Color(hex: 0x679CFF)
    static let tertiaryContainer = Color(hex: 0x007AFF)
    static let tertiaryDim = Color(hex: 0x0070EB)
    static let onTertiary = Color(hex: 0x001F4A)

    // Outline
    static let outline = Color(hex: 0x767575)
    static let outlineVariant = Color(hex: 0x484848)

    // Error
    static let error = Color(hex: 0xEE7D77)
    static let errorContainer = Color(hex: 0x7F2927)
    static let onErrorContainer = Color(hex: 0xFF9993)

    // Surface tint
    static let surfaceTint = Color(hex: 0xC6C6C7)
}

// MARK: - Global UI Scale

/// Global UI text scale. Backed by UserDefaults key "uiScale" (set via ThemeManager.uiScale).
/// All CinemaFont methods and explicit CinemaScale.pt() calls read this at view-render time,
/// so bumping ThemeManager._accentRevision (which happens on uiScale write) re-renders
/// all views and they pick up the new factor automatically.
enum CinemaScale {
    /// Reads the persisted scale factor. Default 1.0 (= 100%).
    /// On tvOS a 1.4× base multiplier is applied on top, since base sizes
    /// are defined for iOS (~10 pt/m) but tvOS is viewed from ~3 m away.
    static var factor: CGFloat {
        let stored = UserDefaults.standard.object(forKey: "uiScale") as? Double ?? 1.0
        #if os(tvOS)
        return CGFloat(stored) * 1.4
        #else
        return CGFloat(stored)
        #endif
    }

    /// Returns a point size multiplied by the global scale factor.
    static func pt(_ size: CGFloat) -> CGFloat { (size * factor).rounded() }
}

// MARK: - Typography

enum CinemaFont {
    static func display(_ size: DisplaySize = .medium) -> Font {
        switch size {
        case .large: .system(size: CinemaScale.pt(56), weight: .heavy, design: .default)
        case .medium: .system(size: CinemaScale.pt(45), weight: .heavy, design: .default)
        case .small: .system(size: CinemaScale.pt(36), weight: .bold, design: .default)
        }
    }

    static func headline(_ size: HeadlineSize = .medium) -> Font {
        switch size {
        case .large: .system(size: CinemaScale.pt(32), weight: .bold, design: .default)
        case .medium: .system(size: CinemaScale.pt(28), weight: .bold, design: .default)
        case .small: .system(size: CinemaScale.pt(24), weight: .semibold, design: .default)
        }
    }

    static var body: Font { .system(size: CinemaScale.pt(17), weight: .regular) }
    static var bodyLarge: Font { .system(size: CinemaScale.pt(19), weight: .regular) }

    static func label(_ size: LabelSize = .medium) -> Font {
        switch size {
        case .large: .system(size: CinemaScale.pt(19), weight: .medium)
        case .medium: .system(size: CinemaScale.pt(16), weight: .medium)
        case .small: .system(size: CinemaScale.pt(14), weight: .medium)
        }
    }

    enum DisplaySize { case large, medium, small }
    enum HeadlineSize { case large, medium, small }
    enum LabelSize { case large, medium, small }
}

// MARK: - Spacing

enum CinemaSpacing {
    static let spacing1: CGFloat = 4
    static let spacing2: CGFloat = 11    // 0.7rem
    static let spacing3: CGFloat = 16
    static let spacing4: CGFloat = 22    // 1.4rem
    static let spacing5: CGFloat = 28
    static let spacing6: CGFloat = 32    // 2rem
    static let spacing8: CGFloat = 44
    static let spacing10: CGFloat = 56
    static let spacing20: CGFloat = 112  // 7rem — page margins
}

// MARK: - Corner Radius

enum CinemaRadius {
    static let small: CGFloat = 4
    static let medium: CGFloat = 8
    static let large: CGFloat = 16
    static let extraLarge: CGFloat = 24
    static let full: CGFloat = 9999
}

// MARK: - Gradients

enum CinemaGradient {
    static let primaryButton = LinearGradient(
        colors: [CinemaColor.primary, CinemaColor.primaryContainer],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let heroOverlay = LinearGradient(
        colors: [
            CinemaColor.surface.opacity(0.4),
            CinemaColor.surface
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Color Extension

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
