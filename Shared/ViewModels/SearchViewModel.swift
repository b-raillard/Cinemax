import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI
#if os(iOS)
import Speech
import AVFoundation
#endif

/// Typed voice-search failures so user-facing copy lives in
/// Localizable.strings (localized at the view) instead of being hardcoded
/// English in the speech helper.
/// Result-type scope for the search filter chips. `all` keeps the original
/// movie+series+episode fan-out; the narrowed scopes constrain the server
/// `includeItemTypes` so the candidate set (and ranking) only sees that kind.
enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case movies
    case series

    var id: String { rawValue }

    var includeItemTypes: [BaseItemKind] {
        switch self {
        case .all:    [.movie, .series, .episode]
        case .movies: [.movie]
        case .series: [.series]
        }
    }

    var localizationKey: String {
        switch self {
        case .all:    "search.filter.all"
        case .movies: "search.filter.movies"
        case .series: "search.filter.series"
        }
    }
}

enum VoiceSearchPermissionError: Sendable {
    case microphoneDenied
    case speechRecognitionDenied
    case recognizerUnavailable

    var localizationKey: String {
        switch self {
        case .microphoneDenied: "search.voice.microphoneDenied"
        case .speechRecognitionDenied: "search.voice.speechDenied"
        case .recognizerUnavailable: "search.voice.unavailable"
        }
    }
}

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

    /// Auto-stops capture once the user goes quiet. Buffer-based recognition
    /// never reports `isFinal` on its own (that only happens after `endAudio()`),
    /// so we restart this timer on every partial transcript and stop when it fires.
    /// `silenceTimeout` is the gap-between-words cutoff; `initialTimeout` is the
    /// longer grace before the FIRST word — server-side recognition
    /// (`requiresOnDeviceRecognition = false`) has network latency, and the short
    /// timeout armed up front would kill the session before any transcript landed.
    private var silenceTimer: Task<Void, Never>?
    private let silenceTimeout: Duration = .milliseconds(1500)
    private let initialTimeout: Duration = .seconds(5)

    var onTranscript: ((String) -> Void)?
    var onStopped: (() -> Void)?
    var onPermissionError: ((VoiceSearchPermissionError) -> Void)?

    func requestPermissionsAndStart() {
        Task { @MainActor [weak self] in
            // RULE — the TCC permission callbacks (SFSpeechRecognizer /
            // AVAudioApplication) fire on TCC's own background dispatch queue. If
            // the completion closure lives in a `@MainActor` context it inherits
            // that isolation, and Swift 6 inserts an executor assertion at the
            // block's entry (`_swift_task_checkIsolatedSwift`) which traps with
            // `dispatch_assert_queue_fail` ("Block was expected to execute on
            // queue"). Bridging through `nonisolated static` continuation helpers
            // means the callback runs with NO actor isolation to assert — we only
            // hop back to the MainActor here, after `await`. Same root cause as the
            // `MPMediaItemArtwork` rule in CLAUDE.md.
            let speechStatus = await SpeechRecognitionHelper.requestSpeechAuthorization()
            guard let self else { return }
            guard speechStatus == .authorized else {
                self.onPermissionError?(.speechRecognitionDenied)
                return
            }
            let micGranted = await SpeechRecognitionHelper.requestRecordPermission()
            guard micGranted else {
                self.onPermissionError?(.microphoneDenied)
                return
            }
            self.startListening()
        }
    }

    /// `nonisolated` so the underlying TCC completion handler executes outside any
    /// actor — see the isolation RULE in `requestPermissionsAndStart`.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private nonisolated static func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startListening() {
        recognitionTask?.cancel()
        recognitionTask = nil

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onPermissionError?(.recognizerUnavailable)
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            // `.duckOthers` is invalid on the `.record` category and makes
            // `setCategory` throw on some routes; the recommended speech-capture
            // setup is `.record` + `.measurement` with no mix options.
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onPermissionError?(.recognizerUnavailable)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        // `installTap` raises an uncatchable Obj-C `NSException`
        // (`IsFormatSampleRateAndChannelCountValid`) when the input format has a
        // zero sample rate / channel count — which happens if the audio route
        // hasn't settled after activating the session. Validate first and bail
        // gracefully instead of crashing the app.
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            recognitionRequest = nil
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            onPermissionError?(.recognizerUnavailable)
            return
        }

        // The tap fires on libAudio's real-time render thread. Capture the request
        // directly (NOT `self`, whose stored properties are @MainActor-isolated) and
        // mark the closure `@Sendable` so it stays nonisolated — otherwise it
        // inherits @MainActor and traps with `dispatch_assert_queue_fail` off-main.
        // `append(_:)` is thread-safe; `nonisolated(unsafe)` lets the non-Sendable
        // request cross into the @Sendable closure.
        nonisolated(unsafe) let tapRequest = request
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { @Sendable buffer, _ in
            tapRequest.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stop()
            return
        }

        // Same isolation rule: the result handler is invoked on a background queue.
        // `@Sendable` keeps it nonisolated; pull out the Sendable values here, then
        // hop to the MainActor to touch UI state. (`@MainActor` classes are Sendable,
        // so `[weak self]` is a legal capture in a @Sendable closure.)
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                // Ignore empty transcripts: when `endAudio()` finalizes on stop, the
                // recognizer can emit a final result with an EMPTY formatted string —
                // forwarding it would wipe `searchText` (and the results) the instant
                // the mic turns off.
                if let transcript, !transcript.isEmpty {
                    self.onTranscript?(transcript)
                    self.bumpSilenceTimer(after: self.silenceTimeout)   // gap between words
                }
                if failed || isFinal { self.stop() }
            }
        }

        // Longer grace before the first transcript so server-recognition latency
        // doesn't trip the cutoff; an empty session still auto-stops after this.
        bumpSilenceTimer(after: initialTimeout)
    }

    /// (Re)starts the silence countdown. Each new transcript pushes it back; when
    /// it elapses with no further speech we stop and the field keeps the result.
    private func bumpSilenceTimer(after timeout: Duration) {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        silenceTimer?.cancel()
        silenceTimer = nil
        // `stop()` can arrive from three sources (silence timer, final result, or a
        // manual tap). Bail if we've already torn down so `onStopped` fires once and
        // we don't `removeTap` a bus that no longer has one.
        guard audioEngine.isRunning || recognitionRequest != nil else { return }
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

    /// Persons matching the query, shown as a portrait row above the poster
    /// grid. Populated only in the `.all` scope. The row is drawn only when this
    /// is non-empty, which makes a failed person fetch degrade to "no row"
    /// rather than to an error state — see `search(using:)`.
    var personResults: [BaseItemDto] = []
    var isSearching = false
    var hasSearched = false
    /// True when the last search failed to reach the server (every term fetch
    /// threw) rather than legitimately returning zero matches — lets the view
    /// show a retryable error state distinct from the "no results" empty state.
    var searchFailed = false

    /// Active result-type filter (All / Movies / Series). Changing it re-runs
    /// the current query — the screen fires `search(using:)` from `.onChange`.
    var scope: SearchScope = .all

    /// Most-recent-first queries shown as chips on the empty search screen.
    /// Persisted as JSON under `SettingsKey.searchRecentQueries`; mutate only
    /// through `recordRecentSearch` / `clearRecentSearches` (explicit-mutator
    /// pattern — see the `@Observable`+`didSet` RULE). Loaded in `init` —
    /// the `@Observable` macro rejects `Self.`-qualified calls in stored
    /// property initializers ("covariant 'Self'" diagnostic).
    private(set) var recentSearches: [String] = []

    init() {
        recentSearches = Self.loadRecentSearches()
    }

    // Voice search state (iOS only)
    var isListening = false
    var showPermissionAlert = false
    var permissionError: VoiceSearchPermissionError?

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
        speechHelper.onPermissionError = { [weak self] error in
            // `toggleListening` flips `isListening` optimistically, before the TCC
            // prompts resolve. Every bail-out in the helper (speech denied, mic
            // denied, recognizer/session/audio-route unavailable) reports here and
            // returns WITHOUT reaching `stop()` — whose idempotency guard would
            // early-return before `onStopped` anyway, since nothing ever started.
            // So this is the single place that has to clear the flag, or the mic
            // pill keeps pulsing "listening" while nothing is recording.
            self?.isListening = false
            self?.permissionError = error
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
    //
    // Input hygiene and the whole ranking path live in `LibrarySearchRanker` so
    // this screen and the App Intents entity query score candidates identically.

    func search(using appState: AppState) {
        searchTask?.cancel()
        let query = LibrarySearchRanker.sanitize(searchText)

        guard !query.isEmpty else {
            results = []
            personResults = []
            hasSearched = false
            searchFailed = false
            return
        }

        let api = appState.apiClient
        let includeItemTypes = scope.includeItemTypes
        // The person row belongs to the unfiltered scope only — a type filter
        // that surfaces something other than the requested type isn't a filter.
        // Narrowed scopes don't even spend the request.
        let includePersons = scope == .all
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            guard let userId = appState.currentUserId else { return }
            self?.isSearching = true
            // `defer` guarantees `isSearching` flips back to false even when an
            // early `return` fires after cancellation mid-await — otherwise the
            // UI can remain stuck on the spinner after a quick text change.
            defer { self?.isSearching = false }

            // Two independent fetches, run concurrently. A failing person search
            // must never degrade the main result, so `searchFailed` — which
            // drives the retryable error screen — stays driven by the titles
            // alone; `rankPersons` swallows its own error into an empty array.
            async let titles = LibrarySearchRanker.rank(query: query, userId: userId, includeItemTypes: includeItemTypes, api: api)
            async let persons: [BaseItemDto] = includePersons
                ? LibrarySearchRanker.rankPersons(query: query, userId: userId, api: api)
                : []

            let outcome = await titles
            let people = await persons
            guard !Task.isCancelled else { return }
            self?.results = outcome.items
            self?.personResults = people
            self?.searchFailed = outcome.failed
            self?.hasSearched = true
            // Only remember queries that produced something — a typo midway
            // through "missio" shouldn't pollute the history, and the debounce
            // already collapses keystroke noise into the final query. A failed
            // fetch never records (the query may be perfectly valid).
            if !outcome.failed && !outcome.items.isEmpty {
                self?.recordRecentSearch(query)
            }
        }
    }

    // MARK: Recent searches

    private static let maxRecentSearches = 8

    /// Whether history capture is enabled (Privacy & Security toggle).
    /// Read straight from UserDefaults because `@AppStorage` can't live on an
    /// `@Observable` class; `object(forKey:)` keeps the default-true semantics
    /// (`bool(forKey:)` would default to false for fresh installs).
    private static var isHistoryEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.searchSaveHistory) as? Bool
            ?? SettingsKey.Default.searchSaveHistory
    }

    private static func loadRecentSearches() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKey.searchRecentQueries),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    private func recordRecentSearch(_ query: String) {
        guard Self.isHistoryEnabled else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        list.insert(query, at: 0)
        if list.count > Self.maxRecentSearches {
            list = Array(list.prefix(Self.maxRecentSearches))
        }
        recentSearches = list
        persistRecentSearches()
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: SettingsKey.searchRecentQueries)
    }

    private func persistRecentSearches() {
        if let data = try? JSONEncoder().encode(recentSearches) {
            UserDefaults.standard.set(data, forKey: SettingsKey.searchRecentQueries)
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
}
