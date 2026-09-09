import SwiftUI

/// Quick Connect *authorize* sheet, opened from Settings → Account by a
/// signed-in user. They type the six-character code another device is showing
/// on its login screen (`QuickConnectSheet`); approving it lets that device
/// finish signing in as the current user. The mirror image of
/// `QuickConnectSheet`, which only *displays* a code.
///
/// iOS presents it as a `.sheet`, tvOS as a `.fullScreenCover` — the same split
/// the login Quick Connect sheet uses (tvOS `.sheet` renders a cramped modal).
/// The tvOS body wears the one chrome every tvOS modal shares
/// (`WatchedHistoryScreen`): header row with the title and an accent Cancel
/// button, content below at the page margin, Menu dismisses.
struct QuickConnectAuthorizeSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = QuickConnectAuthorizeViewModel()
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        Group {
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
        #if os(iOS)
        // Bring up the number pad straight away — the user came here to type a
        // code. On tvOS we DON'T auto-focus: it would force-open the full-screen
        // keyboard over the instructions before the user can read them (matches
        // LoginScreen / SearchScreen, which also let the user open it on demand).
        .onAppear { codeFieldFocused = true }
        #endif
        .onChange(of: viewModel.didAuthorize) { _, done in
            guard done else { return }
            codeFieldFocused = false
            Task {
                // Hold the inline confirmation briefly, then dismiss and leave a
                // toast on the Settings screen as the lasting confirmation.
                try? await Task.sleep(for: .seconds(1.1))
                toasts.success(loc.localized("quickConnect.authorize.success"))
                dismiss()
            }
        }
    }

    // MARK: - iOS

    #if !os(tvOS)
    private var iOSBody: some View {
        VStack(spacing: CinemaSpacing.spacing6) {
            header

            stateContent

            Spacer(minLength: 0)
        }
        .padding(CinemaSpacing.spacing6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CinemaColor.surface.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
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

            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: CinemaScale.pt(40)))
                .foregroundStyle(themeManager.accent)

            Text(loc.localized("quickConnect.authorize.title"))
                .font(.system(size: CinemaScale.pt(24), weight: .black))
                .foregroundStyle(CinemaColor.onSurface)
        }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvOSBody: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                tvHeader

                // The header carries the title, so the column keeps only the
                // glyph above the form.
                VStack(spacing: CinemaSpacing.spacing6) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: CinemaScale.pt(40)))
                        .foregroundStyle(themeManager.accent)

                    stateContent
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
            Text(loc.localized("quickConnect.authorize.title"))
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
        // Without this, up-presses from the code field never reach the Cancel
        // button (separate container — same rule as the Home/Library hero).
        .focusSection()
    }
    #endif

    // MARK: - Shared

    @ViewBuilder
    private var stateContent: some View {
        if viewModel.didAuthorize {
            successState
        } else {
            formState
        }
    }

    // MARK: - Form

    private var formState: some View {
        VStack(spacing: CinemaSpacing.spacing5) {
            Text(loc.localized("quickConnect.authorize.instructions"))
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            codeField

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.error)
                    .multilineTextAlignment(.center)
            }

            CinemaButton(
                title: loc.localized("quickConnect.authorize.submit"),
                style: .accent,
                isLoading: viewModel.isSubmitting
            ) {
                codeFieldFocused = false
                Task { await viewModel.submit(using: appState, loc: loc) }
            }
            .disabled(!viewModel.canSubmit)
            .opacity(viewModel.canSubmit ? 1 : 0.5)
        }
        .frame(maxWidth: 420)
    }

    private var codeField: some View {
        TextField("", text: Binding(
            get: { viewModel.code },
            set: { viewModel.sanitize($0) }
        ))
        .focused($codeFieldFocused)
        .multilineTextAlignment(.center)
        .font(.system(size: CinemaScale.pt(34), weight: .heavy, design: .monospaced))
        .tracking(8)
        .foregroundStyle(CinemaColor.onSurface)
        .tint(themeManager.accent)
        .autocorrectionDisabled()
        #if os(iOS)
        .keyboardType(.numberPad)
        .textInputAutocapitalization(.never)
        #endif
        .padding(.vertical, CinemaSpacing.spacing4)
        .padding(.horizontal, CinemaSpacing.spacing6)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: CinemaRadius.large)
        .overlay {
            if viewModel.code.isEmpty {
                Text(loc.localized("quickConnect.authorize.codePlaceholder"))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant.opacity(0.6))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Success

    private var successState: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: CinemaScale.pt(56)))
                .foregroundStyle(themeManager.accent)

            Text(loc.localized("quickConnect.authorize.success"))
                .font(.system(size: CinemaScale.pt(20), weight: .bold))
                .foregroundStyle(CinemaColor.onSurface)
        }
        .padding(.top, CinemaSpacing.spacing6)
    }
}
