import SwiftUI

struct GlassTextField: View {
    @Environment(ThemeManager.self) private var themeManager
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var icon: String? = nil
    var isSecure: Bool = false

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
    }

    // MARK: - tvOS

    #if os(tvOS)
    private var tvOSField: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 24))
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
                    .font(.system(size: 18))
                    .foregroundStyle(
                        isFocused ? themeManager.accent : CinemaColor.outline
                    )
                    .animation(.easeInOut(duration: 0.2), value: isFocused)
            }

            if isSecure {
                SecureField(placeholder, text: $text)
                    .focused($isFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                    .tint(themeManager.accent)
            } else {
                TextField(placeholder, text: $text)
                    .focused($isFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(CinemaColor.onSurface)
                    .tint(themeManager.accent)
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
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
    #endif

    private var labelFontSize: CGFloat {
        #if os(tvOS)
        18
        #else
        12
        #endif
    }
}
