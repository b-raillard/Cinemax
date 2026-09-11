import Testing
@testable import Cinemax

/// `MotionEffects.isEnabled` is the one rule every animation in the app
/// answers to (it feeds `\.motionEffectsEnabled` at the root, the rainbow
/// accent tick and the sign-in dwell). Either switch turning motion off wins:
/// the system's Reduce Motion must stop the Home hero carousel without the
/// user having to find the app's own toggle as well.
@Suite("MotionEffects")
struct MotionEffectsTests {

    @Test("both on ⇒ motion")
    func appOnSystemOff() {
        #expect(MotionEffects.isEnabled(appToggle: true, systemReduceMotion: false))
    }

    @Test("system Reduce Motion wins over the app toggle")
    func systemReduceMotionWins() {
        #expect(!MotionEffects.isEnabled(appToggle: true, systemReduceMotion: true))
    }

    @Test("app toggle off stops motion on its own")
    func appToggleOff() {
        #expect(!MotionEffects.isEnabled(appToggle: false, systemReduceMotion: false))
    }

    @Test("both off ⇒ still off")
    func bothOff() {
        #expect(!MotionEffects.isEnabled(appToggle: false, systemReduceMotion: true))
    }
}
