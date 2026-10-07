#if os(iOS)
import UIKit

/// The blocks of the player's deck in table posture (iPhone Duo half-folded,
/// portrait — mockup « Pupitre »). Configurations only: the buttons, their
/// actions and their VoiceOver labels stay those of the regular HUD.
enum TabletopHUDStyle {
    static let blockFill = UIColor.white.withAlphaComponent(0.075)
    static let emphasizedFill = UIColor.white.withAlphaComponent(0.13)
    static let cornerRadius: CGFloat = 20

    static func block(symbol: String, pointSize: CGFloat, title: String? = nil,
                      subtitle: String? = nil, emphasized: Bool = false) -> UIButton.Configuration {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: symbol,
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        cfg.baseForegroundColor = .white
        cfg.background.backgroundColor = emphasized ? emphasizedFill : blockFill
        cfg.background.cornerRadius = cornerRadius
        cfg.cornerStyle = .fixed
        if let title {
            cfg.imagePlacement = .top
            cfg.imagePadding = 5
            cfg.title = title
            cfg.titleAlignment = .center
            cfg.titleLineBreakMode = .byTruncatingTail
            cfg.titleTextAttributesTransformer = .init { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 12, weight: .semibold)
                return attributes
            }
            cfg.subtitle = subtitle
            cfg.subtitleLineBreakMode = .byTruncatingTail
            cfg.subtitleTextAttributesTransformer = .init { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 11)
                attributes.foregroundColor = UIColor.white.withAlphaComponent(0.62)
                return attributes
            }
        }
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
        return cfg
    }

    /// Open: the icon takes the accent. Locked: the icon stays white — the
    /// block never takes the accent, it would stay lit for good.
    static func lock(locked: Bool, accent: UIColor) -> UIButton.Configuration {
        var cfg = block(symbol: locked ? "lock.fill" : "lock.open.fill", pointSize: 20)
        cfg.baseForegroundColor = locked ? .white : accent
        return cfg
    }

    /// The film bar: thumbnail · title · detail line, with the menu chevron.
    static func titleBlock(title: String, subtitle: String?, thumbnail: UIImage?) -> UIButton.Configuration {
        var cfg = UIButton.Configuration.plain()
        cfg.baseForegroundColor = .white
        cfg.background.backgroundColor = blockFill
        cfg.background.cornerRadius = cornerRadius
        cfg.cornerStyle = .fixed
        cfg.title = title
        cfg.titleLineBreakMode = .byTruncatingTail
        cfg.titleTextAttributesTransformer = .init { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 17, weight: .semibold)
            return attributes
        }
        cfg.subtitle = subtitle
        cfg.subtitleLineBreakMode = .byTruncatingTail
        cfg.subtitleTextAttributesTransformer = .init { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 13)
            attributes.foregroundColor = UIColor.white.withAlphaComponent(0.62)
            return attributes
        }
        cfg.image = thumbnail.map(roundedThumbnail)
        cfg.imagePlacement = .leading
        cfg.imagePadding = 14
        cfg.indicator = .popup
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 16)
        return cfg
    }

    /// 82 × 46 pt, 10 pt corners — the film bar's thumbnail.
    private static func roundedThumbnail(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 82, height: 46)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10).addClip()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
#endif
