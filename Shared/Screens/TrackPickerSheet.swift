import SwiftUI
import CinemaxKit

// MARK: - Track Picker Sheet

/// Unified audio + subtitle track picker, used on both iOS (sheet) and tvOS (pre-play sheet).
struct TrackPickerSheet: View {
    let info: JellyfinAPIClient.PlaybackInfo
    /// Called with (audioStreamIndex, subtitleStreamIndex). nil = keep current / off.
    let onConfirm: (Int?, Int?) -> Void

    @Environment(LocalizationManager.self) private var loc
    @State private var audioId: Int?
    @State private var subtitleId: Int?  // -1 = off, nil initially resolved to current or off

    private let noSubtitle = -1

    init(info: JellyfinAPIClient.PlaybackInfo, onConfirm: @escaping (Int?, Int?) -> Void) {
        self.info = info
        self.onConfirm = onConfirm
        _audioId = State(initialValue: info.selectedAudioIndex ?? info.audioTracks.first(where: { $0.isDefault })?.id ?? info.audioTracks.first?.id)
        _subtitleId = State(initialValue: info.selectedSubtitleIndex)
    }

    var body: some View {
        NavigationView {
            List {
                if !info.audioTracks.isEmpty {
                    Section(loc.localized("player.audio")) {
                        ForEach(info.audioTracks) { track in
                            Button {
                                audioId = track.id
                            } label: {
                                HStack {
                                    Text(track.label)
                                        .foregroundStyle(CinemaColor.onSurface)
                                    Spacer()
                                    if audioId == track.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !info.subtitleTracks.isEmpty {
                    Section(loc.localized("player.subtitles")) {
                        // "Off" option
                        Button {
                            subtitleId = noSubtitle
                        } label: {
                            HStack {
                                Text(loc.localized("player.subtitles.off"))
                                    .foregroundStyle(CinemaColor.onSurface)
                                Spacer()
                                if subtitleId == noSubtitle || subtitleId == nil {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        ForEach(info.subtitleTracks) { track in
                            Button {
                                subtitleId = track.id
                            } label: {
                                HStack {
                                    Text(track.label)
                                        .foregroundStyle(CinemaColor.onSurface)
                                    Spacer()
                                    if subtitleId == track.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(loc.localized("player.trackPicker.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.localized("action.play")) {
                        onConfirm(audioId, subtitleId == noSubtitle ? -1 : subtitleId)
                    }
                    .fontWeight(.semibold)
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.localized("action.play")) {
                        onConfirm(audioId, subtitleId == noSubtitle ? -1 : subtitleId)
                    }
                }
            }
            #endif
        }
    }
}
