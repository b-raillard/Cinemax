import Testing
@testable import CinemaxKit

@Suite("OfflineFeatureFlag marker round-trip")
struct OfflineFeatureFlagTests {
    @Test("Absent CSS reads as disabled (fail-safe default)")
    func absentIsDisabled() {
        #expect(!OfflineFeatureFlag.isEnabled(customCss: nil))
        #expect(!OfflineFeatureFlag.isEnabled(customCss: ""))
        #expect(!OfflineFeatureFlag.isEnabled(customCss: ".login { color: red; }"))
    }

    @Test("Enable on empty CSS writes just the marker")
    func enableOnEmpty() {
        let css = OfflineFeatureFlag.applying(enabled: true, to: nil)
        #expect(css == OfflineFeatureFlag.markerLine)
        #expect(OfflineFeatureFlag.isEnabled(customCss: css))
    }

    @Test("Enable preserves existing admin CSS")
    func enablePreservesCss() {
        let admin = ".login { color: red; }\n.button { border: 0; }"
        let css = OfflineFeatureFlag.applying(enabled: true, to: admin)
        #expect(OfflineFeatureFlag.isEnabled(customCss: css))
        #expect(css.contains(admin))
    }

    @Test("Disable strips the marker and keeps admin CSS")
    func disableStripsMarker() {
        let admin = ".login { color: red; }"
        let enabled = OfflineFeatureFlag.applying(enabled: true, to: admin)
        let disabled = OfflineFeatureFlag.applying(enabled: false, to: enabled)
        #expect(!OfflineFeatureFlag.isEnabled(customCss: disabled))
        #expect(disabled == admin)
    }

    @Test("Disable strips a hand-formatted marker line")
    func disableStripsHandEditedMarker() {
        let css = "/*   cinemax:offline-downloads=on   */\n.x { }"
        let disabled = OfflineFeatureFlag.applying(enabled: false, to: css)
        #expect(!OfflineFeatureFlag.isEnabled(customCss: disabled))
        #expect(disabled.contains(".x { }"))
    }

    @Test("Enable is idempotent — no duplicate markers")
    func enableIdempotent() {
        let once = OfflineFeatureFlag.applying(enabled: true, to: ".x { }")
        let twice = OfflineFeatureFlag.applying(enabled: true, to: once)
        #expect(once == twice)
    }
}
