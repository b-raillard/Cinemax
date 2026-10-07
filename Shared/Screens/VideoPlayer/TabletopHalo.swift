#if os(iOS)
import UIKit

/// The table-mode halo: a LIVE MIRROR of the picture, not a capture. The video
/// view's layer is a `CAReplicatorLayer`: in table mode it draws a second,
/// flipped instance below the fold, recomposited by the render server on every
/// frame with no main-thread work. Probed on the iPhone Duo simulator on
/// 2026-10-07: the libVLC picture IS copied (`Player.takeSnapshot`, by
/// contrast, failed on hardware-decoded frames and blocked 40–380 ms).
enum TabletopHalo {
    static let opacity: Float = 0.38

    /// Height of the picture aspect-fitted into `viewSize`.
    static func pictureHeight(viewSize: CGSize, videoAspect: CGFloat?) -> CGFloat {
        let aspect = videoAspect ?? (16.0 / 9.0)
        return min(viewSize.height, (viewSize.width / aspect).rounded())
    }

    /// `instanceTransform` applies about the replicator's anchor (its centre):
    /// centre-relative, y′ = −y + k. The picture's bottom edge (y = picH / 2)
    /// must land at h / 2 + gap below the fold, so k = (h + picH) / 2 + gap.
    static func mirrorOffset(viewHeight: CGFloat, pictureHeight: CGFloat, gapBelowFold: CGFloat) -> CGFloat {
        (viewHeight + pictureHeight) / 2 + gapBelowFold
    }

    static func qualityLabel(width: Int) -> String {
        switch width {
        case 3200...: "4K"
        case 1800...: "1080p"
        case 1200...: "720p"
        default: "SD"
        }
    }

    /// The film bar's thumbnail, rendered by UIKit when the deck appears
    /// (~4 ms measured) — never continuously.
    @MainActor
    static func thumbnail(of view: UIView, videoAspect: CGFloat?) -> UIImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let picH = pictureHeight(viewSize: bounds.size, videoAspect: videoAspect)
        let top = (bounds.height - picH) / 2
        let scale = 164 / bounds.width   // 82 pt @2x
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 164, height: (picH * scale).rounded())
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            _ = view.drawHierarchy(in: CGRect(x: 0, y: -top * scale,
                                              width: bounds.width * scale, height: bounds.height * scale),
                                   afterScreenUpdates: false)
        }
    }
}

/// The player's video view. One instance in regular mode: zero cost.
final class MirroringVideoView: UIView {
    override static var layerClass: AnyClass { CAReplicatorLayer.self }

    /// Table mode: a second, flipped instance, its picture starting
    /// `gapBelowFold` pt below the bottom of the view (= the fold).
    func setMirror(enabled: Bool, pictureHeight: CGFloat, gapBelowFold: CGFloat) {
        guard let replicator = layer as? CAReplicatorLayer else { return }
        replicator.masksToBounds = false
        guard enabled else {
            replicator.instanceCount = 1
            return
        }
        let offset = TabletopHalo.mirrorOffset(viewHeight: bounds.height, pictureHeight: pictureHeight,
                                               gapBelowFold: gapBelowFold)
        replicator.instanceCount = 2
        replicator.instanceTransform = CATransform3DConcat(CATransform3DMakeScale(1, -1, 1),
                                                           CATransform3DMakeTranslation(0, offset, 0))
        replicator.instanceAlphaOffset = TabletopHalo.opacity - 1
    }
}

/// Over the reflection, on the lower half: a native blur (live, on the GPU)
/// then a fade to black — the reflection dies out downwards as in the mockup.
/// Not interactive: touches fall through to `tabletopBackdrop`.
final class TabletopHaloVeil: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        blur.alpha = 0.7
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blur)
        fade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.45).cgColor, UIColor.black.cgColor]
        fade.locations = [0, 0.35, 0.8]
        layer.addSublayer(fade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        fade.frame = bounds
    }
}
#endif
