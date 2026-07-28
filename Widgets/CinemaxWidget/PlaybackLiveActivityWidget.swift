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

/// Progress bar + elapsed / remaining labels. While playing these are live
/// SwiftUI timer views (zero pushes); while paused they're static text.
private struct PlaybackProgressRow: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if let range = state.timerRange {
            VStack(spacing: 3) {
                if state.isPaused {
                    ProgressView(value: state.elapsed(at: .now), total: state.duration)
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.9))
                } else {
                    ProgressView(timerInterval: range, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.linear)
                    .tint(.white.opacity(0.9))
                }
                HStack {
                    elapsedLabel(range)
                    Spacer(minLength: 8)
                    remainingLabel(range)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder
    private func elapsedLabel(_ range: ClosedRange<Date>) -> some View {
        if state.isPaused {
            Text(playbackClock(state.elapsed(at: .now)))
        } else {
            Text(timerInterval: range, countsDown: false)
        }
    }

    @ViewBuilder
    private func remainingLabel(_ range: ClosedRange<Date>) -> some View {
        if state.isPaused {
            Text("-" + playbackClock(max(0, state.duration - state.elapsed(at: .now))))
        } else {
            Text(timerInterval: range, countsDown: true)
        }
    }
}

/// Compact/minimal Dynamic Island trailing slot: remaining time, or the state
/// glyph when the runtime is unknown.
private struct PlaybackRemainingPill: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if let range = state.timerRange {
            Group {
                if state.isPaused {
                    Text(playbackClock(max(0, state.duration - state.elapsed(at: .now))))
                } else {
                    Text(timerInterval: range, countsDown: true)
                }
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 52)
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
