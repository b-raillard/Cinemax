import SwiftUI
import CoreImage
import Nuke

/// What the text block of Home's and the library's heroes looks like over its
/// backdrop in LIGHT mode on iOS.
///
/// Those heroes draw no shade in light mode (`HeroBackdropShade`), so their
/// text stands straight on the image: the page's dark text vanished on a dark
/// backdrop (« Shaun le mouton », recette 2026-11-15). Three answers were
/// built and compared on the simulator — white text with a shadow, dark text
/// with a light halo, and the text following the image — and the owner chose
/// the last: over a dark backdrop the block takes the DARK-mode look (light
/// text, dark glass « Plus d'infos », a soft shadow), over a light one it keeps
/// the page's light tokens. Dark mode and tvOS never change.
enum HeroTextTone: Equatable, Sendable {
    /// The page's own tokens: dark text, light glass « Plus d'infos ».
    case standard
    /// The dark-mode look over a dark backdrop.
    case onDark

    /// The light-mode `onSurfaceVariant` and the dark-mode one. Deciding on
    /// these greys rather than the title's colours sets a stricter bar that
    /// tips the in-between images (a mid green, L ≈ 0.19) to the light text,
    /// which its shadow helps — on the title's colours « 0m » stayed dark and
    /// unreadable there.
    nonisolated static let darkText: UInt = 0x55585E
    nonisolated static let lightText: UInt = 0xACABAA

    /// The tone whose grey contrasts more with `red/green/blue`, the average
    /// colour (sRGB, 0…1) of the image under the text block. Flips around a
    /// luminance of 0.21 (#7D7D7D).
    nonisolated static func resolve(red: Double, green: Double, blue: Double) -> Self {
        let ground = AccentLabelContrast.luminance(red: red, green: green, blue: blue)
        let dark = AccentLabelContrast.contrast(AccentLabelContrast.luminance(hex: darkText), ground)
        let light = AccentLabelContrast.contrast(AccentLabelContrast.luminance(hex: lightText), ground)
        return light > dark ? .onDark : .standard
    }

    /// How the meta line (rating, year, genre) is drawn.
    struct MetaStyle: Equatable {
        /// `onSurface`, the title's colour, instead of the `onSurfaceVariant` grey.
        let usesPrimaryText: Bool
        /// A tight dark shadow under light text, for its small size.
        let sharpShadow: Bool
    }

    /// `tone`: the block's tone over an unshaded image, nil under a gradient
    /// (dark mode, tvOS, the fiche). Over an image the grey read far worse
    /// than the title beside it (Chernobyl, recette 2026-11-15).
    nonisolated static func metaStyle(over tone: Self?) -> MetaStyle {
        guard let tone else { return MetaStyle(usesPrimaryText: false, sharpShadow: false) }
        return MetaStyle(usesPrimaryText: true, sharpShadow: tone == .onDark)
    }

    /// The part of the SOURCE image (unit square, origin top-left) the text
    /// block sits on, or nil when either size is empty.
    ///
    /// The backdrop fills the hero (`CinemaLazyImage`, `.fill`): an image wider
    /// than the hero is cropped sideways and centred, a narrower one cropped
    /// vertically and anchored to the TOP (`heroBackdropBleed`). The text sits
    /// in the lower 45 % of the hero, over its left 80 %.
    nonisolated static func sampleRect(imageSize: CGSize, heroSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0, heroSize.width > 0, heroSize.height > 0 else { return nil }
        let imageAspect = imageSize.width / imageSize.height
        let heroAspect = heroSize.width / heroSize.height
        let visible: CGRect
        if imageAspect > heroAspect {
            let width = heroAspect / imageAspect
            visible = CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        } else {
            visible = CGRect(x: 0, y: 0, width: 1, height: imageAspect / heroAspect)
        }
        return CGRect(
            x: visible.minX,
            y: visible.minY + visible.height * 0.55,
            width: visible.width * 0.8,
            height: visible.height * 0.45
        )
    }

    /// One shared context: creating a `CIContext` is the expensive part.
    private nonisolated(unsafe) static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Measures the backdrop at `url` — the image the hero already shows, so
    /// Nuke serves it from its caches — and resolves the tone. Nil when the
    /// image cannot be had or measured.
    nonisolated static func measure(url: URL, heroSize: CGSize) async -> Self? {
        guard let image = try? await ImagePipeline.shared.image(for: ImageRequest(url: url)),
              let cgImage = image.cgImage else { return nil }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        guard let unit = sampleRect(imageSize: size, heroSize: heroSize) else { return nil }
        // Core Image's origin is bottom-left.
        let extent = CGRect(
            x: unit.minX * size.width,
            y: (1 - unit.maxY) * size.height,
            width: unit.width * size.width,
            height: unit.height * size.height
        )
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: CIImage(cgImage: cgImage),
            kCIInputExtentKey: CIVector(cgRect: extent)
        ]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return resolve(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}

extension EnvironmentValues {
    /// The hero text block's tone while it stands on an unshaded image
    /// (`heroAdaptiveText`), nil otherwise. Read by `heroMetaStyle()`.
    @Entry var heroTextTone: HeroTextTone?
}

extension View {
    /// The meta line of Home's or the library's hero (rating, year, genre):
    /// grey under a gradient, the title's colour over an image — see
    /// `HeroTextTone.metaStyle(over:)`.
    func heroMetaStyle() -> some View {
        modifier(HeroMetaStyle())
    }

    /// The text block of Home's or the library's hero follows its backdrop in
    /// light mode on iOS — see `HeroTextTone`. Apply it to the block filling
    /// the hero, so its size is the hero's.
    func heroAdaptiveText(backdropURL: URL?) -> some View {
        modifier(HeroAdaptiveText(url: backdropURL))
    }
}

private struct HeroAdaptiveText: ViewModifier {
    let url: URL?

    private struct MeasureKey: Equatable {
        let url: URL?
        let width: Int
        let height: Int
        let isLight: Bool
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var tone: HeroTextTone = .standard
    @State private var heroSize: CGSize = .zero

    func body(content: Content) -> some View {
        #if os(iOS)
        let onDark = colorScheme == .light && tone == .onDark
        content
            // Always set, never added or removed: a conditional modifier would
            // rebuild the block (and its buttons) every time the tone flips.
            .environment(\.colorScheme, onDark ? .dark : colorScheme)
            .environment(\.heroTextTone, colorScheme == .light ? tone : nil)
            .shadow(color: .black.opacity(onDark ? 0.35 : 0), radius: 6)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { heroSize = $0 }
            .task(id: MeasureKey(url: url, width: Int(heroSize.width), height: Int(heroSize.height),
                                 isLight: colorScheme == .light)) {
                guard colorScheme == .light, let url, heroSize.width > 0 else {
                    tone = .standard
                    return
                }
                // The previous tone stays until the new image is measured: the
                // carousel's next backdrop is usually already cached.
                if let measured = await HeroTextTone.measure(url: url, heroSize: heroSize) {
                    tone = measured
                }
            }
        #else
        content
        #endif
    }
}

private struct HeroMetaStyle: ViewModifier {
    @Environment(\.heroTextTone) private var tone

    func body(content: Content) -> some View {
        let style = HeroTextTone.metaStyle(over: tone)
        content
            .foregroundStyle(style.usesPrimaryText ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
            .shadow(color: .black.opacity(style.sharpShadow ? 0.6 : 0), radius: 1.5)
    }
}
