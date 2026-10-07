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

    @Test("entering table mode with the deck locked reveals a HUD hidden in the other mode")
    func lockedDeckRevealedOnEntry() {
        #expect(PlayerPostureLayout.revealsOnModeChange(mode: .tabletop, locked: true, visible: false) == true)
        #expect(PlayerPostureLayout.revealsOnModeChange(mode: .tabletop, locked: true, visible: true) == false)
        #expect(PlayerPostureLayout.revealsOnModeChange(mode: .tabletop, locked: false, visible: false) == false)
        #expect(PlayerPostureLayout.revealsOnModeChange(mode: .regular, locked: true, visible: false) == false)
    }
}

#if os(iOS)
import UIKit

/// The deck's blocks (table mode). The lock never lights its block: open, only
/// its icon takes the accent; locked, the icon stays white — a deck kept on
/// screen for good must not glow (user decision, 2026-10-07).
@Suite("TabletopHUDStyle")
@MainActor
struct TabletopHUDStyleTests {
    private let accent = UIColor.systemGreen

    @Test("open lock: accent icon, ordinary block")
    func openLock() {
        let cfg = TabletopHUDStyle.lock(locked: false, accent: accent)
        #expect(cfg.baseForegroundColor == accent)
        #expect(cfg.background.backgroundColor == TabletopHUDStyle.blockFill)
    }

    @Test("closed lock: white icon, ordinary block")
    func closedLock() {
        let cfg = TabletopHUDStyle.lock(locked: true, accent: accent)
        #expect(cfg.baseForegroundColor == .white)
        #expect(cfg.background.backgroundColor == TabletopHUDStyle.blockFill)
    }

    @Test("play block is the emphasised one")
    func emphasis() {
        #expect(TabletopHUDStyle.block(symbol: "play.fill", pointSize: 54, emphasized: true).background.backgroundColor
                == TabletopHUDStyle.emphasizedFill)
        #expect(TabletopHUDStyle.block(symbol: "xmark", pointSize: 18).background.backgroundColor
                == TabletopHUDStyle.blockFill)
    }
}
#endif

#if os(iOS)
/// The halo's geometry and the film bar's definition label (table mode).
@Suite("TabletopHalo")
struct TabletopHaloTests {
    @Test("definition shown from the playing video track's width")
    func quality() {
        #expect(TabletopHalo.qualityLabel(width: 4096) == "4K")
        #expect(TabletopHalo.qualityLabel(width: 3840) == "4K")
        #expect(TabletopHalo.qualityLabel(width: 1920) == "1080p")
        #expect(TabletopHalo.qualityLabel(width: 1280) == "720p")
        #expect(TabletopHalo.qualityLabel(width: 720) == "SD")
    }

    @Test("picture height, aspect-fit in the upper half")
    func pictureHeight() {
        let half = CGSize(width: 700, height: 500)
        #expect(TabletopHalo.pictureHeight(viewSize: half, videoAspect: 2.35) == (700 / 2.35).rounded())
        #expect(TabletopHalo.pictureHeight(viewSize: half, videoAspect: 1.0) == 500)
        let fallback = TabletopHalo.pictureHeight(viewSize: half, videoAspect: nil)
        let expected: CGFloat = (CGFloat(700) / (16.0 / 9.0)).rounded()
        #expect(fallback == expected, "\(fallback) vs \(expected)")
    }

    @Test("mirror offset puts the reflected picture `gap` below the fold")
    func mirrorOffset() {
        // Centre-relative mirror y′ = −y + k: the picture's bottom edge
        // (y = picH / 2) must land at h / 2 + gap.
        let k = TabletopHalo.mirrorOffset(viewHeight: 500, pictureHeight: 298, gapBelowFold: 24)
        #expect(-(298.0 / 2) + k == 500.0 / 2 + 24)
    }
}
#endif
