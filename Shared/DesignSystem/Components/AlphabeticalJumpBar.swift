/// The alphabet both jump affordances offer.
///
/// Outside the `#if` below on purpose: tvOS draws a horizontal strip of
/// focusable chips (`MovieLibraryScreen.tvLetterStrip`) because a vertical bar
/// tracked with a thumb is meaningless on a remote — but the two must offer the
/// SAME set, or a letter reachable on one platform would be missing on the
/// other.
enum AlphabeticalJump {
    /// "#" covers items that begin with a digit or symbol.
    static let letters: [String] = {
        var list = ["#"]
        list.append(contentsOf: (UnicodeScalar("A").value...UnicodeScalar("Z").value)
            .compactMap { UnicodeScalar($0).map { String(Character($0)) } })
        return list
    }()

    /// The letter a VoiceOver adjust gesture lands on: one step along
    /// `letters`, clamped at both ends (swiping past Z stays on Z).
    static func stepped(from letter: String, by offset: Int) -> String {
        guard let index = letters.firstIndex(of: letter) else { return letters[0] }
        return letters[min(max(index + offset, 0), letters.count - 1)]
    }
}

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

    /// The letters rendered. See `AlphabeticalJump.letters`.
    private static let letters = AlphabeticalJump.letters

    @State private var lastFired: String?
    /// The letter VoiceOver's adjust gesture moves from — its spoken value.
    @State private var spokenLetter = AlphabeticalJump.letters[0]
    @Environment(LocalizationManager.self) private var loc

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
        // It was `accessibilityHidden`, with nothing in its place: VoiceOver
        // users had no way to jump through a 500-film library (audit §5,
        // lot 9). One adjustable element instead of 27 tiny targets — swipe
        // up / down moves one letter and jumps there, as Contacts does.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized("library.jumpBar.a11y"))
        .accessibilityValue(spokenLetter == "#" ? loc.localized("library.jumpBar.digits") : spokenLetter)
        .accessibilityHint(loc.localized("library.jumpBar.hint"))
        .accessibilityAdjustableAction { direction in
            let offset: Int
            switch direction {
            case .increment: offset = 1
            case .decrement: offset = -1
            @unknown default: return
            }
            spokenLetter = AlphabeticalJump.stepped(from: spokenLetter, by: offset)
            fire(spokenLetter)
        }
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
