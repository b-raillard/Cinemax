import SwiftUI

struct CastCircle: View {
    let name: String
    var role: String? = nil
    var imageURL: URL? = nil

    private let size: CGFloat = 80

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            CinemaLazyImage(
                url: imageURL,
                fallbackIcon: "person.fill",
                fallbackBackground: CinemaColor.surfaceContainerHigh
            )
            .frame(width: size, height: size)
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

#if DEBUG
#Preview("CastCircle — fallback and with role") {
    HStack(spacing: CinemaSpacing.spacing3) {
        CastCircle(name: "Jane Doe", role: "Director")
        CastCircle(name: "John Smith")
    }
    .padding(CinemaSpacing.spacing4)
    .background(CinemaColor.surfaceContainerLowest)
}
#endif
