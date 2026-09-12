import Foundation

/// Subtitle appearance on the VLC path: colour, outline, background (#162).
///
/// **Why these are libVLC ARGUMENTS and not API calls.** libVLC's public C API
/// exposes exactly two subtitle knobs — `libvlc_video_set_spu_text_scale` (the
/// existing size setting) and `libvlc_video_set_spu_delay`. Appearance lives in
/// the `freetype` text-renderer module's config items, which are set as
/// instance command-line arguments; there is nothing for SwiftVLC to "wrap".
/// Measured on the vendored `libvlc.xcframework` (libVLC 4.0.6, `tvos-arm64`):
/// every option name below exists verbatim in the binary, and `nm` lists exactly
/// two compiled text renderers — `freetype` and `tdummy` (the null one) — with no
/// CoreText module entry point, so freetype really is what draws subtitles and
/// these options land on the module that runs.
///
/// **RULE — the default configuration emits NO arguments.** `libVLCArguments` is
/// empty unless the user has changed something, which is what lets the player
/// keep using `VLCInstance.shared`: a custom instance costs a plugin scan AND a
/// second log-stream subscription (see `VLCEngineLog.install(on:)`). So the whole
/// feature costs nothing at all for anybody who never opens the setting, and the
/// instance swap only happens for someone who opted in.
///
/// **RULE — arguments are per-INSTANCE, so a change applies at the NEXT player
/// creation, never to the player on screen.** The settings row says so; do not
/// try to "fix" it by mutating a live instance, which libVLC does not support.
struct SubtitleStyleOptions: Equatable {
    var color: SubtitleColorOption
    var outline: SubtitleOutlineOption
    var background: SubtitleBackgroundOption

    /// The engine's own defaults: white text, freetype's normal outline, no
    /// background box. Kept in step with `SettingsKey.Default`.
    static let engineDefault = Self(
        color: .white,
        outline: .normal,
        background: .none
    )

    /// Reads the three stored preferences, falling back to the engine default
    /// for an absent or unrecognised value.
    static func current(defaults: UserDefaults = .standard) -> Self {
        Self(
            color: SubtitleColorOption(rawValue: defaults.string(forKey: SettingsKey.subtitleColor) ?? "")
                ?? engineDefault.color,
            outline: SubtitleOutlineOption(rawValue: defaults.string(forKey: SettingsKey.subtitleOutline) ?? "")
                ?? engineDefault.outline,
            background: SubtitleBackgroundOption(rawValue: defaults.string(forKey: SettingsKey.subtitleBackground) ?? "")
                ?? engineDefault.background
        )
    }

    var isEngineDefault: Bool { self == Self.engineDefault }

    /// libVLC instance arguments for this configuration — empty when nothing has
    /// been changed (see the RULE above).
    ///
    /// Colour is passed as a DECIMAL integer. The module's own help text calls it
    /// "an hexadecimal (like HTML colors)", but the underlying config item is an
    /// integer, and a decimal literal cannot be misread by the argument parser
    /// the way a bare `FFFF00` could.
    var libVLCArguments: [String] {
        guard !isEngineDefault else { return [] }
        var arguments = [
            "--freetype-color=\(color.rgb)",
            // Opacity is 0…255 in every freetype option (measured: the binary's
            // help strings read "Text opacity", "Outline opacity", "Background
            // opacity"). Text stays fully opaque; the user's choices only move
            // the outline and the box.
            "--freetype-opacity=255",
            "--freetype-outline-opacity=\(outline.opacity)",
            "--freetype-background-opacity=\(background.opacity)"
        ]
        // Thickness is a CHOICE item whose labels the binary exposes (None /
        // Thin / Normal / Thick) but whose integers it does not. It is therefore
        // sent only as a refinement ON TOP of the opacity above: if these values
        // are wrong, an outline still appears and disappears correctly — the
        // control degrades to on/off rather than dying. Worth confirming on
        // device that `normal` and `thick` differ visibly.
        if outline != .normal {
            arguments.append("--freetype-outline-thickness=\(outline.thickness)")
        }
        // A box is only drawn when it is asked for, and it is always black:
        // a coloured box behind coloured text is a legibility trap, not a choice.
        if background != .none {
            arguments.append("--freetype-background-color=0")
        }
        return arguments
    }
}

/// What a settings picker needs from one of the three appearance enums, so both
/// platforms render them through ONE generic row each instead of six near-copies.
protocol SubtitleStylePickerOption: CaseIterable, Identifiable, RawRepresentable where RawValue == String {
    var localizationKey: String { get }
}

/// Text colour. Three high-contrast choices rather than a full picker: these are
/// the ones that stay legible over arbitrary video, and every extra entry is one
/// more thing nobody can verify on device.
enum SubtitleColorOption: String, SubtitleStylePickerOption {
    case white
    case yellow
    case cyan

    var id: String { rawValue }

    /// RGB as the integer the `freetype-color` config item takes.
    var rgb: Int {
        switch self {
        case .white:  return 0xFF_FF_FF
        case .yellow: return 0xFF_FF_00
        case .cyan:   return 0x00_FF_FF
        }
    }

    var localizationKey: String { "subtitleColor.\(rawValue)" }
}

/// Outline around each glyph — what actually makes white text readable over a
/// bright scene.
enum SubtitleOutlineOption: String, SubtitleStylePickerOption {
    case none
    case normal
    case thick

    var id: String { rawValue }

    /// freetype's `Outline thickness` choice item. See the note in
    /// `libVLCArguments` about why this is a refinement, not the mechanism.
    var thickness: Int {
        switch self {
        case .none:   return 0
        case .normal: return 4
        case .thick:  return 6
        }
    }

    /// 0 hides the outline whatever the thickness — this is the value the
    /// on/off behaviour actually rests on.
    var opacity: Int {
        switch self {
        case .none:            return 0
        case .normal, .thick:  return 255
        }
    }

    var localizationKey: String { "subtitleOutline.\(rawValue)" }
}

/// Box drawn behind the text. Always black (see `libVLCArguments`).
enum SubtitleBackgroundOption: String, SubtitleStylePickerOption {
    case none
    case translucent
    case opaque

    var id: String { rawValue }

    var opacity: Int {
        switch self {
        case .none:        return 0
        case .translucent: return 160
        case .opaque:      return 255
        }
    }

    var localizationKey: String { "subtitleBackground.\(rawValue)" }
}
