import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// Sets `isDuo` to `true` once this view's window reports a hinge — an
    /// iPhone Duo — so a page can speak to its owner (« Films sur table »)
    /// rather than announce the support to everybody else.
    ///
    /// UIKit has no « is this a foldable » property: a `UIHingeInteraction`
    /// is the answer, reporting a hinge with a known status only on a device
    /// that has one. It never writes `false` — the interaction also reports
    /// `nil` when the view leaves its hierarchy, which says nothing about the
    /// device. Settings → Débogage « Simuler le mode table » counts as a Duo,
    /// so the Duo copy can be read on any iPhone. A no-op on tvOS and on an
    /// SDK without the hinge API (`NO_HINGE_API`).
    @ViewBuilder
    func detectsIPhoneDuo(_ isDuo: Binding<Bool>) -> some View {
        #if os(iOS)
        background(HingeProbe { isDuo.wrappedValue = true })
            .onAppear {
                if UserDefaults.standard.bool(forKey: SettingsKey.debugSimulateTabletop) { isDuo.wrappedValue = true }
            }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// An invisible view carrying the hinge interaction.
private struct HingeProbe: UIViewRepresentable {
    let onHinge: @MainActor () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        #if !NO_HINGE_API
        if #available(iOS 27.1, *) {
            let onHinge = self.onHinge
            view.addInteraction(UIHingeInteraction { _, update in
                if let hinge = update.hinge, hinge.status != .unknown { onHinge() }
            })
        }
        #endif
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
