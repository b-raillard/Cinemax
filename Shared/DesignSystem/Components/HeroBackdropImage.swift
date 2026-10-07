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

extension View {
    /// The backdrop layer of a full-bleed hero (image or fallback): hosted in a
    /// `Color.clear` the size of the hero, drawn with the hero gradient over
    /// it, and on iOS run under the HORIZONTAL safe area — and `topExtension`
    /// points up, under the status and navigation bars (the fiche, which has no
    /// title of its own up there; the screen measures its own top inset, since
    /// inside the scroll view the hero reports none).
    /// The hero's text stays in the page column; the hero's sizing driver must
    /// NOT clip, or it cuts the bleed back.
    ///
    /// - The `Color.clear` host is the hero RULE's sizing-driver pattern: a
    ///   `.fill` image reports its FILLED size, so clipped to its own frame it
    ///   outgrew a clamped hero (iPhone Duo closed in landscape: 332 pt of image
    ///   in a 289 pt hero) and spilled under the nav title and the first rail.
    /// - The GRADIENT is drawn on that host, never on the image: on the image
    ///   it ended where the image ended, below a clamped hero, and the hero met
    ///   the page with a hard edge instead of fading into it.
    /// - On iOS the image is anchored to the TOP of the box when it must be
    ///   cropped vertically (a landscape phone, an iPad): centred, a short hero
    ///   cut the heads off. A portrait phone crops sideways and is unchanged.
    ///   tvOS keeps the centred crop and its overscan margins.
    ///
    /// Without the bleed the image stopped dead at the safe-area edge while the
    /// rails below slid under it: the iPhone Duo's right-hand column (status +
    /// vertical tab bar) and the notch side of any iPhone in landscape.
    func heroBackdropBleed(topExtension: CGFloat = 0) -> some View {
        modifier(HeroBackdropBleed(topExtension: topExtension))
    }
}

/// See `heroBackdropBleed(topExtension:)`. Two mechanisms, because the inset
/// reaches the hero in two forms (measured on the iPhone Duo closed,
/// 2026-10-07):
/// - in portrait the right-hand column is a true safe area OUTSIDE the hero's
///   frame, and `.ignoresSafeArea` extends into it;
/// - in landscape the tab content is laid out 594 pt wide on a 678 pt window
///   and STILL reports an 84 pt trailing inset inside that frame, so there is
///   nothing for `.ignoresSafeArea` to extend into — the layer is widened by
///   the reported inset instead (negative padding) and draws past the frame.
private struct HeroBackdropBleed: ViewModifier {
    let topExtension: CGFloat
    #if os(iOS)
    @State private var reportedInsets = EdgeInsets()
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        Color.clear
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { reportedInsets = $0 }
            .overlay {
                Color.clear
                    .overlay(alignment: .top) { content }
                    .overlay { CinemaGradient.heroOverlay.allowsHitTesting(false) }
                    .ignoresSafeArea(edges: .horizontal)
                    .clipped()
                    .padding(.leading, -reportedInsets.leading)
                    .padding(.trailing, -reportedInsets.trailing)
                    .padding(.top, -topExtension)
            }
        #else
        Color.clear
            .overlay { content }
            .overlay { CinemaGradient.heroOverlay.allowsHitTesting(false) }
            .clipped()
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
    private var requestedURL: URL?
    /// The in-flight fetch — internal so a test can await it.
    private(set) var loadTask: Task<Void, Never>?
    /// The last fetch failed; the next window entry retries it — what
    /// `LazyImage` did on every appear, so a backdrop that failed on a flaky
    /// link heals on the next tab switch or pop instead of staying blank.
    private(set) var hasFailedLoad = false
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
    /// A repeated URL is a no-op: `updateUIView` runs on every parent update.
    func load(_ url: URL?) {
        guard url != requestedURL else { return }
        requestedURL = url
        startLoad()
    }

    private func startLoad() {
        loadTask?.cancel()
        loadTask = nil
        hasFailedLoad = false
        guard let url = requestedURL else {
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
            guard let self, !Task.isCancelled, self.requestedURL == url else { return }
            if let image {
                self.imageView.image = image
            } else {
                self.hasFailedLoad = true
            }
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
        if window != nil, hasFailedLoad { startLoad() }
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
