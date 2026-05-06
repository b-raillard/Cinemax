import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI
#if os(iOS)
import Speech
import AVFoundation
#endif

// MARK: - Speech Recognition Helper (iOS only)

#if os(iOS)
/// Wraps SFSpeechRecognizer + AVAudioEngine outside of @Observable to avoid
/// Sendable issues with Swift 6 strict concurrency.
@MainActor
final class SpeechRecognitionHelper {
    private var speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    var onTranscript: ((String) -> Void)?
    var onStopped: (() -> Void)?
    var onPermissionError: ((String) -> Void)?

    func requestPermissionsAndStart() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                guard let self else { return }
                switch authStatus {
                case .authorized:
                    AVAudioApplication.requestRecordPermission { granted in
                        DispatchQueue.main.async {
                            if granted {
                                self.startListening()
                            } else {
                                self.onPermissionError?("Microphone access is required for voice search. Enable it in Settings > Privacy & Security > Microphone.")
                            }
                        }
                    }
                case .denied, .restricted:
                    self.onPermissionError?("Speech recognition access is required for voice search. Enable it in Settings > Privacy & Security > Speech Recognition.")
                case .notDetermined:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func startListening() {
        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onPermissionError?("Speech recognition is not available on this device.")
            return
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stop()
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            var isFinal = false
            if let result {
                let transcript = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.onTranscript?(transcript)
                }
                isFinal = result.isFinal
            }
            if error != nil || isFinal {
                DispatchQueue.main.async {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onStopped?()
    }
}
#endif

// MARK: - ViewModel

@MainActor @Observable
final class SearchViewModel {
    var searchText = ""
    var results: [BaseItemDto] = []
    var isSearching = false
    var hasSearched = false

    // Voice search state (iOS only)
    var isListening = false
    var showPermissionAlert = false
    var permissionAlertMessage = ""

    private var searchTask: Task<Void, Never>?

    #if os(iOS)
    private let speechHelper = SpeechRecognitionHelper()
    private var hasBoundSpeechCallbacks = false

    /// Binds the speech helper's callbacks once per view-model lifetime. Re-binding on
    /// every toggle is wasteful — old closures are replaced but their captured
    /// `appState` / `self` stack up briefly during tear-down, which the audit flagged
    /// as a latent leak. Guarding on `hasBoundSpeechCallbacks` keeps a single stable
    /// set of closures; `stop()` clears them on the helper side.
    func setupSpeechCallbacks(using appState: AppState) {
        guard !hasBoundSpeechCallbacks else { return }
        hasBoundSpeechCallbacks = true
        speechHelper.onTranscript = { [weak self] transcript in
            self?.searchText = transcript
            self?.search(using: appState)
        }
        speechHelper.onStopped = { [weak self] in
            self?.isListening = false
        }
        speechHelper.onPermissionError = { [weak self] message in
            self?.permissionAlertMessage = message
            self?.showPermissionAlert = true
        }
    }
    #endif

    // MARK: - Surprise Me

    /// Two specialized entry points (vs. one parameterized) so the `[BaseItemKind]`
    /// literal is captured locally — Swift 6 strict concurrency raises a "sending
    /// non-Sendable value" diagnostic when the array is built from a function
    /// parameter and sent across the actor boundary into the API call.
    func fetchRandomMovie(using appState: AppState) async -> BaseItemDto? {
        guard let userId = appState.currentUserId else { return nil }
        do {
            let response = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.movie],
                sortBy: [.random],
                limit: 1
            )
            return response.items.first
        } catch {
            return nil
        }
    }

    func fetchRandomSeries(using appState: AppState) async -> BaseItemDto? {
        guard let userId = appState.currentUserId else { return nil }
        do {
            let response = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.series],
                sortBy: [.random],
                limit: 1
            )
            return response.items.first
        } catch {
            return nil
        }
    }

    // MARK: Text search

    /// Defensive cap on search input — anything beyond this is almost
    /// certainly noise (paste accident, malformed dictation), and Jellyfin's
    /// search endpoint doesn't benefit from longer terms. Also bounds the
    /// payload sent in the URL.
    /// `nonisolated` so the matching `nonisolated static func sanitize`
    /// can read it; `Int` is Sendable so this is safe.
    nonisolated private static let maxQueryLength = 200

    func search(using appState: AppState) {
        searchTask?.cancel()
        let query = Self.sanitize(searchText)

        guard !query.isEmpty else {
            results = []
            hasSearched = false
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            guard let userId = appState.currentUserId else { return }
            self?.isSearching = true
            // `defer` guarantees `isSearching` flips back to false even when an
            // early `return` fires after cancellation mid-await — otherwise the
            // UI can remain stuck on the spinner after a quick text change.
            defer { self?.isSearching = false }

            do {
                let items = try await appState.apiClient.searchItems(userId: userId, searchTerm: query, limit: 30)
                guard !Task.isCancelled else { return }
                self?.results = items
            } catch {
                guard !Task.isCancelled else { return }
                self?.results = []
            }

            self?.hasSearched = true
        }
    }

    // MARK: Voice search (iOS only)

    #if os(iOS)
    func toggleListening(using appState: AppState) {
        if isListening {
            stopListening()
        } else {
            setupSpeechCallbacks(using: appState)
            isListening = true
            speechHelper.requestPermissionsAndStart()
        }
    }

    func stopListening() {
        speechHelper.stop()
        isListening = false
    }
    #endif

    /// Trims whitespace, strips control / illegal chars, and caps length.
    /// `BaseItemDto` search terms flow into a URL query string — keeping the
    /// input bounded and printable is a small defense against pathological
    /// values from voice dictation, paste, or future-untrusted sources.
    /// `nonisolated` so it can be called from any context (matches the
    /// documented escape hatch for pure-input/Sendable-output static funcs
    /// on `@MainActor` types — see CLAUDE.md).
    nonisolated private static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let stripped = trimmed.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(stripped))
        if cleaned.count > maxQueryLength {
            return String(cleaned.prefix(maxQueryLength))
        }
        return cleaned
    }
}
