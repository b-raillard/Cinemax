import AppIntents
import SwiftUI
import WidgetKit

/// « Reprendre la lecture » as a Control Center / Action-button / Lock Screen
/// control, plus the intent it runs.
///
/// **RULE — the intent a control runs must compile INSIDE the extension, and
/// `ResumePlaybackIntent` cannot.** That one imports CinemaxKit and JellyfinAPI,
/// resolves its session through `IntentSessionProvider` and routes through
/// `AppState` — none of which the widget target links, by the "extensions do NOT
/// link CinemaxKit" rule (widget memory budget). `ControlWidgetButton(action:)`
/// needs the intent TYPE visible in the extension, so `openAppWhenRun` alone is
/// not enough to reuse the app's intent: the type has to exist on both sides.
///
/// So this shim is shared by SOURCE with the app — the same mechanism
/// `PlaybackActivityAttributes` uses, and the only one available — and its BODY
/// is compiled per target through `CINEMAX_APP` (defined on the app target
/// only): the app forwards to the real intent, which stays the single authority
/// for what "resume" means (session bootstrap, the `privacy.maxContentAge` cap,
/// which item, and the routing through `MediaDetailScreen`); the extension gets
/// a body that satisfies the compiler and never runs, because `openAppWhenRun`
/// performs the intent in the APP process.
///
/// **RULE — an intent's `title` / `description` must be STRING LITERALS, even
/// here.** `appintentsmetadataprocessor` extracts them statically at build time
/// and refuses anything else outright: « 'LocalizedStringResource' must be
/// initialized with a call to its initializer or a string literal », which fails
/// the whole target's metadata export, not just this file. So they are keys, like
/// every other intent in the app — resolved from the APP's catalogue, which is
/// where they are read (Shortcuts, Siri, the intent's accessibility label).
/// The CONTROL's own gallery strings below are NOT intent metadata, so they keep
/// the widget's inline `french ? … : …` form — the extension bundles no
/// `.lproj`, and a key there would render as the key.
struct ResumeControlIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.resumeControl.title"
    static let description = IntentDescription("intent.resumeControl.description")
    /// The whole design rests on this: the system launches the app and performs
    /// the intent THERE, which is what lets the app-side branch below reach the
    /// real intent while the extension's copy stays inert.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if CINEMAX_APP
        // One authority, not a copy: whatever `ResumePlaybackIntent` decides
        // (nothing to resume, not signed in, which episode) holds here too.
        _ = try await ResumePlaybackIntent().perform()
        #endif
        return .result()
    }
}

/// Control Center / Action button / Lock Screen control.
struct CinemaxResumeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.cinemax.ios.control.resume") {
            ControlWidgetButton(action: ResumeControlIntent()) {
                Label(
                    ResumeControlStrings.isFrench ? "Reprendre" : "Resume",
                    systemImage: "play.fill"
                )
            }
        }
        .displayName(
            LocalizedStringResource(
                stringLiteral: ResumeControlStrings.isFrench ? "Reprendre la lecture" : "Continue watching"
            )
        )
        .description(
            LocalizedStringResource(
                stringLiteral: ResumeControlStrings.isFrench
                    ? "Reprend le dernier titre commencé."
                    : "Resumes the last thing you were watching."
            )
        )
    }
}

/// The language test, once. `static let` rather than a computed property because
/// Swift 6 rejects a mutable nonisolated static and an intent's statics must be
/// constants (see the intent-statics RULE).
enum ResumeControlStrings {
    static let isFrench = Locale.preferredLanguages.first?.hasPrefix("fr") ?? true
}
