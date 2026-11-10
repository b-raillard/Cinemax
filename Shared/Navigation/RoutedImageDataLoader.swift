import Foundation
import CinemaxKit
import Nuke

/// The identity → dial mapping image requests are rewritten through. Image URLs
/// and Nuke's cache keys are built on the server's public (identity) URL; only
/// the transport dials the LAN address, so a route change never invalidates the
/// 500 MB disk cache.
final class ImageRouteTable: @unchecked Sendable {
    static let shared = ImageRouteTable()

    private let lock = NSLock()
    private var identity: URL?
    private var dial: URL?

    /// `dial` nil or equal to `identity` means no rewrite.
    func set(identity: URL?, dial: URL?) {
        lock.lock(); defer { lock.unlock() }
        if let identity, let dial, dial != identity {
            self.identity = identity
            self.dial = dial
        } else {
            self.identity = nil
            self.dial = nil
        }
    }

    func rewrite(_ request: URLRequest) -> URLRequest {
        lock.lock()
        let identity = self.identity, dial = self.dial
        lock.unlock()
        guard let identity, let dial, let url = request.url,
              let rewritten = ServerRoutePolicy.rewrite(url, identityBase: identity, dialBase: dial)
        else { return request }
        var copy = request
        copy.url = rewritten
        return copy
    }
}

/// Wraps Nuke's configured `DataLoader` (which keeps `ServerTrustDelegate` and
/// its session config) and swaps each request's base identity → dial at load time.
final class RoutedImageDataLoader: DataLoading, @unchecked Sendable {
    private let base: any DataLoading
    private let table: ImageRouteTable

    init(wrapping base: any DataLoading, table: ImageRouteTable = .shared) {
        self.base = base
        self.table = table
    }

    func loadData(with request: URLRequest,
                  didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        base.loadData(with: table.rewrite(request), didReceiveData: didReceiveData, completion: completion)
    }
}
