#if os(iOS)
import SwiftUI
import UIKit

/// Right-edge vertical index strip, Contacts.app-style: tap or drag over a letter
/// to jump the parent scroll view to the matching item. Only used on iOS — tvOS
/// focus navigation already handles this naturally via remote.
struct AlphabeticalJumpBar: View {
    let accent: Color
    /// Returns whether the tap actually led somewhere — the haptic follows that
    /// answer. See `fire(_:)`.
    let onSelect: (String) -> Bool

    /// The letters rendered. "#" covers items that begin with a digit or symbol.
    private static let letters: [String] = {
        var list = ["#"]
        list.append(contentsOf: (UnicodeScalar("A").value...UnicodeScalar("Z").value)
            .compactMap { UnicodeScalar($0).map { String(Character($0)) } })
        return list
    }()

    @State private var lastFired: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: CinemaScale.pt(11), weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 14)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        fire(letter)
                    }
            }
        }
        .padding(.vertical, 6)
        .background(
            Capsule().fill(.ultraThinMaterial)
        )
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Use the proportion of the drag y to pick a letter — lets the user
                    // slide their finger up/down without lifting.
                    let totalHeight = CGFloat(Self.letters.count) * 14 + 12
                    let clampedY = max(0, min(value.location.y, totalHeight))
                    let index = Int(clampedY / 14)
                    guard index >= 0 && index < Self.letters.count else { return }
                    let letter = Self.letters[index]
                    if letter != lastFired {
                        fire(letter)
                    }
                }
                .onEnded { _ in
                    lastFired = nil
                }
        )
        .accessibilityHidden(true)
    }

    private func fire(_ letter: String) {
        lastFired = letter
        // The haptic follows the outcome; it never precedes it. Firing up front
        // made a letter that led nowhere FEEL like it had been taken into
        // account — the worst possible signal on a bar that, before the grid
        // learned to re-anchor, could not reach most of its own alphabet.
        if onSelect(letter) {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
#endif
