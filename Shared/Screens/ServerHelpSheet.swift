import SwiftUI
import CinemaxKit

/// Explains where to find a Jellyfin server URL — surfaced from the Server Setup screen's
/// "How do I find my server?" button. Static informational content; no network activity.
///
/// Chrome is platform-branched: iPhone/iPad use `NavigationStack` + toolbar (idiomatic sheet
/// pattern); tvOS uses a full-screen cover with a custom header + accent close button because
/// tvOS `.toolbar` on a modal clips the title and renders the trailing button as an empty pill.
struct ServerHelpSheet: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        tvOSChrome
        #else
        iOSChrome
        #endif
    }

    // MARK: - iOS/iPad chrome

    #if !os(tvOS)
    private var iOSChrome: some View {
        NavigationStack {
            ZStack {
                CinemaColor.surface.ignoresSafeArea()

                ScrollView {
                    contentBody
                        .padding(CinemaSpacing.spacing4)
                        .frame(maxWidth: 700, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle(loc.localized("server.help.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.localized("action.done")) { dismiss() }
                        .foregroundStyle(themeManager.accent)
                }
            }
        }
    }
    #endif

    // MARK: - tvOS chrome

    #if os(tvOS)
    private var tvOSChrome: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    contentBody
                        .padding(.horizontal, CinemaSpacing.spacing10)
                        .padding(.bottom, CinemaSpacing.spacing10)
                        .frame(maxWidth: 1400, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(loc.localized("server.help.title"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)

            Spacer(minLength: CinemaSpacing.spacing6)

            CinemaButton(
                title: loc.localized("action.done"),
                style: .accent
            ) {
                dismiss()
            }
            .frame(width: 240)
        }
        .padding(.horizontal, CinemaSpacing.spacing10)
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing5)
    }
    #endif

    // MARK: - Content (shared)

    private var contentBody: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            Text(loc.localized("server.help.intro"))
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            section(
                icon: "globe",
                title: loc.localized("server.help.format.title"),
                body: loc.localized("server.help.format.body"),
                example: "http://192.168.1.100:8096"
            )

            section(
                icon: "wifi",
                title: loc.localized("server.help.local.title"),
                body: loc.localized("server.help.local.body")
            )

            section(
                icon: "lock.shield",
                title: loc.localized("server.help.remote.title"),
                body: loc.localized("server.help.remote.body"),
                example: "https://jellyfin.example.com"
            )

            tip(loc.localized("server.help.tip"))
        }
    }

    @ViewBuilder
    private func section(icon: String, title: String, body: String, example: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            HStack(spacing: CinemaSpacing.spacing3) {
                ZStack {
                    Circle()
                        .fill(themeManager.accentContainer.opacity(0.25))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(themeManager.accent)
                }

                Text(title)
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurface)
            }

            Text(body)
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            if let example {
                Text(example)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(CinemaColor.onSurface)
                    .padding(.horizontal, CinemaSpacing.spacing3)
                    .padding(.vertical, CinemaSpacing.spacing2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: CinemaRadius.medium)
                            .fill(CinemaColor.surfaceContainerHigh)
                    )
            }
        }
        .padding(CinemaSpacing.spacing4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .fill(CinemaColor.surfaceContainerLow.opacity(0.5))
        )
    }

    @ViewBuilder
    private func tip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing2) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(Color.yellow)
                .padding(.top, 2)
            Text(message)
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CinemaSpacing.spacing3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CinemaRadius.medium)
                .fill(Color.yellow.opacity(0.12))
        )
    }
}
