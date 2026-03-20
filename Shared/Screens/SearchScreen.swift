import SwiftUI
import NukeUI
import CinemaxKit
import JellyfinAPI
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

    func setupSpeechCallbacks(using appState: AppState) {
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

    // MARK: Text search

    func search(using appState: AppState) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            results = []
            hasSearched = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            guard let userId = appState.currentUserId else { return }
            isSearching = true

            do {
                let items = try await appState.apiClient.searchItems(userId: userId, searchTerm: query, limit: 30)
                guard !Task.isCancelled else { return }
                results = items
            } catch {
                guard !Task.isCancelled else { return }
                results = []
            }

            isSearching = false
            hasSearched = true
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

// MARK: - View

struct SearchScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @State private var viewModel = SearchViewModel()

    // Pulsing animation state for the listening indicator
    @State private var isPulsing = false

    private let columns: [GridItem] = {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 32), count: 6)
        #else
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
        #endif
    }()

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                searchField
                #if os(iOS)
                listeningLabel
                #endif
                resultContent
            }
        }
        .navigationTitle("Search")
        #if os(iOS)
        .alert("Permission Required", isPresented: Bindable(viewModel).showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.permissionAlertMessage)
        }
        .onDisappear {
            // Stop any active recognition session when leaving the screen
            if viewModel.isListening {
                viewModel.stopListening()
            }
        }
        #endif
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .font(.system(size: searchIconSize))

            TextField("Search movies, shows...", text: Bindable(viewModel).searchText)
                #if os(iOS)
                .textFieldStyle(.plain)
                #endif
                .font(.system(size: searchFontSize))
                .foregroundStyle(CinemaColor.onSurface)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: viewModel.searchText) {
                    viewModel.search(using: appState)
                }

            // Microphone button — iOS only
            #if os(iOS)
            microphoneButton
            #endif

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                    viewModel.results = []
                    viewModel.hasSearched = false
                    #if os(iOS)
                    if viewModel.isListening {
                        viewModel.stopListening()
                    }
                    #endif
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CinemaColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        .padding(.horizontal, gridPadding)
        .padding(.vertical, CinemaSpacing.spacing3)
    }

    // MARK: - Microphone Button (iOS only)

    #if os(iOS)
    private var microphoneButton: some View {
        Button {
            viewModel.toggleListening(using: appState)
        } label: {
            ZStack {
                // Pulsing ring shown while listening
                if viewModel.isListening {
                    Circle()
                        .fill(themeManager.accent.opacity(0.25))
                        .frame(width: isPulsing ? 36 : 28, height: isPulsing ? 36 : 28)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: isPulsing
                        )
                }

                Image(systemName: "mic.fill")
                    .font(.system(size: searchIconSize))
                    .foregroundStyle(viewModel.isListening ? themeManager.accent : CinemaColor.onSurfaceVariant)
            }
        }
        .buttonStyle(.plain)
        .onChange(of: viewModel.isListening) { _, newValue in
            isPulsing = newValue
        }
    }

    // MARK: - Listening Label (iOS only)

    @ViewBuilder
    private var listeningLabel: some View {
        if viewModel.isListening {
            Text("Listening...")
                .font(CinemaFont.label(.large))
                .foregroundStyle(themeManager.accent)
                .padding(.bottom, CinemaSpacing.spacing1)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
    #endif

    // MARK: - Results

    @ViewBuilder
    private var resultContent: some View {
        if viewModel.isSearching {
            Spacer()
            ProgressView()
                .tint(CinemaColor.onSurfaceVariant)
                .scaleEffect(1.5)
            Spacer()
        } else if viewModel.results.isEmpty && viewModel.hasSearched {
            Spacer()
            VStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(CinemaColor.outlineVariant)
                Text("No results found")
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            Spacer()
        } else if viewModel.results.isEmpty {
            Spacer()
            VStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(CinemaColor.outlineVariant)
                Text("Search your library")
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            Spacer()
        } else {
            resultsGrid
        }
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                Text("Top Matches")
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(.horizontal, gridPadding)

                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(viewModel.results, id: \.id) { item in
                        resultCard(item)
                    }
                }
                .padding(.horizontal, gridPadding)

                Spacer(minLength: 80)
            }
        }
    }

    @ViewBuilder
    private func resultCard(_ item: BaseItemDto) -> some View {
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        let subtitle: String = {
            var parts: [String] = []
            if let year = item.productionYear { parts.append(String(year)) }
            if let type = item.type { parts.append(type.rawValue) }
            return parts.joined(separator: " · ")
        }()

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(
                    itemId: id,
                    itemType: item.type ?? .movie
                )
            }
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map { builder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300) },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }

    // MARK: - Sizing

    private var gridPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        CinemaSpacing.spacing3
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        32
        #else
        16
        #endif
    }

    private var searchFontSize: CGFloat {
        #if os(tvOS)
        24
        #else
        17
        #endif
    }

    private var searchIconSize: CGFloat {
        #if os(tvOS)
        22
        #else
        17
        #endif
    }
}
