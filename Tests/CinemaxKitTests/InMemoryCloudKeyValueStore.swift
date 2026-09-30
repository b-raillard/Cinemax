import Foundation
@testable import Cinemax

/// A `CloudKeyValueStore` held in memory — never the real iCloud account.
/// `simulateExternalChange` plays the part of the OTHER device: it writes the
/// value and delivers `didChangeExternallyNotification` to every listener,
/// which a local `set` does not (exactly like the real store).
@MainActor
final class InMemoryCloudKeyValueStore: CloudKeyValueStore {
    private(set) var values: [String: Data] = [:]
    private(set) var synchronizeCount = 0
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    func data(forKey key: String) -> Data? {
        values[key]
    }

    func set(_ data: Data?, forKey key: String) {
        values[key] = data
    }

    @discardableResult
    func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }

    func externalChanges() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        continuations[id] = continuation
        return stream
    }

    /// Whether a listener is attached yet — the store's listening task starts
    /// asynchronously, so a test waits for it before simulating a change.
    var hasListeners: Bool { !continuations.isEmpty }

    func simulateExternalChange(_ data: Data?, forKey key: String) {
        values[key] = data
        for continuation in continuations.values { continuation.yield() }
    }
}
