#if os(tvOS)
import SwiftUI
import CinemaxKit

// MARK: - Audio Track Menu

/// Isolated sub-view. Only accesses state.currentAudioIdx — never re-renders on time updates.
/// Selecting the already-active track is a no-op (no stream restart).
struct TVAudioTrackMenu: View {
    let state: TVPlayerState
    let tracks: [MediaTrackInfo]
    let isFocused: Bool
    let onInteraction: () -> Void
    let onAudioChange: (Int?) -> Void

    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Menu {
            ForEach(tracks) { track in
                Button {
                    onInteraction()
                    guard state.currentAudioIdx != track.id else { return }
                    onAudioChange(track.id)
                } label: {
                    if state.currentAudioIdx == track.id {
                        Label(track.label, systemImage: "checkmark")
                    } else {
                        Text(track.label)
                    }
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: CinemaScale.pt(22), weight: .medium))
                .foregroundStyle(isFocused ? Color.black.opacity(0.8) : .white)
                .padding(14)
                .background(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.regularMaterial), in: Circle())
                .animation(.easeInOut(duration: 0.15), value: isFocused)
                .accessibilityLabel(loc.localized("player.audio"))
        }
    }
}

// MARK: - Subtitle Track Menu

/// Isolated sub-view. Only accesses state.currentSubtitleIdx — never re-renders on time updates.
/// Selecting the already-active subtitle (or "off" when already off) is a no-op.
struct TVSubtitleTrackMenu: View {
    let state: TVPlayerState
    let tracks: [MediaTrackInfo]
    let isFocused: Bool
    let onInteraction: () -> Void
    let onSubtitleChange: (Int?) -> Void

    @Environment(LocalizationManager.self) private var loc

    private var lang: String { UserDefaults.standard.string(forKey: "language") ?? "fr" }
    private var offLabel: String { lang == "fr" ? "Désactivé" : "Off" }
    private var isOff: Bool { state.currentSubtitleIdx == nil || state.currentSubtitleIdx == -1 }

    var body: some View {
        Menu {
            Button {
                onInteraction()
                guard !isOff else { return }
                onSubtitleChange(-1)
            } label: {
                if isOff {
                    Label(offLabel, systemImage: "checkmark")
                } else {
                    Text(offLabel)
                }
            }
            ForEach(tracks) { track in
                Button {
                    onInteraction()
                    guard state.currentSubtitleIdx != track.id else { return }
                    onSubtitleChange(track.id)
                } label: {
                    if state.currentSubtitleIdx == track.id {
                        Label(track.label, systemImage: "checkmark")
                    } else {
                        Text(track.label)
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: CinemaScale.pt(22), weight: .medium))
                .foregroundStyle(isFocused ? Color.black.opacity(0.8) : .white)
                .padding(14)
                .background(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.regularMaterial), in: Circle())
                .animation(.easeInOut(duration: 0.15), value: isFocused)
                .accessibilityLabel(loc.localized("player.subtitles"))
        }
    }
}
#endif
