import SwiftUI

/// « Quoi de neuf » — one page per new feature, shown once on the first launch
/// of a version and replayable from Réglages.
///
/// **Deliberately the same pager as `OnboardingScreen`, not a second one**: one
/// switched page plus explicit controls on both platforms, with the iOS swipe
/// added on top as a convenience. `PageTabViewStyle` does not exist on tvOS and
/// a swipe is not an input there, so a `TabView` pager could never serve both —
/// and the app already answered this question once. Which pages appear is
/// `WhatsNewPolicy`'s business, locked by its own tests; this file renders.
///
/// **iOS presents it as a sheet, tvOS as a full-screen cover**
/// (`whatsNewPresentation`): on a phone a full-screen page read as a place the
/// user had been sent to rather than a note they can close, so iOS carries the
/// same top-trailing close button as the app's other sheets — which is also why
/// « Passer » is tvOS-only (two controls doing the same thing, one of them in
/// the footer's already-tight row). A tvOS `.sheet` renders cramped, and Menu is
/// its close.
struct WhatsNewScreen: View {
    let pages: [WhatsNewPage]
    /// Called by the close button / « Passer » and by the last page's CTA. The
    /// host owns what that means: stamping the installed version at launch,
    /// dismissing on a replay.
    let onFinish: () -> Void

    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEffects

    @State private var index = 0
    @FocusState private var focusedControl: Control?
    #if os(iOS)
    /// Height of the scrolling page area, so a short page can be centred in it
    /// while a long one (large Dynamic Type) still scrolls.
    @State private var pageViewportHeight: CGFloat = 0
    #endif

    private enum Control: Hashable { case primary, back, skip }

    private var page: WhatsNewPage? {
        pages.indices.contains(index) ? pages[index] : pages.first
    }

    private var isLast: Bool { index >= pages.count - 1 }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                #if os(iOS)
                header
                #endif
                pageBody
                footer
            }
        }
        #if os(tvOS)
        // Unlike the onboarding's, this screen is ALWAYS dismissible — it is
        // never the only thing between the user and their server — so Menu
        // needs no `nil` branch and no shared helper: back one page, or out.
        .onExitCommand { goBack(orFinish: true) }
        #else
        .presentationDragIndicator(.visible)
        #endif
    }

    // MARK: - Header (iOS)

    #if os(iOS)
    private var header: some View {
        HStack(alignment: .center) {
            Text(loc.localized("settings.whatsNew"))
                .font(.system(size: CinemaScale.pt(17), weight: .bold))
                .foregroundStyle(CinemaColor.onSurface)

            Spacer(minLength: CinemaSpacing.spacing4)

            Button { onFinish() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: CinemaScale.pt(14), weight: .bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(themeManager.accentContainer)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.localized("action.done"))
        }
        .padding(.horizontal, pagePadding)
        .padding(.top, CinemaSpacing.spacing5)
    }
    #endif

    // MARK: - Page

    @ViewBuilder
    private var pageBody: some View {
        #if os(tvOS)
        pageContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        ScrollView {
            pageContent
                .padding(.vertical, CinemaSpacing.spacing4)
                .frame(maxWidth: .infinity, minHeight: pageViewportHeight)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24).onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width < 0 { advance() } else { goBack() }
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageViewportHeight = $0 }
        #endif
    }

    @ViewBuilder
    private var pageContent: some View {
        if let page {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                WhatsNewIllustrationView(kind: page.illustration, baseSize: illustrationSize)

                Text(loc.localized("whatsNew.\(page.id).title"))
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .fixedSize(horizontal: false, vertical: true)

                Text(loc.localized("whatsNew.\(page.id).body"))
                    .font(CinemaFont.dynamicBody)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: proseWidth, alignment: .leading)
            .padding(.horizontal, pagePadding)
            .id(page.id)
            .transition(.opacity)
            .animation(motionEffects ? .easeInOut(duration: 0.25) : nil, value: index)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            dots
            // Same layout rule as `OnboardingScreen`'s footer: fixed-width CTAs
            // and a spacer on tvOS; equal slots across the row on iOS, where
            // three fixed 130 pt buttons came to 486 pt on a 402 pt iPhone and
            // pushed the whole screen past both edges.
            HStack(spacing: CinemaSpacing.spacing4) {
                #if os(tvOS)
                if index > 0 { backButton }
                Spacer(minLength: CinemaSpacing.spacing4)
                if !isLast {
                    CinemaButton(title: loc.localized("whatsNew.skip"), style: .ghost) { onFinish() }
                        .frame(maxWidth: ctaWidth)
                        .focused($focusedControl, equals: .skip)
                }
                #else
                backButton.slotVisible(index > 0)
                #endif
                CinemaButton(
                    title: loc.localized(isLast ? "whatsNew.done" : "whatsNew.next"),
                    style: .accent
                ) { advance() }
                .frame(maxWidth: ctaWidth)
                .focused($focusedControl, equals: .primary)
            }
            #if os(iOS)
            .frame(maxWidth: proseWidth)
            #endif
        }
        .padding(.horizontal, pagePadding)
        .padding(.top, CinemaSpacing.spacing4)
        .padding(.bottom, footerBottomPadding)
        #if os(tvOS)
        .focusSection()
        #endif
        // Same reason as the onboarding's: without this the focus engine lands
        // on whichever control comes first, which on a page carrying
        // « Précédent » is the one going backwards.
        .onAppear { focusedControl = .primary }
        .onChange(of: index) { focusedControl = .primary }
    }

    private var backButton: some View {
        CinemaButton(title: loc.localized("whatsNew.back"), style: .ghost) { goBack() }
            .frame(maxWidth: ctaWidth)
            .focused($focusedControl, equals: .back)
    }

    /// One accessibility element for the whole pager, so VoiceOver says
    /// « Page 2 sur 4 » once instead of reading four circles.
    private var dots: some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            ForEach(pages) { candidate in
                Circle()
                    .fill(candidate.id == page?.id ? themeManager.accent : CinemaColor.onSurfaceVariant.opacity(0.3))
                    .frame(width: CinemaScale.pt(8), height: CinemaScale.pt(8))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized("whatsNew.page", index + 1, pages.count))
    }

    // MARK: - Actions

    private func advance() {
        guard !isLast else { onFinish(); return }
        index += 1
    }

    private func goBack(orFinish: Bool = false) {
        guard index > 0 else {
            if orFinish { onFinish() }
            return
        }
        index -= 1
    }

    // MARK: - Metrics

    #if os(tvOS)
    private var pagePadding: CGFloat { CinemaTVLayout.pagePadding }
    private var proseWidth: CGFloat { CinemaTVLayout.readingMaxWidth }
    private var ctaWidth: CGFloat { CinemaTVLayout.ctaWidth }
    private var illustrationSize: CGFloat { 180 }
    private var footerBottomPadding: CGFloat { CinemaSpacing.spacing8 }
    #else
    private var pagePadding: CGFloat { CinemaSpacing.spacing6 }
    private var proseWidth: CGFloat { 520 }
    private var ctaWidth: CGFloat { .infinity }
    private var illustrationSize: CGFloat { 132 }
    private var footerBottomPadding: CGFloat { CinemaSpacing.spacing5 }
    #endif
}

extension View {
    /// iOS: a sheet with its own close button; tvOS: a full-screen cover, since
    /// a tvOS `.sheet` renders cramped. Shared by the launch host
    /// (`AppNavigation`) and the Réglages replay, so the two cannot drift.
    func whatsNewPresentation<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}
