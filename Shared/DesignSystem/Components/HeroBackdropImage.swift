import SwiftUI
import UIKit
import Nuke

/// A full-bleed hero backdrop. iOS: a plain `CinemaLazyImage` (its heroes
/// rotate instead — see `HomeScreen`). tvOS: the same image with a very slow
/// scale drift, so a hero that never changes for the life of the screen still
/// has some life, without moving anything the remote can aim at.
///
/// The fallback colour sits BEHIND the image, so a missing or failed backdrop
/// reads exactly like `CinemaLazyImage(fallbackIcon: nil)` did.
struct HeroBackdropImage: View {
    let url: URL?
    var fallbackBackground: Color = CinemaColor.surfaceContainerLow

    #if os(tvOS)
    @Environment(\.motionEffectsEnabled) private var motionEnabled
    #endif

    var body: some View {
        #if os(tvOS)
        fallbackBackground
            .overlay { DriftingBackdropRepresentable(url: url, drifting: motionEnabled) }
        #else
        CinemaLazyImage(url: url, fallbackIcon: nil, fallbackBackground: fallbackBackground)
        #endif
    }
}

#if os(tvOS)
/// The drift's shape: 1.08 over 24 s, autoreversing — about 0.3 % of the frame
/// per second.
enum HeroDrift {
    static let scale: CGFloat = 1.08
    static let period: CFTimeInterval = 24
    static let animationKey = "cinemax.hero.drift"

    /// A Core Animation drift, run by the render server. It was a SwiftUI
    /// `.repeatForever` `scaleEffect` until lot 8 (2026-09-26): SwiftUI ticks
    /// such an animation on the MAIN thread every frame, and on the Apple TV
    /// 4K (A15) the idle Home spent ~1,600 main-thread samples per 15 s on it
    /// (re-committing the transaction and re-rasterising the hero's text)
    /// against 42 with motion effects off — a constant ~10–12 % CPU for a
    /// screen nobody touches. Measured in Instruments, numbers in PR / audit §11.
    static func makeAnimation() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.0
        animation.toValue = scale
        animation.duration = period
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Survives the app going to the background and the view leaving its
        // window; `DriftingBackdropView` still re-adds it on window entry in
        // case the system stripped it.
        animation.isRemovedOnCompletion = false
        return animation
    }
}

private struct DriftingBackdropRepresentable: UIViewRepresentable {
    let url: URL?
    let drifting: Bool

    func makeUIView(context: Context) -> DriftingBackdropView { DriftingBackdropView() }

    func updateUIView(_ view: DriftingBackdropView, context: Context) {
        view.load(url)
        view.setDrifting(drifting)
    }

    static func dismantleUIView(_ view: DriftingBackdropView, coordinator: ()) {
        view.cancelLoad()
    }
}

/// A clipping container whose image view carries the drift. A plain `UIView`
/// root on purpose: an image view as the representable's root would report the
/// image's pixel size as its intrinsic size and push back on the hero's frame.
final class DriftingBackdropView: UIView {
    let imageView = UIImageView()
    private var loadedURL: URL?
    private var loadTask: Task<Void, Never>?
    private(set) var isDrifting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Same pipeline and same plain `ImageRequest(url:)` as `LazyImage`, so the
    /// backdrop hits the cache entry the prefetcher and the iOS hero warm.
    func load(_ url: URL?) {
        guard url != loadedURL else { return }
        loadedURL = url
        loadTask?.cancel()
        guard let url else {
            imageView.image = nil
            return
        }
        if let cached = ImagePipeline.shared.cache[url] {
            imageView.image = cached.image
            return
        }
        imageView.image = nil
        loadTask = Task { [weak self] in
            let image = try? await ImagePipeline.shared.image(for: url)
            guard let self, !Task.isCancelled, self.loadedURL == url else { return }
            self.imageView.image = image
        }
    }

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    func setDrifting(_ drifting: Bool) {
        guard drifting != isDrifting else { return }
        isDrifting = drifting
        applyDrift()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyDrift()
    }

    private func applyDrift() {
        let layer = imageView.layer
        if isDrifting, window != nil {
            if layer.animation(forKey: HeroDrift.animationKey) == nil {
                layer.add(HeroDrift.makeAnimation(), forKey: HeroDrift.animationKey)
            }
        } else if !isDrifting {
            layer.removeAnimation(forKey: HeroDrift.animationKey)
        }
    }
}
#endif
