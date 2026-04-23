import SwiftUI

/// Shared rainbow preview dot used by every accent picker. Kept as a reusable
/// component so the iOS + tvOS Settings pickers render identical visuals.
///
/// Consumed by the accent picker when rainbow is unlocked; see `AccentOption.rainbow`
/// for the actual animated accent behavior driven by `ThemeManager._rainbowHue`.
struct RainbowAccentSwatch: View {
    var diameter: CGFloat = 28

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    gradient: Gradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red]),
                    center: .center
                )
            )
            .frame(width: diameter, height: diameter)
    }
}
