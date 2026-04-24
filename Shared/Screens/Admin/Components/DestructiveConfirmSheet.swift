#if os(iOS)
import SwiftUI
import CinemaxKit

/// Type-to-confirm sheet for irreversible admin actions (delete user, delete
/// media item). Raises the friction bar high enough that accidental destructive
/// taps are essentially impossible.
///
/// The caller provides the phrase the user must type — typically the user's
/// display name or the item's title. Case-insensitive comparison, whitespace
/// trimmed. The confirm button is disabled until the input matches.
///
/// For reversible destructive actions (revoke device, uninstall plugin) use a
/// `.confirmationDialog` with a `.destructive` role instead — this sheet is
/// reserved for truly irreversible operations.
@MainActor
struct DestructiveConfirmSheet: View {
    let title: String
    let message: String
    let requiredPhrase: String
    let confirmLabel: String
    let onConfirm: () async -> Void

    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss
    @State private var typed: String = ""
    @State private var isSubmitting = false

    private var matches: Bool {
        typed.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(requiredPhrase) == .orderedSame
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: CinemaScale.pt(44)))
                        .foregroundStyle(CinemaColor.error)
                        .frame(maxWidth: .infinity)
                        .padding(.top, CinemaSpacing.spacing4)

                    Text(message)
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                        Text(String(format: loc.localized("admin.destructive.typeToConfirm"), requiredPhrase))
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)

                        GlassTextField(
                            label: "",
                            text: $typed,
                            placeholder: requiredPhrase
                        )
                    }
                    .padding(.top, CinemaSpacing.spacing3)

                    CinemaButton(
                        title: confirmLabel,
                        style: .primary,
                        isLoading: isSubmitting
                    ) {
                        Task {
                            isSubmitting = true
                            await onConfirm()
                            isSubmitting = false
                            dismiss()
                        }
                    }
                    .disabled(!matches || isSubmitting)
                    .opacity(matches && !isSubmitting ? 1.0 : 0.5)
                    .tint(CinemaColor.error)
                    .padding(.top, CinemaSpacing.spacing3)
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel")) { dismiss() }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
#endif
