#if canImport(ActivityKit)
import ActivityKit
import SwiftUI
import WidgetKit

// Live Activity for the current playback session: Lock Screen banner + Dynamic
// Island. Registered in `CinemaxWidgetBundle` (CinemaxWidget.swift).
//
// Progress is rendered CLIENT-SIDE from `ContentState.startedAt` via
// `Text(timerInterval:)` / `ProgressView(timerInterval:)` — the app pushes an
// update only on play/pause, seek, item change and stop (see
// `PlaybackActivityAttributes.ContentState`). Never add a per-second push here.
//
// v1 has NO interactive controls by design. Pause/play buttons via
// `LiveActivityIntent` (+ an App Intents extension target) are explicitly v2.
//
// Styling mirrors `PosterRailWidgetView`: black gradient container, white-on-dark
// with opacity tiers, `film` glyph placeholder. Strings are inline
// `french ? … : …` — the extension can't link the app's `LocalizationManager`
// (documented widget RULE).

private var isFrench: Bool {
    Locale.preferredLanguages.first?.hasPrefix("fr") ?? true
}

/// HH:MM:SS / MM:SS. Local copy of the app's `PlayerTimeFormat` — the extension
/// links nothing of ours.
private func playbackClock(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

private func deepLink(itemId: String) -> URL? {
    URL(string: "cinemax://item/\(itemId)")
}

/// "2×" / "1.25×" / "0.5×" — shown in place of the elapsed label while playback
/// runs off-speed (see `PlaybackProgressRow.leadingLabel`).
private func rateLabel(_ rate: Double) -> String {
    let rounded = (rate * 100).rounded() / 100
    let digits = rounded == rounded.rounded()
        ? String(format: "%.0f", rounded)
        : String(format: "%g", rounded)
    return "\(digits)×"
}

// MARK: - Shared pieces

/// Square film-reel tile standing in for the poster. The extension can't reach
/// the app's authenticated image pipeline from an activity update, and a Live
/// Activity payload is size-capped (4 KB) — so no artwork in v1.
private struct PlaybackGlyphTile: View {
    var size: CGFloat = 42
    var isPaused: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size / 5)
                .fill(.white.opacity(0.10))
            Image(systemName: isPaused ? "pause.fill" : "film.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: size, height: size)
    }
}

private struct PlaybackHeadline: View {
    let attributes: PlaybackActivityAttributes
    let state: PlaybackActivityAttributes.ContentState

    private var status: String {
        if state.isPaused { return isFrench ? "En pause" : "Paused" }
        return isFrench ? "Lecture en cours" : "Now playing"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(status.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))
            Text(attributes.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !attributes.subtitle.isEmpty {
                Text(attributes.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }
    }
}

/// Progress bar + elapsed / remaining labels.
///
/// `state.timerRange` is a **wall-clock** range anchored to the current rate, so
/// while playing the bar and the countdown are live SwiftUI timer views at ANY
/// speed and cost zero pushes. It is `nil` while paused, which selects the
/// static rendering below.
private struct PlaybackProgressRow: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if state.duration > 0 {
            VStack(spacing: 3) {
                bar
                HStack {
                    leadingLabel
                    Spacer(minLength: 8)
                    trailingLabel
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder
    private var bar: some View {
        if let range = state.timerRange {
            ProgressView(timerInterval: range, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(.white.opacity(0.9))
        } else {
            ProgressView(value: state.progressFraction(at: .now))
                .progressViewStyle(.linear)
                .tint(.white.opacity(0.9))
        }
    }

    /// Elapsed, live, while playing at 1×. **Off-speed swaps in a rate badge**:
    /// the only live timer SwiftUI offers counts wall-clock, which at 2× is not
    /// the media playhead — showing one there would simply be a wrong number.
    @ViewBuilder
    private var leadingLabel: some View {
        if state.isOffSpeed {
            Text(rateLabel(state.rate)).fontWeight(.bold)
        } else if let range = state.timerRange {
            Text(timerInterval: range, countsDown: false)
        } else {
            Text(playbackClock(state.elapsed(at: .now)))
        }
    }

    /// Time until the media ends. Correct at every rate — the range is anchored
    /// in wall-clock, so at 2× it counts down twice as fast, which is exactly
    /// how much longer the user actually has to wait.
    @ViewBuilder
    private var trailingLabel: some View {
        if let range = state.timerRange {
            Text(timerInterval: range, countsDown: true)
        } else {
            Text("-" + playbackClock(max(0, state.duration - state.elapsed(at: .now))))
        }
    }
}

/// Compact/minimal Dynamic Island trailing slot: time remaining, or the state
/// glyph when the runtime is unknown.
private struct PlaybackRemainingPill: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if state.duration > 0 {
            Group {
                if let range = state.timerRange {
                    Text(timerInterval: range, countsDown: true)
                } else {
                    Text(playbackClock(max(0, state.duration - state.elapsed(at: .now))))
                }
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            // Wide enough for "1:23:45": a film with over an hour left was
            // truncated at 52pt. `minimumScaleFactor` absorbs the rest.
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 66)
        } else {
            Image(systemName: state.isPaused ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .bold))
        }
    }
}

// MARK: - Lock Screen

struct PlaybackLiveActivityLockScreenView: View {
    let attributes: PlaybackActivityAttributes
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PlaybackGlyphTile(isPaused: state.isPaused)
                PlaybackHeadline(attributes: attributes, state: state)
                Spacer(minLength: 0)
            }
            PlaybackProgressRow(state: state)
        }
        .padding(.vertical, 2)
        .activityBackgroundTint(.black)
        .activitySystemActionForegroundColor(.white)
        .widgetURL(deepLink(itemId: attributes.itemId))
    }
}

// MARK: - Widget

struct CinemaxPlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            PlaybackLiveActivityLockScreenView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PlaybackGlyphTile(size: 36, isPaused: context.state.isPaused)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PlaybackRemainingPill(state: context.state)
                        .foregroundStyle(.white.opacity(0.75))
                }
                DynamicIslandExpandedRegion(.center) {
                    PlaybackHeadline(attributes: context.attributes, state: context.state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PlaybackProgressRow(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "film.fill")
                    .font(.system(size: 13, weight: .semibold))
            } compactTrailing: {
                PlaybackRemainingPill(state: context.state)
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "film.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .widgetURL(deepLink(itemId: context.attributes.itemId))
            .keylineTint(.white)
        }
    }
}
#endif
