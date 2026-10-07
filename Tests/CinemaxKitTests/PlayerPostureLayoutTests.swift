import Testing
import CoreGraphics
@testable import Cinemax

/// The player's « table » mode: video on the upper screen, control deck on the
/// lower one — only for an iPhone Duo half-open AND in portrait.
@Suite("PlayerPostureLayout")
struct PlayerPostureLayoutTests {
    private let portrait = CGSize(width: 703, height: 1000)
    private let landscape = CGSize(width: 1000, height: 703)

    @Test("half-open in portrait: table mode")
    func partiallyOpenPortrait() {
        #expect(PlayerPostureLayout.mode(hinge: .partiallyOpen, viewSize: portrait) == .tabletop)
    }

    @Test("half-open in landscape (book posture): regular player")
    func partiallyOpenLandscape() {
        #expect(PlayerPostureLayout.mode(hinge: .partiallyOpen, viewSize: landscape) == .regular)
    }

    @Test("open, closed or unknown: regular player", arguments: [HingeReading.fullyOpen, .closed, .unknown])
    func otherReadingsAreRegular(_ reading: HingeReading) {
        #expect(PlayerPostureLayout.mode(hinge: reading, viewSize: portrait) == .regular)
        #expect(PlayerPostureLayout.mode(hinge: reading, viewSize: landscape) == .regular)
    }

    @Test("square or empty view: regular player")
    func degenerateSizes() {
        #expect(PlayerPostureLayout.mode(hinge: .partiallyOpen, viewSize: CGSize(width: 700, height: 700)) == .regular)
        #expect(PlayerPostureLayout.mode(hinge: .partiallyOpen, viewSize: .zero) == .regular)
    }

    @Test("an update without a hinge keeps the last known reading")
    func nilKeepsPrevious() {
        #expect(PlayerPostureLayout.reading(previous: .partiallyOpen, update: nil) == .partiallyOpen)
        #expect(PlayerPostureLayout.reading(previous: .unknown, update: nil) == .unknown)
    }

    @Test("a real update replaces the reading")
    func updateReplaces() {
        #expect(PlayerPostureLayout.reading(previous: .partiallyOpen, update: .fullyOpen) == .fullyOpen)
        #expect(PlayerPostureLayout.reading(previous: .unknown, update: .closed) == .closed)
    }

    @Test("locked deck in table mode: a tap does not hide it")
    func lockedTapDoesNotHide() {
        #expect(PlayerPostureLayout.tapHides(mode: .tabletop, locked: true) == false)
        #expect(PlayerPostureLayout.tapHides(mode: .tabletop, locked: false) == true)
        #expect(PlayerPostureLayout.tapHides(mode: .regular, locked: true) == true)
    }

    @Test("the lock only stops auto-hide in table mode")
    func lockOnlyMattersInTabletop() {
        #expect(PlayerPostureLayout.autoHides(mode: .tabletop, locked: true) == false)
        #expect(PlayerPostureLayout.autoHides(mode: .tabletop, locked: false) == true)
        #expect(PlayerPostureLayout.autoHides(mode: .regular, locked: true) == true)
        #expect(PlayerPostureLayout.autoHides(mode: .regular, locked: false) == true)
    }
}
