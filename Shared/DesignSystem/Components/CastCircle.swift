import SwiftUI

struct CastCircle: View {
    let name: String
    var role: String? = nil
    var imageURL: URL? = nil

    private let size: CGFloat = 80

    #if os(tvOS)
    // The card button style (`CinemaTVCardButtonStyle`) already scales +
    // brightens on focus, but its ring/halo companion (`cinemaFocus()`) draws a
    // rounded *rectangle* — wrong for a circular portrait. So the ring is drawn
    // here as a Circle, driven by the focus that propagates into the button
    // label (same mechanism `cinemaFocus()` relies on for poster cards).
    @Environment(\.isFocused) private var isFocused
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEnabled
    #endif

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            CinemaLazyImage(
                url: imageURL,
                fallbackIcon: "person.fill",
                fallbackBackground: CinemaColor.surfaceContainerHigh
            )
            .frame(width: size, height: size)
            .clipShape(Circle())
            #if os(tvOS)
            .overlay(
                Circle()
                    .strokeBorder(themeManager.accent.opacity(isFocused ? 1 : 0), lineWidth: 3)
            )
            .shadow(color: themeManager.accent.opacity(isFocused ? 0.4 : 0), radius: 14, x: 0, y: 6)
            .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: isFocused)
            #endif

            Text(name)
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurface)
                .lineLimit(1)

            if let role {
                Text(role)
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
            }
        }
        .frame(width: size + 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([name, role].compactMap { $0 }.joined(separator: ", "))
    }
}

#if DEBUG
#Preview("CastCircle — fallback and with role") {
    HStack(spacing: CinemaSpacing.spacing3) {
        CastCircle(name: "Jane Doe", role: "Director")
        CastCircle(name: "John Smith")
    }
    .padding(CinemaSpacing.spacing4)
    .background(CinemaColor.surfaceContainerLowest)
    .environment(ThemeManager())
}
#endif
