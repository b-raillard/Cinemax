import SwiftUI

struct GlassTextField: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEffects
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var icon: String? = nil
    var isSecure: Bool = false
    /// Two-way mirror of the inner field's focus, so a form can chain its
    /// fields — the username's Return key moving on to the password. Setting
    /// it to `true` focuses the field; the field writes its own state back.
    var focusRequest: Binding<Bool>? = nil
    #if os(iOS)
    var keyboardType: UIKeyboardType = .default
    #endif

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            if !label.isEmpty {
                Text(label.uppercased())
                    .font(.system(size: labelFontSize, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(.leading, 4)
            }

            #if os(tvOS)
            tvOSField
            #else
            iOSField
            #endif
        }
        .onChange(of: focusRequest?.wrappedValue ?? false) { _, wantsFocus in
            if wantsFocus, !isFocused { isFocused = true }
        }
        .onChange(of: isFocused) { _, focused in
            if let focusRequest, focusRequest.wrappedValue != focused { focusRequest.wrappedValue = focused }
        }
    }

    // MARK: - tvOS

    #if os(tvOS)
    private var tvOSField: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: CinemaScale.pt(24)))
                    .foregroundStyle(
                        isFocused ? themeManager.accent : CinemaColor.outline
                    )
            }

            if isSecure {
                SecureField(placeholder, text: $text)
                    .focused($isFocused)
            } else {
                TextField(placeholder, text: $text)
                    .focused($isFocused)
                    .autocorrectionDisabled()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .fill(CinemaColor.surfaceContainerHighest.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .stroke(
                    isFocused ? themeManager.accent.opacity(0.5) : .clear,
                    lineWidth: 3
                )
        )
    }
    #endif

    // MARK: - iOS

    #if os(iOS)
    private var iOSField: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: CinemaScale.pt(18)))
                    .foregroundStyle(
                        isFocused ? themeManager.accent : CinemaColor.outline
                    )
                    .animation(motionEffects ? .easeInOut(duration: 0.2) : nil, value: isFocused)
            }

            if isSecure {
                SecureField(placeholder, text: $text)
                    .focused($isFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: CinemaScale.pt(18), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                    .tint(themeManager.accent)
            } else {
                TextField(placeholder, text: $text)
                    .focused($isFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: CinemaScale.pt(18), weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                    .tint(themeManager.accent)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .fill(CinemaColor.surfaceContainerHighest.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .stroke(
                    isFocused ? themeManager.accent.opacity(0.3) : .clear,
                    lineWidth: 2
                )
        )
        .animation(motionEffects ? .easeInOut(duration: 0.2) : nil, value: isFocused)
    }
    #endif

    private var labelFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(18)
        #else
        CinemaScale.pt(12)
        #endif
    }
}

/// What a form field holds, for AutoFill and the Return key.
enum CredentialFieldKind {
    case username
    case password
    case serverURL

    fileprivate var contentType: UITextContentType {
        switch self {
        case .username: .username
        case .password: .password
        case .serverURL: .URL
        }
    }
}

extension View {
    /// AutoFill and a working Return key for a pre-auth form field.
    ///
    /// The sign-in forms had neither: no `textContentType`, so iCloud Keychain
    /// never offered the saved account (nor tvOS its « sign in with your
    /// iPhone »), and a Return key that did nothing. The username's key reads
    /// « Suivant » and moves on; the others read « Aller » and submit.
    /// Applied to the whole `GlassTextField` — all three are environment-borne,
    /// so they reach the inner `TextField` / `SecureField`.
    func credentialField(_ kind: CredentialFieldKind, onSubmit action: @escaping () -> Void) -> some View {
        self
            .textContentType(kind.contentType)
            .submitLabel(kind == .username ? .next : .go)
            .onSubmit(action)
    }
}
