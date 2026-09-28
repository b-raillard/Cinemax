import SwiftUI
import UIKit

// MARK: - Season trait
//
// The active season rides the UIKit trait system: set once on the window
// scene (`SeasonTraitApplier`), it reaches every window (the app's, the
// toasts', every UIKit presentation) and — through the bridge below — the
// SwiftUI environment as `\.seasonID`. `Color.dynamic` reads it in its
// provider, so the ~800 `CinemaColor` call sites repaint with no change.

struct SeasonTrait: UITraitDefinition {
    static let defaultValue: String? = nil
    static let affectsColorAppearance = true
    static let identifier = "com.cinemax.trait.season"
    static let name = "Season"
}

private struct SeasonEnvironmentKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension SeasonEnvironmentKey: UITraitBridgedEnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> String? {
        traitCollection[SeasonTrait.self]
    }

    static func write(to mutableTraits: inout UIMutableTraits, value: String?) {
        mutableTraits[SeasonTrait.self] = value
    }
}

extension EnvironmentValues {
    /// The active season's id, or `nil`. Views read THIS (a value, never a
    /// required object — a context menu or a sheet without the root's
    /// injected objects must not crash), then `SeasonalThemeCatalogue.theme(id:)`.
    var seasonID: String? {
        get { self[SeasonEnvironmentKey.self] }
        set { self[SeasonEnvironmentKey.self] = newValue }
    }
}

enum SeasonalColor {
    /// The hex a `CinemaColor` token paints. `token == nil`: the season never
    /// touches it.
    static func resolve(light: UInt, dark: UInt, token: SeasonToken?, isDark: Bool, season: SeasonalTheme?) -> UInt {
        if let token, let season {
            if isDark { return season.dark[token] }
            if let palette = season.light { return palette[token] }
        }
        return isDark ? dark : light
    }
}

/// Zero-size view that writes the season onto its window SCENE, so the
/// toasts' own window and the UIKit player get it too.
struct SeasonTraitApplier: UIViewRepresentable {
    let seasonID: String?

    func makeUIView(context: Context) -> SeasonTraitApplierView {
        let view = SeasonTraitApplierView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SeasonTraitApplierView, context: Context) {
        view.setSeasonID(seasonID)
    }
}

final class SeasonTraitApplierView: UIView {
    private var seasonID: String?

    func setSeasonID(_ id: String?) {
        seasonID = id
        apply()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        guard let scene = window?.windowScene else { return }
        if scene.traitOverrides[SeasonTrait.self] != seasonID {
            scene.traitOverrides[SeasonTrait.self] = seasonID
        }
    }
}
