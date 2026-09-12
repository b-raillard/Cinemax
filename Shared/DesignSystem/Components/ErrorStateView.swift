import SwiftUI

/// Standard error state: warning icon (or a themed illustration) + message text
/// + retry button.
struct ErrorStateView: View {
    let message: String
    let retryTitle: String
    /// Optional `CinemaIllustration` drawn in place of the warning triangle —
    /// `.offline` where the message is explicitly "can't reach the server".
    /// `nil` keeps the triangle.
    var illustration: CinemaIllustration? = nil
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing3) {
            if let illustration {
                CinemaIllustrationView(kind: illustration)
                    .padding(.bottom, CinemaSpacing.spacing1)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: CinemaScale.pt(48)))
                    .foregroundStyle(CinemaColor.error)
                    .accessibilityHidden(true)
            }
            Text(message)
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CinemaSpacing.spacing6)
            CinemaButton(title: retryTitle, style: .ghost) {
                onRetry()
            }
            .frame(width: retryWidth)
        }
    }

    /// Same reasoning as `EmptyStateView.actionWidth`.
    private var retryWidth: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.ctaWidth
        #else
        160
        #endif
    }
}

#if DEBUG
#Preview("ErrorStateView") {
    ErrorStateView(
        message: "Couldn't reach the server. Check your connection and try again.",
        retryTitle: "Retry"
    ) {}
    .frame(maxWidth: 480)
    .padding(CinemaSpacing.spacing10)
    .background(CinemaColor.surfaceContainerLowest)
    .environment(ThemeManager())
}
#endif
