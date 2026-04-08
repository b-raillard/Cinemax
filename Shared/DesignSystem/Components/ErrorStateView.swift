import SwiftUI

/// Standard error state: warning icon + message text + retry button.
struct ErrorStateView: View {
    let message: String
    let retryTitle: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: CinemaScale.pt(48)))
                .foregroundStyle(CinemaColor.error)
                .accessibilityHidden(true)
            Text(message)
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CinemaSpacing.spacing6)
            CinemaButton(title: retryTitle, style: .ghost) {
                onRetry()
            }
            .frame(width: 160)
        }
    }
}
