import SwiftUI

/// Quick Connect sheet: shows the six-character code the user approves from an
/// already-signed-in session (web dashboard or another app). While open, the
/// owning `LoginViewModel` polls the server; once approved it completes the
/// session and the whole login surface is replaced, tearing this down.
struct QuickConnectSheet: View {
    @Bindable var viewModel: LoginViewModel
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing6) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: CinemaScale.pt(14), weight: .bold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(themeManager.accentContainer)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.localized("action.cancel"))
            }

            Image(systemName: "qrcode")
                .font(.system(size: CinemaScale.pt(40)))
                .foregroundStyle(themeManager.accent)

            Text(loc.localized("quickConnect.title"))
                .font(.system(size: CinemaScale.pt(24), weight: .black))
                .foregroundStyle(CinemaColor.onSurface)

            Text(loc.localized("quickConnect.instructions"))
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            codeBlock

            if let error = viewModel.quickConnectError {
                Text(error)
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.error)
                    .multilineTextAlignment(.center)
            } else {
                HStack(spacing: CinemaSpacing.spacing2) {
                    ProgressView()
                    Text(loc.localized("quickConnect.waiting"))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(CinemaSpacing.spacing6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CinemaColor.surface.ignoresSafeArea())
    }

    @ViewBuilder
    private var codeBlock: some View {
        if let code = viewModel.quickConnectCode {
            Text(code)
                .font(.system(size: CinemaScale.pt(40), weight: .heavy, design: .monospaced))
                .tracking(8)
                .foregroundStyle(CinemaColor.onSurface)
                .padding(.vertical, CinemaSpacing.spacing4)
                .padding(.horizontal, CinemaSpacing.spacing8)
                .glassPanel(cornerRadius: CinemaRadius.large)
                .accessibilityLabel(code.map { String($0) }.joined(separator: " "))
        } else {
            ProgressView()
                .padding(.vertical, CinemaSpacing.spacing6)
        }
    }
}
