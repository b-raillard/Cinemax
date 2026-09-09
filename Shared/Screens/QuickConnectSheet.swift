import SwiftUI

/// Quick Connect sheet: shows the six-character code the user approves from an
/// already-signed-in session (web dashboard or another app). While open, the
/// owning `LoginViewModel` polls the server; once approved it completes the
/// session and the whole login surface is replaced, tearing this down.
///
/// iOS presents it as a `.sheet`; tvOS as a `.fullScreenCover` wearing the one
/// chrome every tvOS modal shares (`WatchedHistoryScreen`): header row with the
/// title and an accent Cancel button, content below at the page margin, Menu
/// dismisses.
struct QuickConnectSheet: View {
    @Bindable var viewModel: LoginViewModel
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        iOSBody
        #endif
    }

    #if !os(tvOS)
    private var iOSBody: some View {
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

            contentColumn

            Spacer(minLength: 0)
        }
        .padding(CinemaSpacing.spacing6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CinemaColor.surface.ignoresSafeArea())
    }
    #endif

    #if os(tvOS)
    private var tvOSBody: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                tvHeader

                // The header carries the title, so the column keeps only the
                // glyph above the instructions.
                VStack(spacing: CinemaSpacing.spacing6) {
                    Image(systemName: "qrcode")
                        .font(.system(size: CinemaScale.pt(40)))
                        .foregroundStyle(themeManager.accent)

                    contentColumn
                }
                .frame(maxWidth: CinemaTVLayout.readingMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, CinemaTVLayout.pagePadding)
                .padding(.top, CinemaSpacing.spacing6)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onExitCommand { dismiss() }
    }

    private var tvHeader: some View {
        HStack(alignment: .center) {
            Text(loc.localized("quickConnect.title"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)

            Spacer(minLength: CinemaSpacing.spacing6)

            CinemaButton(
                title: loc.localized("action.cancel"),
                style: .accent
            ) {
                dismiss()
            }
            .frame(width: CinemaTVLayout.ctaWidth)
        }
        .padding(.horizontal, CinemaTVLayout.pagePadding)
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing5)
        // The header's button is the screen's only focusable — the column
        // below holds no control — so it must be its own focus section.
        .focusSection()
    }
    #endif

    // MARK: - Shared column

    /// Instructions, the code, and the waiting / error line — everything under
    /// the title, identical on both platforms.
    @ViewBuilder
    private var contentColumn: some View {
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
