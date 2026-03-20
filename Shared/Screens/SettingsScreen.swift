import SwiftUI

struct SettingsScreen: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            VStack(spacing: CinemaSpacing.spacing6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 48))
                    .foregroundStyle(CinemaColor.outlineVariant)
                Text("Settings")
                    .font(CinemaFont.headline(.medium))
                    .foregroundStyle(CinemaColor.onSurface)
                Text("Coming in Phase 5")
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)

                CinemaButton(title: "Sign Out", style: .ghost) {
                    appState.logout()
                }
                .frame(maxWidth: 200)
            }
        }
        .navigationTitle("Settings")
    }
}
