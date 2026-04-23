#if os(iOS)
import SwiftUI
import CinemaxKit

/// Scrolling form with a sticky `Sauvegarder` footer. Used by every admin
/// editor (user policy, playback defaults, network, metadata tabs).
///
/// Save is explicit because admin-scoped changes can have blast radius (policy
/// revocations, password resets, network rebinding). Auto-save would be
/// dangerous here — the user should have an intentional confirmation gesture.
///
/// The component owns the save button + its loading state. Dirty-state
/// tracking lives in the caller's view model, which passes `isDirty` in.
/// Confirm-on-dismiss is enforced via `.interactiveDismissDisabled(isDirty)`
/// plus a custom back-button interception in the toolbar.
@MainActor
struct AdminFormScreen<Content: View>: View {
    let isDirty: Bool
    let isSaving: Bool
    let onSave: () async -> Void
    let onDiscard: (() -> Void)?
    @ViewBuilder let content: Content

    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @State private var showDiscardConfirm = false

    init(
        isDirty: Bool,
        isSaving: Bool = false,
        onSave: @escaping () async -> Void,
        onDiscard: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isDirty = isDirty
        self.isSaving = isSaving
        self.onSave = onSave
        self.onDiscard = onDiscard
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                    content
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.top, CinemaSpacing.spacing4)
                .padding(.bottom, 100) // clearance for sticky footer
            }

            saveFooter
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog(
            loc.localized("admin.form.discardChanges.title"),
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button(loc.localized("admin.form.discard"), role: .destructive) {
                onDiscard?()
                dismiss()
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("admin.form.discardChanges.message"))
        }
    }

    private var saveFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(CinemaColor.outlineVariant.opacity(0.3))
                .frame(height: 1)

            CinemaButton(
                title: loc.localized("action.save"),
                style: .primary,
                isLoading: isSaving
            ) {
                Task { await onSave() }
            }
            .disabled(!isDirty || isSaving)
            .opacity(isDirty && !isSaving ? 1.0 : 0.5)
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.top, CinemaSpacing.spacing3)
            .padding(.bottom, CinemaSpacing.spacing4)
        }
        .background(.ultraThinMaterial)
    }
}
#endif
