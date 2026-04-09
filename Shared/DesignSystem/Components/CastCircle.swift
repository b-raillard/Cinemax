import SwiftUI
import NukeUI

struct CastCircle: View {
    let name: String
    var role: String? = nil
    var imageURL: URL? = nil

    private let size: CGFloat = 80

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            LazyImage(url: imageURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "person.fill")
                        .font(.title2)
                        .foregroundStyle(CinemaColor.outlineVariant)
                }
            }
            .frame(width: size, height: size)
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(Circle())

            Text(name)
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurface)
                .lineLimit(1)

            if let role {
                Text(role)
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
            }
        }
        .frame(width: size + 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([name, role].compactMap { $0 }.joined(separator: ", "))
    }
}
