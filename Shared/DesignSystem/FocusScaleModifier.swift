import SwiftUI

struct CinemaFocusModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(ThemeManager.self) private var themeManager

    func body(content: Content) -> some View {
        content
            #if os(tvOS)
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(
                        themeManager.accent.opacity(isFocused ? 0.8 : 0),
                        lineWidth: 2
                    )
            )
            .shadow(
                color: CinemaColor.surfaceTint.opacity(isFocused ? 0.12 : 0),
                radius: 24,
                x: 0, y: 12
            )
            .animation(.easeInOut(duration: 0.2), value: isFocused)
            #endif
    }
}

extension View {
    func cinemaFocus() -> some View {
        modifier(CinemaFocusModifier())
    }
}
