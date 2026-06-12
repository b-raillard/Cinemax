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
    var isSearching = false
    var hasSearched = false

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

    /// Defensive cap on search input — anything beyond this is almost
    /// certainly noise (paste accident, malformed dictation), and Jellyfin's
    /// search endpoint doesn't benefit from longer terms. Also bounds the
    /// payload sent in the URL.
    /// `nonisolated` so the matching `nonisolated static func sanitize`
    /// can read it; `Int` is Sendable so this is safe.
    nonisolated private static let maxQueryLength = 200

    /// FR/EN articles & conjunctions excluded from per-word search fetches and
    /// word-presence scoring (they'd match nearly everything). `nonisolated` +
    /// `Set<String>` (Sendable) so the ranking helpers can read it.
    nonisolated private static let searchStopWords: Set<String> = [
        "the", "a", "an", "of", "and", "or", "to", "in", "on",
        "le", "la", "les", "un", "une", "des", "du", "de", "et", "ou", "au", "aux"
    ]

    func search(using appState: AppState) {
        searchTask?.cancel()
        let query = Self.sanitize(searchText)

        guard !query.isEmpty else {
            results = []
            hasSearched = false
            return
        }

        let api = appState.apiClient
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            guard let userId = appState.currentUserId else { return }
            self?.isSearching = true
            // `defer` guarantees `isSearching` flips back to false even when an
            // early `return` fires after cancellation mid-await — otherwise the
            // UI can remain stuck on the spinner after a quick text change.
            defer { self?.isSearching = false }

            let ranked = await Self.fetchRanked(query: query, userId: userId, api: api)
            guard !Task.isCancelled else { return }
            self?.results = ranked
            self?.hasSearched = true
            // Only remember queries that produced something — a typo midway
            // through "missio" shouldn't pollute the history, and the debounce
            // already collapses keystroke noise into the final query.
            if !ranked.isEmpty {
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

    /// Fetches a permissive candidate set and ranks it locally so punctuation and
    /// word order don't drop relevant items. Jellyfin's `searchTerm` is contiguous
    /// and punctuation-sensitive — e.g. "Mission Impossible" misses
    /// "Mission : Impossible". We query the full phrase AND each significant word,
    /// union the candidates, then score by the weighting the user asked for:
    ///   • full query as a contiguous run in the title  (strongest)
    ///   • every query word present but separated / reordered
    ///   • only some query words present                (weakest)
    /// `nonisolated` (pure inputs, Sendable `any LibraryAPI`) so the per-word
    /// fetches can run concurrently off the main actor.
    nonisolated private static func fetchRanked(
        query: String,
        userId: String,
        api: any LibraryAPI
    ) async -> [BaseItemDto] {
        let normalizedQuery = normalizeForMatch(query)
        // Drop stop words so per-word fetches and the word-presence tiers stay
        // meaningful — otherwise "the"/"le"/"de" alone match hundreds of titles.
        let words = normalizedQuery
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 && !searchStopWords.contains($0) }

        // Always fetch the full phrase, plus up to the first 4 significant words.
        // Each term is a separate concurrent server request, so an unbounded list
        // turns a long query into a fan-out spike (a 7-word title = 8 requests per
        // debounced keystroke). The leading words are the most distinctive, and
        // scoring below still ranks against the *full* `words` set — capping only
        // the fetch, not the relevance. 1 + 4 = 5 requests worst case.
        var terms: [String] = [query]
        if words.count > 1 { terms.append(contentsOf: words.prefix(4)) }
        let uniqueTerms = Array(Set(terms))

        var candidates: [String: BaseItemDto] = [:]
        await withTaskGroup(of: [BaseItemDto].self) { group in
            for term in uniqueTerms {
                group.addTask {
                    (try? await api.searchItems(userId: userId, searchTerm: term, limit: 30)) ?? []
                }
            }
            for await items in group {
                for item in items where item.id != nil {
                    candidates[item.id!] = item
                }
            }
        }

        let scored = candidates.values.compactMap { item -> (item: BaseItemDto, score: Double)? in
            let score = max(
                relevanceScore(title: item.name ?? "", fullQuery: normalizedQuery, queryWords: words),
                relevanceScore(title: item.originalTitle ?? "", fullQuery: normalizedQuery, queryWords: words)
            )
            return score > 0 ? (item, score) : nil
        }
        return scored.sorted { $0.score > $1.score }.map(\.item)
    }

    /// Weighted relevance of one title against the query. 0 = no match (filtered out).
    /// `internal` (not `private`) so the ranking is directly unit-testable via
    /// `@testable import`.
    nonisolated static func relevanceScore(title: String, fullQuery: String, queryWords: [String]) -> Double {
        let normalized = normalizeForMatch(title)
        guard !normalized.isEmpty, !fullQuery.isEmpty else { return 0 }

        // Tier 1 — full query appears as a contiguous run.
        if normalized.contains(fullQuery) {
            var score = 1000.0
            if normalized == fullQuery { score += 500 }                 // exact title
            else if normalized.hasPrefix(fullQuery) { score += 250 }     // title starts with query
            return score - Double(normalized.count) * 0.5               // prefer tighter titles
        }

        guard !queryWords.isEmpty else { return 0 }
        let titleWords = Set(normalized.split(separator: " ").map(String.init))
        let present = queryWords.filter { titleWords.contains($0) || normalized.contains($0) }
        guard !present.isEmpty else { return 0 }

        // Tier 2 — every query word present but separated; Tier 3 — only some.
        if present.count == queryWords.count {
            return 500 - Double(normalized.count) * 0.5
        }
        return 100 * (Double(present.count) / Double(queryWords.count))
    }

    /// Lowercases, strips diacritics, and collapses any run of non-alphanumerics to
    /// a single space so punctuation can't block matches: "Mission : Impossible"
    /// and "mission impossible" normalize to the same string.
    nonisolated static func normalizeForMatch(_ raw: String) -> String {
        let folded = raw.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasSpace = true   // seeded true so leading separators are trimmed
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
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
