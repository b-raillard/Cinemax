import SwiftUI

/// The first-run introduction: three pages, shown once in place of
/// `ServerSetupScreen`, and re-openable from Réglages → Serveur.
///
/// Every decision about WHO sees it, how the pages chain and what the tvOS Menu
/// button does lives in `OnboardingPolicy` — this file is the rendering only, so
/// the routing is locked by `OnboardingPolicyTests` rather than by reading
/// SwiftUI. Deliberately NOT a paged `TabView`: `PageTabViewStyle` does not
/// exist on tvOS, and a swipe is not an input there — so the pager is one
/// switched page plus explicit controls, identical on both platforms, with the
/// swipe added on iOS as a convenience on top.
struct OnboardingScreen: View {
    /// `true` when opened from Réglages rather than shown at first run. It
    /// changes exactly two things, both of them `OnboardingPolicy`'s business:
    /// what Menu does on the first page (dismiss vs suspend), and that finishing
    /// latches nothing — the flag is already set.
    let isReplay: Bool
    /// Called by « Passer » and by the last page's CTA. The host owns what that
    /// means: stamping `onboarding.seen` at first run, dismissing on a replay.
    let onFinish: () -> Void

    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEffects

    @State private var page: OnboardingPage = .server
    @State private var showServerHelp = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable { case primary, back, skip }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                pageBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        }
        // `OnboardingExit` answers with `nil` for the first page at first run,
        // and passing nil is the ONLY way to express « réduire l'app » — see the
        // tvOS Menu-button RULE.
        .tvExitCommand(exitAction)
        .serverHelpPresentation(isPresented: $showServerHelp)
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageBody: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            Image(systemName: symbol(for: page))
                .font(.system(size: CinemaScale.pt(iconSize), weight: .semibold))
                .foregroundStyle(themeManager.accent)
                .accessibilityHidden(true)

            Text(loc.localized("onboarding.\(key(for: page)).title"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)

            Text(loc.localized("onboarding.\(key(for: page)).body"))
                .font(CinemaFont.dynamicBody)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            if page == .server {
                // The issue asks for the discovery hint to reach the same help
                // the pre-auth screen offers — reusing `PreAuthChrome`'s link
                // rather than a second affordance that would drift from it.
                PreAuthHelperLink(
                    icon: "questionmark.circle",
                    title: loc.localized("server.help.title")
                ) { showServerHelp = true }
            }
        }
        .frame(maxWidth: proseWidth, alignment: .leading)
        .padding(.horizontal, pagePadding)
        .id(page)
        .transition(.opacity)
        .animation(motionEffects ? .easeInOut(duration: 0.25) : nil, value: page)
        #if os(iOS)
        // A swipe is the idiom a pager teaches on a phone; the buttons below
        // stay the accessible path and the only one on tvOS.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                value.translation.width < 0 ? advance() : goBack()
            }
        )
        #endif
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            dots
            HStack(spacing: CinemaSpacing.spacing4) {
                if page.previous != nil {
                    CinemaButton(title: loc.localized("onboarding.back"), style: .ghost) { goBack() }
                        .frame(width: ctaWidth)
                        .focused($focusedControl, equals: .back)
                }
                Spacer(minLength: CinemaSpacing.spacing4)
                if !page.isLast {
                    CinemaButton(title: loc.localized("onboarding.skip"), style: .ghost) { onFinish() }
                        .frame(width: ctaWidth)
                        .focused($focusedControl, equals: .skip)
                }
                CinemaButton(
                    title: loc.localized(page.isLast ? "onboarding.start" : "onboarding.next"),
                    style: .accent
                ) { advance() }
                .frame(width: ctaWidth)
                .focused($focusedControl, equals: .primary)
            }
        }
        .padding(.horizontal, pagePadding)
        .padding(.bottom, CinemaSpacing.spacing8)
        #if os(tvOS)
        .focusSection()
        #endif
        // The CTA is what the viewer is looking for on arrival; without this the
        // focus engine lands on whichever control happens to come first, which
        // on a page carrying « Précédent » is the one going backwards.
        .onAppear { focusedControl = .primary }
        .onChange(of: page) { focusedControl = .primary }
    }

    /// Page indicator. One accessibility element for the whole pager, so
    /// VoiceOver says « Page 2 sur 3 » once instead of reading three circles.
    private var dots: some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            ForEach(OnboardingPage.allCases) { candidate in
                Circle()
                    .fill(candidate == page ? themeManager.accent : CinemaColor.onSurfaceVariant.opacity(0.3))
                    .frame(width: CinemaScale.pt(8), height: CinemaScale.pt(8))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized("onboarding.page", page.rawValue + 1, OnboardingPage.allCases.count))
    }

    // MARK: - Actions

    private func advance() {
        guard let next = page.next else { onFinish(); return }
        page = next
    }

    private func goBack() {
        guard let previous = page.previous else { return }
        page = previous
    }

    /// `nil` restores the system default — suspending the app, which is what the
    /// pre-auth screens do when there is nothing to go back to.
    private var exitAction: (() -> Void)? {
        switch OnboardingExit.decide(page: page, isReplay: isReplay) {
        case .previousPage: { goBack() }
        case .dismiss: { onFinish() }
        case .systemDefault: nil
        }
    }

    // MARK: - Page content

    private func key(for page: OnboardingPage) -> String {
        switch page {
        case .server: "server"
        case .quickConnect: "quickConnect"
        case .personalize: "personalize"
        }
    }

    private func symbol(for page: OnboardingPage) -> String {
        switch page {
        case .server: "server.rack"
        case .quickConnect: "person.badge.key"
        case .personalize: "paintbrush"
        }
    }

    // MARK: - Metrics

    #if os(tvOS)
    private var pagePadding: CGFloat { CinemaTVLayout.pagePadding }
    private var proseWidth: CGFloat { CinemaTVLayout.readingMaxWidth }
    private var ctaWidth: CGFloat { CinemaTVLayout.ctaWidth }
    private var iconSize: CGFloat { 64 }
    #else
    private var pagePadding: CGFloat { CinemaSpacing.spacing6 }
    private var proseWidth: CGFloat { 520 }
    private var ctaWidth: CGFloat { 130 }
    private var iconSize: CGFloat { 44 }
    #endif
}

// MARK: - Platform-gated modifiers

private extension View {
    /// `.onExitCommand` is **unavailable on iOS**, so the Menu handling has to be
    /// gated rather than merely inert there. Passing `nil` on tvOS restores the
    /// system default — suspending the app — which is exactly what
    /// `OnboardingExit.systemDefault` means; see the tvOS Menu-button RULE.
    @ViewBuilder
    func tvExitCommand(_ action: (() -> Void)?) -> some View {
        #if os(tvOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

private extension View {
    /// `ServerHelpSheet` owns its own chrome per platform (iOS `NavigationStack`
    /// + toolbar, tvOS a full-screen cover with a custom header), so the only
    /// thing that differs here is the presentation itself — the same split
    /// `ServerSetupScreen` uses.
    @ViewBuilder
    func serverHelpPresentation(isPresented: Binding<Bool>) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented) { ServerHelpSheet() }
        #else
        sheet(isPresented: isPresented) { ServerHelpSheet() }
        #endif
    }
}
