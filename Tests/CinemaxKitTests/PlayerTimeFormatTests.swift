import Testing
@testable import Cinemax

/// `PlayerTimeFormat.ms(_:)` renders M:SS below one hour and H:MM:SS at or
/// above it, clamping negative inputs to zero. Expected strings below are
/// derived directly from the implementation (`%d:%02d` / `%d:%02d:%02d` with
/// integer division of milliseconds by 1000).
@Suite("PlayerTimeFormat")
struct PlayerTimeFormatTests {

    @Test("zero milliseconds formats as 0:00")
    func zero() {
        #expect(PlayerTimeFormat.ms(0) == "0:00")
    }

    @Test("negative input clamps to zero")
    func negative() {
        #expect(PlayerTimeFormat.ms(-1) == "0:00")
        #expect(PlayerTimeFormat.ms(-5_000) == "0:00")
        #expect(PlayerTimeFormat.ms(Int32.min) == "0:00")
    }

    @Test("sub-minute values truncate to whole seconds")
    func subMinute() {
        // 59_999 ms → 59 s (integer division, no rounding up)
        #expect(PlayerTimeFormat.ms(59_999) == "0:59")
    }

    @Test("exactly one minute")
    func oneMinute() {
        #expect(PlayerTimeFormat.ms(60_000) == "1:00")
    }

    @Test("hour boundary: 59:59 stays M:SS, 1:00:00 switches to H:MM:SS")
    func hourBoundary() {
        #expect(PlayerTimeFormat.ms(3_599_999) == "59:59")
        #expect(PlayerTimeFormat.ms(3_600_000) == "1:00:00")
    }

    @Test("minutes and seconds are zero-padded above one hour")
    func zeroPadding() {
        // 3_661_000 ms → 3661 s → 1 h, 1 m, 1 s
        #expect(PlayerTimeFormat.ms(3_661_000) == "1:01:01")
        // 7_322_000 ms → 7322 s → 2 h, 2 m, 2 s
        #expect(PlayerTimeFormat.ms(7_322_000) == "2:02:02")
    }

    @Test("Int32.max formats without overflow")
    func largeValue() {
        // 2_147_483_647 ms → 2_147_483 s → 596 h, 31 m, 23 s
        #expect(PlayerTimeFormat.ms(Int32.max) == "596:31:23")
    }
}
