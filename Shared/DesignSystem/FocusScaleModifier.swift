import SwiftUI

struct CinemaFocusModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            #if os(tvOS)
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .shadow(
                color: CinemaColor.surfaceTint.opacity(isFocused ? 0.08 : 0),
                radius: 40,
                x: 0, y: 20
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
