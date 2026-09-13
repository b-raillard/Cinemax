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
struct WhatsNewScreen: View {
    let pages: [WhatsNewPage]
    /// Called by « Passer » and by the last page's CTA. The host owns what that
    /// means: stamping the installed version at launch, dismissing on a replay.
    let onFinish: () -> Void

    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEffects

    @State private var index = 0
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable { case primary, back, skip }

    private var page: WhatsNewPage? {
        pages.indices.contains(index) ? pages[index] : pages.first
    }

    private var isLast: Bool { index >= pages.count - 1 }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                pageBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        }
        #if os(tvOS)
        // Unlike the onboarding's, this screen is ALWAYS dismissible — it is
        // never the only thing between the user and their server — so Menu
        // needs no `nil` branch and no shared helper: back one page, or out.
        .onExitCommand { goBack(orFinish: true) }
        #endif
    }

    // MARK: - Page

    @ViewBuilder
    private var pageBody: some View {
        if let page {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                WhatsNewIllustrationView(kind: page.illustration, baseSize: illustrationSize)

                Text(loc.localized("whatsNew.\(page.id).title"))
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)

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
            #if os(iOS)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if value.translation.width < 0 { advance() } else { goBack() }
                }
            )
            #endif
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            dots
            HStack(spacing: CinemaSpacing.spacing4) {
                if index > 0 {
                    CinemaButton(title: loc.localized("whatsNew.back"), style: .ghost) { goBack() }
                        .frame(width: ctaWidth)
                        .focused($focusedControl, equals: .back)
                }
                Spacer(minLength: CinemaSpacing.spacing4)
                if !isLast {
                    CinemaButton(title: loc.localized("whatsNew.skip"), style: .ghost) { onFinish() }
                        .frame(width: ctaWidth)
                        .focused($focusedControl, equals: .skip)
                }
                CinemaButton(
                    title: loc.localized(isLast ? "whatsNew.done" : "whatsNew.next"),
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
        // Same reason as the onboarding's: without this the focus engine lands
        // on whichever control comes first, which on a page carrying
        // « Précédent » is the one going backwards.
        .onAppear { focusedControl = .primary }
        .onChange(of: index) { focusedControl = .primary }
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
    #else
    private var pagePadding: CGFloat { CinemaSpacing.spacing6 }
    private var proseWidth: CGFloat { 520 }
    private var ctaWidth: CGFloat { 130 }
    private var illustrationSize: CGFloat { 132 }
    #endif
}
