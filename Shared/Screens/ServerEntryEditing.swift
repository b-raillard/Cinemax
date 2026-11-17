import SwiftUI
import CinemaxKit

// MARK: - Server entry editing (rename, local address)

/// A LAN certificate waiting for the user's approval: the entry id (re-resolved
/// at action time, like every pending action here), the text typed, and the
/// summary SHOWN — its exact fingerprint is what gets pinned (R15).
struct LocalCertificateApproval: Identifiable {
    let entryId: String
    let raw: String
    let summary: ServerCertificateSummary
    /// The host already carried a pin: the certificate CHANGED since.
    let isRotation: Bool
    var id: String { summary.fingerprint }
}

/// The pending state of the two per-server edits « Renommer » and « Adresse
/// locale… », shared by « Mes serveurs » (every card) and Réglages → Serveur
/// (the active-server card). Each host owns one as `@State` and applies
/// `.serverEntryEditing(_:)`, which presents the alerts and the certificate
/// approval; the menu items are `renameButton` / `localAddressButton`.
///
/// **RULE — pending edits hold an entry `id`, never a captured entry**
/// (`ServersScreen` RULE (b)): every commit re-resolves from `appState.servers`
/// at action time, so a probe's metadata write-back between the tap and the
/// save is never regressed.
@MainActor @Observable
final class ServerEntryEditor {
    /// Id of the entry being renamed.
    var pendingRenameId: String?
    var renameText = ""
    /// Id of the entry whose local address is being edited.
    var pendingLocalAddressId: String?
    var localAddressText = ""
    /// The LAN certificate the last save asked to approve.
    var pendingApproval: LocalCertificateApproval?

    /// Opens the rename alert pre-filled with the name currently shown.
    func beginRename(id: String, in servers: [ServerEntry]) {
        renameText = servers.first(where: { $0.id == id })?.displayName ?? ""
        pendingRenameId = id
    }

    /// Opens the local-address alert pre-filled with the stored address.
    func beginLocalAddress(id: String, in servers: [ServerEntry]) {
        localAddressText = servers.first(where: { $0.id == id })?.localURL?.absoluteString ?? ""
        pendingLocalAddressId = id
    }

    /// « Renommer » — a plain `Button`, so a host can tint it in `.swipeActions`.
    /// The registry is read when the item is CHOSEN, not when the menu is built.
    func renameButton(for id: String, appState: AppState, loc: LocalizationManager) -> some View {
        Button {
            self.beginRename(id: id, in: appState.servers)
        } label: {
            Label(loc.localized("servers.rename"), systemImage: "pencil")
        }
    }

    /// « Adresse locale… » — same shape as `renameButton`.
    func localAddressButton(for id: String, appState: AppState, loc: LocalizationManager) -> some View {
        Button {
            self.beginLocalAddress(id: id, in: appState.servers)
        } label: {
            Label(loc.localized("servers.localAddress"), systemImage: "house")
        }
    }
}

extension View {
    /// Presents `editor`'s rename alert, local-address alert and LAN
    /// certificate approval, and runs their saves. `onLocalAddressSettled`
    /// runs after every settled local-address save (a toast shown), with the
    /// entry id — « Mes serveurs » re-probes that card there.
    func serverEntryEditing(
        _ editor: ServerEntryEditor,
        onLocalAddressSettled: ((String) async -> Void)? = nil
    ) -> some View {
        modifier(ServerEntryEditingPresentations(editor: editor, onLocalAddressSettled: onLocalAddressSettled))
    }
}

/// The rename alert, the local-address entry alert and the LAN certificate
/// approval. The entries are `.alert`s with a `TextField` on both platforms
/// (tvOS: the system text entry). The approval is `serverConfirmation`: an
/// alert on iOS, a confirmation dialog on tvOS (a SwiftUI alert has focus bugs
/// there), whose first button « Faire confiance à ce certificat » takes the focus.
private struct ServerEntryEditingPresentations: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    @Bindable var editor: ServerEntryEditor
    let onLocalAddressSettled: ((String) async -> Void)?

    func body(content: Content) -> some View {
        content
            .alert(
                loc.localized("servers.rename.title"),
                isPresented: Binding(
                    get: { editor.pendingRenameId != nil },
                    set: { if !$0 { editor.pendingRenameId = nil } }
                ),
                presenting: editor.pendingRenameId
            ) { id in
                // The placeholder is the server's own name — exactly what an empty
                // field falls back to.
                TextField(serverOwnName(for: id), text: $editor.renameText)
                Button(loc.localized("action.save")) { commitRename(id: id) }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            } message: { id in
                Text(loc.localized("servers.rename.message", serverOwnName(for: id)))
            }
            .alert(
                loc.localized("servers.localAddress.title"),
                isPresented: Binding(
                    get: { editor.pendingLocalAddressId != nil },
                    set: { if !$0 { editor.pendingLocalAddressId = nil } }
                ),
                presenting: editor.pendingLocalAddressId
            ) { id in
                TextField(loc.localized("servers.localAddress.placeholder"), text: $editor.localAddressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                Button(loc.localized("action.save")) { commitLocalAddress(id: id) }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            } message: { _ in
                Text(loc.localized("servers.localAddress.message"))
            }
            .serverConfirmation(
                loc.localized("server.certificate.title"),
                isPresented: Binding(
                    get: { editor.pendingApproval != nil },
                    set: { if !$0 { editor.pendingApproval = nil } }
                ),
                presenting: editor.pendingApproval
            ) { approval in
                Button(loc.localized("server.certificate.trust")) { trust(approval) }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            } message: { approval in
                Text(approvalMessage(approval))
            }
    }

    // MARK: Rename

    /// The name the SERVER reports — what an empty rename falls back to.
    private func serverOwnName(for id: String) -> String {
        appState.servers.first(where: { $0.id == id })?.name ?? ServerEntry.fallbackName
    }

    /// Toasts only on a real change — saving the field untouched says nothing.
    private func commitRename(id: String) {
        let before = appState.servers.first(where: { $0.id == id })?.displayNameOverride
        guard let updated = appState.renameServer(id: id, to: editor.renameText),
              updated.displayNameOverride != before else { return }
        if updated.displayNameOverride == nil {
            toasts.success(loc.localized("servers.renameReset", updated.name))
        } else {
            toasts.success(loc.localized("servers.renamed", updated.displayName))
        }
    }

    // MARK: Local address

    private func commitLocalAddress(id: String) {
        let raw = editor.localAddressText
        Task { await handleLocalAddress(await appState.setLocalAddress(id: id, raw: raw), id: id, raw: raw) }
    }

    /// Pins exactly the fingerprint the user was shown (R15): `AppState` pins
    /// it only while the pending certificate still carries it, and otherwise
    /// answers `.needsCertificateApproval` again with the new one.
    private func trust(_ approval: LocalCertificateApproval) {
        Task {
            let outcome = await appState.trustLocalCertificate(
                id: approval.entryId, raw: approval.raw, fingerprint: approval.summary.fingerprint
            )
            await handleLocalAddress(outcome, id: approval.entryId, raw: approval.raw)
        }
    }

    /// Every save's outcome lands here: a toast, or the certificate approval.
    private func handleLocalAddress(_ outcome: LocalAddressSaveOutcome, id: String, raw: String) async {
        if outcome == .needsCertificateApproval {
            guard appState.servers.contains(where: { $0.id == id }),
                  let summary = appState.pendingLocalCertificate(raw: raw) else {
                // The pending certificate is gone (the entry was removed, or
                // another probe replaced it): nothing to show, nothing saved.
                toasts.error(loc.localized("server.connectFailed"))
                return
            }
            editor.pendingApproval = LocalCertificateApproval(
                entryId: id,
                raw: raw,
                summary: summary,
                isRotation: ServerTrustDelegate.shared.isPinned(trustKey: summary.trustKey)
            )
            return
        }
        if let message = LocalAddressToast.message(for: outcome) {
            let text = loc.localized(message.key)
            switch message.level {
            case .success: toasts.success(text)
            case .error:   toasts.error(text)
            case .info:    toasts.info(text)
            }
        }
        await onLocalAddressSettled?(id)
    }

    /// What the approval shows, in the server-setup panel's order: why, what
    /// to check, then the host, the subject and the SHA-256 fingerprint in its
    /// grouped form — the thing that gets pinned.
    private func approvalMessage(_ approval: LocalCertificateApproval) -> String {
        let summary = approval.summary
        var lines = [
            loc.localized(approval.isRotation ? "server.certificate.changed" : "server.certificate.untrusted"),
            loc.localized("server.certificate.explain"),
            "",
            loc.localized("server.certificate.host").uppercased(),
            summary.host
        ]
        if let subject = summary.subject, !subject.isEmpty {
            lines += ["", loc.localized("server.certificate.subject").uppercased(), subject]
        }
        lines += ["", loc.localized("server.certificate.fingerprint").uppercased(), summary.formattedFingerprint]
        return lines.joined(separator: "\n")
    }
}
