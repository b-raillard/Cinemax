#if os(iOS)
import SwiftUI
import CinemaxKit

/// Type-to-confirm sheet for irreversible admin actions (delete user, delete
/// media item). Raises the friction bar high enough that accidental destructive
/// taps are essentially impossible.
///
/// The caller provides the phrase the user must type — typically the user's
/// display name or the item's title. The comparison is `ConfirmPhrase.matches`,
/// **never a raw string compare**: the keyboard's smart punctuation rewrites the
/// apostrophe as it is typed, so `L'Odyssée` reached this view as `L’Odyssée`
/// and the button stayed disabled for ever. See that type for the full rule.
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
        ConfirmPhrase.matches(typed: typed, required: requiredPhrase)
    }

    /// Only accuse a mismatch once the user has actually typed something — an
    /// empty field is the starting state, not a mistake.
    private var showsMismatch: Bool {
        !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !matches
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    warningIcon

                    Text(message)
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    confirmField

                    confirmButton
                }
                .padding(CinemaSpacing.spacing4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .background(CinemaColor.surface)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel")) { dismiss() }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
        // `.medium` clipped the confirm button off the bottom of the sheet —
        // and the keyboard this sheet always raises took what was left, so the
        // one control the screen exists for was below the fold at the moment it
        // mattered. There is no second detent to offer: the content needs the
        // full height either way.
        .presentationDetents([.large])
        .presentationBackground(CinemaColor.surface)
    }

    // MARK: - Sections

    private var warningIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: CinemaScale.pt(34), weight: .semibold))
            .foregroundStyle(CinemaColor.onErrorContainer)
            .frame(width: CinemaScale.pt(78), height: CinemaScale.pt(78))
            .background(Circle().fill(CinemaColor.errorContainer))
            .frame(maxWidth: .infinity)
            .padding(.top, CinemaSpacing.spacing3)
            .accessibilityHidden(true)
    }

    private var confirmField: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Text(String(format: loc.localized("admin.destructive.typeToConfirm"), requiredPhrase))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)

            GlassTextField(
                label: "",
                text: $typed,
                placeholder: requiredPhrase
            )

            // The button coming alive is the only signal that the phrase took;
            // nothing explained its ABSENCE, so a mismatch read as a dead
            // button — which is exactly how the smart-quote defect was
            // reported. Held in the layout at zero opacity so typing the last
            // character doesn't shift the button out from under the finger.
            Text(loc.localized("admin.destructive.mismatch"))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.error)
                .opacity(showsMismatch ? 1 : 0)
                .accessibilityHidden(!showsMismatch)
        }
        .padding(.top, CinemaSpacing.spacing2)
    }

    private var confirmButton: some View {
        CinemaButton(
            title: confirmLabel,
            style: .destructive,
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
        // Dimmed red, not dimmed grey: the old neutral gradient at 0.5 over a
        // near-black sheet left "Supprimer définitivement" illegible, so the
        // armed and unarmed states looked equally dead.
        .opacity(matches ? 1 : 0.55)
        .padding(.top, CinemaSpacing.spacing2)
    }
}
#endif
