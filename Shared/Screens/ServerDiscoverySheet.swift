import SwiftUI
import CinemaxKit

/// Scans the local network for Jellyfin servers (UDP/7359 broadcast) and lets the
/// user pick one — populates the caller's URL field on selection.
///
/// Chrome is platform-branched for the same reason as `ServerHelpSheet`: tvOS `.toolbar`
/// inside a modal clips titles and produces empty-looking pill buttons. tvOS gets a full-screen
/// cover with a custom header + accent `CinemaButton`; iOS keeps the idiomatic NavigationStack.
struct ServerDiscoverySheet: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    /// Called with the chosen server's `Address`. Sheet dismisses immediately after.
    let onSelect: (String) -> Void

    @State private var isScanning = false
    @State private var servers: [DiscoveredJellyfinServer] = []
    @State private var hasScanned = false
    @State private var hasAutoRetried = false
    @Environment(\.scenePhase) private var scenePhase
    #if os(tvOS)
    @FocusState private var focusedField: FocusField?

    private enum FocusField: Hashable {
        case done
        case scanAgain
    }
    #endif

    var body: some View {
        #if os(tvOS)
        tvOSChrome
            .task { await scan() }
            .onChange(of: scenePhase) { _, phase in rescanOnActivation(phase) }
        #else
        iOSChrome
            .task { await scan() }
            .onChange(of: scenePhase) { _, phase in rescanOnActivation(phase) }
        #endif
    }

    // MARK: - iOS/iPad chrome

    #if !os(tvOS)
    private var iOSChrome: some View {
        NavigationStack {
            ZStack {
                CinemaColor.surface.ignoresSafeArea()
                stateContent
            }
            .navigationTitle(loc.localized("server.discovery.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel")) { dismiss() }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
    }
    #endif

    // MARK: - tvOS chrome

    #if os(tvOS)
    private var tvOSChrome: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                stateContent
                    .frame(maxWidth: 1400)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, CinemaSpacing.spacing10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(loc.localized("server.discovery.title"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)

            Spacer(minLength: CinemaSpacing.spacing6)

            CinemaButton(
                title: loc.localized("action.done"),
                style: .accent
            ) {
                dismiss()
            }
            .frame(width: 240)
            .focused($focusedField, equals: .done)
            .onMoveCommand { direction in
                if direction == .down, focusedField == .done {
                    focusedField = .scanAgain
                }
            }
        }
        .padding(.horizontal, CinemaSpacing.spacing10)
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing5)
    }
    #endif

    // MARK: - States

    @ViewBuilder
    private var stateContent: some View {
        if isScanning && servers.isEmpty {
            scanningState
        } else if servers.isEmpty && hasScanned {
            emptyState
        } else {
            resultsList
        }
    }

    private var scanningState: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            Spacer()
            ProgressView()
                .tint(themeManager.accent)
                .scaleEffect(1.4)
            Text(loc.localized("server.discovery.scanning"))
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: CinemaSpacing.spacing5) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
            VStack(spacing: CinemaSpacing.spacing2) {
                Text(loc.localized("server.discovery.noResults.title"))
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurface)
                Text(loc.localized("server.discovery.noResults.message"))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, CinemaSpacing.spacing6)

            CinemaButton(
                title: loc.localized("server.discovery.scanAgain"),
                style: .accent,
                icon: "arrow.clockwise"
            ) {
                Task { await scan() }
            }
            .frame(maxWidth: 400)
            .padding(.horizontal, CinemaSpacing.spacing4)
            #if os(tvOS)
            .focused($focusedField, equals: .scanAgain)
            .onMoveCommand { direction in
                if direction == .up, focusedField == .scanAgain {
                    focusedField = .done
                }
            }
            #endif

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(tvOS)
        .onAppear { focusedField = .scanAgain }
        #endif
    }

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: CinemaSpacing.spacing3) {
                ForEach(servers) { server in
                    serverRow(server)
                }

                CinemaButton(
                    title: loc.localized("server.discovery.scanAgain"),
                    style: .ghost,
                    icon: "arrow.clockwise"
                ) {
                    Task { await scan() }
                }
                .frame(maxWidth: 400)
                .padding(.top, CinemaSpacing.spacing3)
                #if os(tvOS)
                .focused($focusedField, equals: .scanAgain)
                .onMoveCommand { direction in
                    if direction == .up, focusedField == .scanAgain {
                        focusedField = .done
                    }
                }
                #endif
            }
            .padding(CinemaSpacing.spacing4)
        }
    }

    @ViewBuilder
    private func serverRow(_ server: DiscoveredJellyfinServer) -> some View {
        Button {
            onSelect(server.address)
            dismiss()
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                ZStack {
                    Circle()
                        .fill(themeManager.accentContainer.opacity(0.25))
                        .frame(width: 48, height: 48)
                    Image(systemName: "server.rack")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(themeManager.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                        .font(CinemaFont.label(.large).weight(.semibold))
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(1)
                    Text(server.address)
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant.opacity(0.6))
            }
            .padding(CinemaSpacing.spacing3)
            .background(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .fill(CinemaColor.surfaceContainerHigh)
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel("\(server.name), \(server.address)")
    }

    // MARK: - Actions

    /// Broadcast-and-listen sweep. On an empty first result we transparently retry once
    /// after a short delay — on iPhone, the very first probe often races the local-network
    /// permission prompt and gets silently dropped by the system before the user can
    /// approve it. The retry catches that case without the user having to tap "Scan again".
    private func scan(isAutoRetry: Bool = false) async {
        isScanning = true
        if !isAutoRetry {
            servers = []
        }
        let found = await JellyfinServerDiscovery.discover()
        servers = found
        isScanning = false
        hasScanned = true

        if found.isEmpty, !isAutoRetry, !hasAutoRetried {
            hasAutoRetried = true
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await scan(isAutoRetry: true)
        }
    }

    /// Re-scan when the app becomes active with an empty result set — covers the flow
    /// where the user goes to Settings to enable Local Network access and comes back.
    private func rescanOnActivation(_ phase: ScenePhase) {
        guard phase == .active, !isScanning, servers.isEmpty else { return }
        hasAutoRetried = false
        Task { await scan() }
    }
}
