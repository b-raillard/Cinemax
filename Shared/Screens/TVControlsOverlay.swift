#if os(tvOS)
import SwiftUI
import CinemaxKit

// MARK: - Overlay View

/// Top-level overlay. Only observes `state.isBuffering` and `state.showControls`.
/// Time-dependent and track-dependent rendering is delegated to isolated sub-views
/// so that the frequent currentTime updates do not re-render the Menu buttons.
struct TVPlayerOverlayView: View {
    let state: TVPlayerState
    let info: JellyfinAPIClient.PlaybackInfo
    let onPlayPause: () -> Void
    let onSeek: (Double) -> Void
    let onAudioChange: (Int?) -> Void
    let onSubtitleChange: (Int?) -> Void
    let onDismiss: () -> Void
    let onInteraction: () -> Void
    let onPreviousEpisode: () -> Void
    let onNextEpisode: () -> Void

    var body: some View {
        // Accesses only state.isBuffering + state.showControls — re-renders only on those.
        ZStack {
            if state.isBuffering {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(2)
            }

            if state.showControls {
                TVControlsOverlay(
                    state: state,
                    info: info,
                    onSeek: onSeek,
                    onAudioChange: onAudioChange,
                    onSubtitleChange: onSubtitleChange,
                    onInteraction: onInteraction,
                    onPreviousEpisode: onPreviousEpisode,
                    onNextEpisode: onNextEpisode
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: state.showControls)
    }
}

// MARK: - Controls Overlay

/// Layout shell: title + glass controls strip. Owns the single @FocusState
/// for all interactive elements so SwiftUI can reliably restore focus to the
/// correct button after a Menu is dismissed with the back button.
struct TVControlsOverlay: View {

    private enum FocusItem: Hashable { case scrubber, audio, subtitle, previousEpisode, nextEpisode }

    let state: TVPlayerState
    let info: JellyfinAPIClient.PlaybackInfo
    let onSeek: (Double) -> Void
    let onAudioChange: (Int?) -> Void
    let onSubtitleChange: (Int?) -> Void
    let onInteraction: () -> Void
    let onPreviousEpisode: () -> Void
    let onNextEpisode: () -> Void

    @FocusState private var focus: FocusItem?

    // Seek flash indicators — local UI state only
    @State private var showBackwardSeek = false
    @State private var showForwardSeek = false
    @State private var backwardSeekTask: Task<Void, Never>?
    @State private var forwardSeekTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            // Title floats at top — reads from state.title so it updates after episode navigation
            HStack {
                Text(state.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
                    .lineLimit(1)
                Spacer()
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 72)
            .padding(.top, 48)

            // Center: play/pause status + seek flash indicators
            HStack(spacing: 80) {
                Image(systemName: "gobackward.15")
                    .font(.system(size: CinemaScale.pt(52), weight: .light))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .opacity(showBackwardSeek ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: showBackwardSeek)

                Image(systemName: state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: CinemaScale.pt(80), weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 10)

                Image(systemName: "goforward.15")
                    .font(.system(size: CinemaScale.pt(52), weight: .light))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .opacity(showForwardSeek ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: showForwardSeek)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            // Shift up slightly so it sits in the visual center above the scrubber strip
            .padding(.bottom, 160)

            // Floating controls — no background container, elements float on video
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Spacer()
                    if state.previousEpisode != nil {
                        Button {
                            onInteraction()
                            onPreviousEpisode()
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: CinemaScale.pt(22), weight: .medium))
                                .foregroundStyle(focus == .previousEpisode ? Color.black.opacity(0.8) : .white)
                                .padding(14)
                                .background(
                                    focus == .previousEpisode
                                        ? AnyShapeStyle(.white)
                                        : AnyShapeStyle(.regularMaterial),
                                    in: Circle()
                                )
                                .animation(.easeInOut(duration: 0.15), value: focus == .previousEpisode)
                        }
                        .focused($focus, equals: .previousEpisode)
                        .focusEffectDisabled()
                    }
                    if state.nextEpisode != nil {
                        Button {
                            onInteraction()
                            onNextEpisode()
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: CinemaScale.pt(22), weight: .medium))
                                .foregroundStyle(focus == .nextEpisode ? Color.black.opacity(0.8) : .white)
                                .padding(14)
                                .background(
                                    focus == .nextEpisode
                                        ? AnyShapeStyle(.white)
                                        : AnyShapeStyle(.regularMaterial),
                                    in: Circle()
                                )
                                .animation(.easeInOut(duration: 0.15), value: focus == .nextEpisode)
                        }
                        .focused($focus, equals: .nextEpisode)
                        .focusEffectDisabled()
                    }
                    if !info.audioTracks.isEmpty {
                        TVAudioTrackMenu(
                            state: state,
                            tracks: info.audioTracks,
                            isFocused: focus == .audio,
                            onInteraction: onInteraction,
                            onAudioChange: onAudioChange
                        )
                        .focused($focus, equals: .audio)
                        .focusEffectDisabled()
                    }
                    if !info.subtitleTracks.isEmpty {
                        TVSubtitleTrackMenu(
                            state: state,
                            tracks: info.subtitleTracks,
                            isFocused: focus == .subtitle,
                            onInteraction: onInteraction,
                            onSubtitleChange: onSubtitleChange
                        )
                        .focused($focus, equals: .subtitle)
                        .focusEffectDisabled()
                    }
                }

                // Scrubber: glass pill container, focus + seek handled here
                TVPlayerScrubber(state: state, isFocused: focus == .scrubber)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CinemaRadius.large))
                    .focusable()
                    .focused($focus, equals: .scrubber)
                    .focusEffectDisabled()
                    .onMoveCommand { direction in
                        switch direction {
                        case .left:
                            onSeek(-15)
                            flashSeekIndicator(forward: false)
                        case .right:
                            onSeek(15)
                            flashSeekIndicator(forward: true)
                        default: break
                        }
                    }
            }
            .padding(.horizontal, 72)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focus = .scrubber }
        // Reset auto-hide timer whenever focus moves to any interactive element
        .onChange(of: focus) { _, _ in onInteraction() }
    }

    /// Shows the seek flash indicator for 500 ms then fades it out.
    /// Rapid consecutive seeks reset the timer so the icon stays visible throughout.
    private func flashSeekIndicator(forward: Bool) {
        if forward {
            forwardSeekTask?.cancel()
            showForwardSeek = true
            forwardSeekTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                showForwardSeek = false
            }
        } else {
            backwardSeekTask?.cancel()
            showBackwardSeek = true
            backwardSeekTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                showBackwardSeek = false
            }
        }
    }
}
#endif
