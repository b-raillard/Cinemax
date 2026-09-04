import SwiftUI
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "RemoteControl")

/// Makes this device a **target** for another Jellyfin session's "Play on…"
/// picker — the receiving half of the feature `MediaDetailRemotePlay` already
/// implements for sending.
///
/// Two things are required, and neither works alone:
///   1. `publishCapabilities` — the only thing that sets
///      `SessionInfoDto.supportsRemoteControl`, which is what makes this device
///      appear in a picker at all (this app's own `RemotePlayTarget.resolve`
///      filters on exactly that flag, which is why Cinemax could never cast to
///      Cinemax before).
///   2. A subscription to the realtime socket — Jellyfin delivers session
///      commands there and nowhere else, so capabilities without one would put
///      the device in the list and then swallow every tap. The socket itself is
///      owned by `JellyfinSocketHub`, never by this listener: Watch Together
///      needs the same one, and two connections would make every frame arrive
///      twice (see the one-socket rule on `JellyfinSocket`).
///
/// **Playback is routed through the same in-process path as an App Intent**
/// (`pendingIntentPlaybackItemId` + `pendingDeepLinkItemId`), not straight to
/// the player. That is what gives a remote-initiated play the same fidelity as
/// a tap: series → next-up resolution, resume position, version pick, prev/next
/// episode buttons — all owned by `MediaDetailScreen.resolvedPlayTarget(for:)`.
/// The consequence is that an inbound `StartPositionTicks` is *not* threaded
/// through: the receiver re-resolves the resume position itself, which lands on
/// the same tick for the sender this app ships (its `remotePlayIntent` reads
/// that very position) and is the more correct answer for any other sender.
///
/// Deliberately NOT handled: `Playstate` (pause / seek / stop from the sender).
/// The capability declaration advertises only what is honored here, so no sender
/// renders a transport control that does nothing — and this app's own sender is
/// send-only by design anyway (see the "Remote control" RULE in CLAUDE.md).
@MainActor
final class RemoteControlListener {
    /// Our handle on the shared socket. Nil when not listening.
    private var subscription: UUID?
    private var consumeTask: Task<Void, Never>?
    /// Bumped by every `apply`, and re-checked after each await inside `start`.
    /// A logout / server switch that lands while `publishCapabilities` is in
    /// flight must not go on to open a socket against the session it just left.
    private var generation = 0
    /// What the current socket + capability post were built for, so a repeated
    /// `apply` with unchanged inputs is a no-op instead of a reconnect storm
    /// (`scenePhase` and auth observers both drive this).
    private var appliedState: State?

    private struct State: Equatable {
        let userId: String
        let serverURL: URL
        let enabled: Bool
    }

    /// Single entry point: reconciles the live socket against what the app state
    /// says it should be. Safe to call repeatedly — on auth changes, server
    /// switches, foregrounding, and the settings toggle.
    func apply(appState: AppState, toasts: ToastCenter, enabled: Bool) {
        guard appState.isAuthenticated,
              let userId = appState.currentUserId,
              let serverURL = appState.serverURL else {
            stop()
            return
        }
        let desired = State(userId: userId, serverURL: serverURL, enabled: enabled)
        guard desired != appliedState else { return }

        // Tear the old session down first: a switch must never leave a socket
        // open against the previous server.
        stop()
        appliedState = desired
        generation &+= 1
        let token = generation

        Task { [weak self] in
            // Announce the withdrawal too — clearing `supportsMediaControl` is
            // what actually removes a still-live session from other clients'
            // pickers. Then stop, because a disabled listener has no socket.
            do {
                try await appState.apiClient.publishCapabilities(supportsMediaControl: enabled)
            } catch {
                // Non-fatal and deliberately silent: failing to advertise costs
                // the user a target in someone else's list, never a broken
                // screen. A 401 already drives the shared session-expiry flow.
                logger.debug("Publishing capabilities failed: \(error.localizedDescription, privacy: .public)")
            }
            guard let self, token == self.generation, enabled else { return }
            self.openSocket(appState: appState, toasts: toasts, token: token)
        }
    }

    /// Closes the socket and forgets the applied state, so the next `apply`
    /// re-establishes from scratch. Called on background, logout, and before
    /// every re-apply.
    func stop() {
        // Bump first: a frame already in flight through the stream must be
        // rejected by `handle`'s token check even before cancellation lands.
        generation &+= 1
        consumeTask?.cancel()
        consumeTask = nil
        if let subscription {
            // Only ever drops OUR subscription. The hub closes the socket when
            // the last consumer leaves, so a live Watch Together session keeps
            // it up — which is the whole point of the hub.
            Task { await JellyfinSocketHub.shared.unsubscribe(subscription) }
        }
        subscription = nil
        appliedState = nil
    }

    // MARK: - Socket

    private func openSocket(appState: AppState, toasts: ToastCenter, token: Int) {
        guard let url = appState.apiClient.makeRealtimeSocketURL() else { return }
        consumeTask = Task { [weak self] in
            let handle = await JellyfinSocketHub.shared.subscribe(url: url)
            guard let listener = self, token == listener.generation else {
                await JellyfinSocketHub.shared.unsubscribe(handle.id)
                return
            }
            listener.subscription = handle.id
            for await message in handle.messages {
                // A logout / switch / background bumps the token; the stream can
                // still deliver a frame that was already in flight.
                guard let self, token == self.generation else { return }
                self.handle(message, appState: appState, toasts: toasts)
            }
        }
    }

    /// The hub delivers every frame to every consumer, so this sees SyncPlay
    /// traffic too and ignores it — `SyncPlayController` owns that half.
    private func handle(_ message: JellyfinSocketMessage, appState: AppState, toasts: ToastCenter) {
        switch message {
        case .syncPlayCommand, .syncPlayGroupUpdate:
            break
        case .play(let request):
            // Only "start this now" is honored: this app has no playback queue,
            // so PlayNext / PlayLast have nothing truthful to map onto.
            guard request.isPlayNow, let itemId = request.itemIds.first else { return }
            // Same shape validation as the public `cinemax://` scheme. The
            // socket is authenticated so the id is not attacker-supplied in the
            // deep-link sense, but a malformed id must fail here rather than
            // drive a lookup — one definition, both entry points.
            guard AppState.isValidItemId(itemId) else {
                logger.error("Remote play command carried a malformed item id — ignored")
                return
            }
            appState.pendingIntentPlaybackItemId = itemId
            appState.pendingDeepLinkItemId = itemId
        case .displayMessage(let message):
            // The only `GeneralCommandType` the capability post advertises.
            if let header = message.header {
                toasts.info(header, message: message.text)
            } else {
                toasts.info(message.text)
            }
        }
    }
}
