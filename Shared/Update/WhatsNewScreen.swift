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
    /// The pages as they were when the reel opened. FROZEN on purpose: the
    /// language offer resolves against the app's language, so the Réglages
    /// replay — which recomputes its pages on every render — would drop the
    /// page from under the user the moment they accept it.
    @State private var pages: [WhatsNewPage]
    /// Called by the close button / « Passer » and by the last page's CTA. The
    /// host owns what that means: stamping the installed version at launch,
    /// dismissing on a replay.
    let onFinish: () -> Void

    init(pages: [WhatsNewPage], onFinish: @escaping () -> Void) {
        _pages = State(initialValue: pages)
        self.onFinish = onFinish
    }

    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEffects
    @Environment(SeasonalThemeController.self) private var seasonal
    @Environment(ToastCenter.self) private var toasts

    @State private var index = 0
    /// A page with a Duo variant speaks to an iPhone Duo's owner (`detectsIPhoneDuo`).
    @State private var isDuo = false
    @FocusState private var focusedControl: Control?
    #if os(iOS)
    /// Height of the scrolling page area, so a short page can be centred in it
    /// while a long one (large Dynamic Type) still scrolls.
    @State private var pageViewportHeight: CGFloat = 0
    #endif

    private enum Control: Hashable { case primary, back, skip, decline }

    private var page: WhatsNewPage? {
        pages.indices.contains(index) ? pages[index] : pages.first
    }

    private var isLast: Bool { index >= pages.count - 1 }

    /// The season this page offers, if it offers one.
    private var offeredSeason: SeasonalTheme? {
        guard case .seasonalTheme(let id) = page?.offer else { return nil }
        return SeasonalThemeCatalogue.theme(id: id)
    }

    /// The language this page offers (`WhatsNewOffer.appLanguage`), if any.
    private var offeredLanguage: String? {
        guard case .appLanguage(let code) = page?.offer else { return nil }
        return code
    }

    /// The offered language named in the app's CURRENT language (« allemand »),
    /// for the body. The button stays « Activer »: « Passer en allemand »
    /// truncated in the iPhone's half-width slot, and the chip and the title
    /// above it already say which language.
    private func languageName(_ code: String) -> String {
        loc.locale.localizedString(forLanguageCode: code) ?? loc.localized(AppLanguage.nameKey(code))
    }

    /// The page still has something to switch on: « Activer » / « Non merci »
    /// replace the navigation button. Once on (or on a replay after
    /// accepting), the page reads like any other and wears a « ✓ Activé » chip.
    private var offerPending: Bool {
        if offeredSeason != nil { return seasonal.setting != .automatic }
        if let code = offeredLanguage { return loc.languageCode != code }
        return false
    }

    /// Title and body of a page. The language offer is the exception to the
    /// `whatsNew.<id>.*` rule on two counts: its TITLE is read in the offered
    /// language (« JellyGlass auf Deutsch » — the line meant for the person
    /// whose phone speaks it), and its body names that language.
    private func texts(for page: WhatsNewPage) -> (title: String, body: String) {
        if let code = offeredLanguage {
            let title = Bundle.localizedBundle(for: code)
                .localizedString(forKey: "whatsNew.\(page.id).title", value: nil, table: nil)
            return (title, loc.localized("whatsNew.\(page.id).body", languageName(code)))
        }
        let key = page.textKey(onDuo: isDuo)
        return (loc.localized("whatsNew.\(key).title"), loc.localized("whatsNew.\(key).body"))
    }

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
        .detectsIPhoneDuo($isDuo)
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
                    .foregroundStyle(themeManager.onAccentContainer)
                    .padding(10)
                    .background(themeManager.accentContainer)
                    .clipShape(Circle())
                    // A 34 pt disc inside a 44 pt target (audit §5, lot 9).
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
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

                if let season = offeredSeason { offerBadges(for: season) }
                if let code = offeredLanguage { languageBadges(for: code) }

                Text(texts(for: page).title)
                    .font(offeredSeason.flatMap { SeasonalTypography.titleFont(for: $0, size: CinemaScale.pt(titleFaceSize)) }
                          ?? CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .fixedSize(horizontal: false, vertical: true)

                Text(texts(for: page).body)
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

    /// « Éphémère · du 1er octobre au 2 novembre » — dates read from the
    /// catalogue, so the page cannot announce a window the theme does not
    /// have — and « ✓ Activé » once the user said yes.
    private func offerBadges(for season: SeasonalTheme) -> some View {
        // In the SEASON's accent, not the user's: the pill belongs to the
        // scene above it, and the theme is not on yet.
        let tint = Color.dynamic(light: season.accent.accentLight, dark: season.accent.accentDark)
        let window = badge(
            loc.localized(
                "whatsNew.offer.window",
                SeasonalSettingsText.dayMonth(season.window.start, locale: loc.locale, abbreviated: true),
                SeasonalSettingsText.dayMonth(season.window.end, locale: loc.locale, abbreviated: true)
            ),
            systemImage: "hourglass", tint: tint
        )
        // VoiceOver reads the dates in full, not « oct. → nov. ».
        .accessibilityLabel(SeasonalSettingsText.windowSummary(
            for: season, name: loc.localized(season.nameKey),
            template: loc.localized("settings.seasonal.window"),
            locale: loc.locale, calendar: .autoupdatingCurrent
        ))
        let enabled = badge(loc.localized("whatsNew.offer.enabled"), systemImage: "checkmark", tint: tint)
        // Side by side when they fit, stacked at large text sizes or on a
        // narrow phone rather than truncating the dates.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: CinemaSpacing.spacing2) {
                window
                if !offerPending { enabled }
            }
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                window
                if !offerPending { enabled }
            }
        }
    }

    /// « 🌐 Deutsch » — the language in its own name — and « ✓ Activé » once
    /// the app speaks it.
    private func languageBadges(for code: String) -> some View {
        let tint = themeManager.accent
        return HStack(spacing: CinemaSpacing.spacing2) {
            badge(loc.localized(AppLanguage.nameKey(code)), systemImage: "globe", tint: tint)
            if !offerPending {
                badge(loc.localized("whatsNew.offer.enabled"), systemImage: "checkmark", tint: tint)
            }
        }
    }

    private func badge(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(CinemaFont.label(.medium))
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.vertical, CinemaSpacing.spacing1)
            .background(tint.opacity(0.14), in: Capsule())
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
                if offerPending {
                    declineButton
                } else if !isLast {
                    CinemaButton(title: loc.localized("whatsNew.skip"), style: .ghost) { onFinish() }
                        .frame(maxWidth: ctaWidth)
                        .focused($focusedControl, equals: .skip)
                }
                #else
                // The offer's « Non merci » takes the back slot; a swipe still
                // goes back. An offer is normally its reel's FIRST page (the
                // newest release leads), so no « Précédent » is lost — but an
                // install skipping from 2.2 to 2.3.1 gets the language offer
                // THEN the Halloween one, whose page then has no « Précédent »
                // button (the swipe still goes back) — accepted: going back to
                // a language already chosen has nothing left to do.
                if offerPending {
                    declineButton
                } else {
                    backButton.slotVisible(index > 0)
                }
                #endif
                // ONE button whose title and action switch: two views swapped
                // under focus let tvOS drop focus onto « Précédent » while
                // `index` moves in the same transaction.
                CinemaButton(title: primaryTitle, style: .accent) {
                    if offerPending { acceptOffer() } else { advance() }
                }
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

    private var primaryTitle: String {
        if offerPending { return loc.localized("whatsNew.offer.accept") }
        return loc.localized(isLast ? "whatsNew.done" : "whatsNew.next")
    }

    private var declineButton: some View {
        CinemaButton(title: loc.localized("whatsNew.offer.decline"), style: .ghost) { advance() }
            .frame(maxWidth: ctaWidth)
            .focused($focusedControl, equals: .decline)
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

    /// One tap: the theme goes on through its only mutator, then the reel
    /// moves on. In season the app turns over at once, behind the sheet; out
    /// of season nothing would show, so a toast names the day it starts.
    private func acceptOffer() {
        if let code = offeredLanguage {
            // The whole reel turns over at once, this page included — which
            // is how the user sees that it worked.
            loc.languageCode = code
            advance()
            return
        }
        guard let season = offeredSeason else { advance(); return }
        seasonal.setSetting(.automatic)
        if let start = SeasonalOffer.startsLater(season, on: Date(), calendar: .autoupdatingCurrent) {
            toasts.success(
                loc.localized("whatsNew.offer.accepted"),
                message: loc.localized("whatsNew.offer.startsOn", SeasonalSettingsText.dayMonth(start, locale: loc.locale))
            )
        }
        advance()
    }

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
    private var titleFaceSize: CGFloat { 52 }
    private var footerBottomPadding: CGFloat { CinemaSpacing.spacing8 }
    #else
    private var pagePadding: CGFloat { CinemaSpacing.spacing6 }
    private var proseWidth: CGFloat { 520 }
    private var ctaWidth: CGFloat { .infinity }
    private var illustrationSize: CGFloat { 132 }
    private var titleFaceSize: CGFloat { 34 }
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
