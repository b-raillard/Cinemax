import Foundation
import Darwin

/// A Jellyfin server found on the local network via UDP broadcast.
public struct DiscoveredJellyfinServer: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let address: String

    public init(id: String, name: String, address: String) {
        self.id = id
        self.name = name
        self.address = address
    }
}

/// Jellyfin's built-in auto-discovery: broadcast `"Who is JellyfinServer?"` on UDP/7359
/// and collect JSON responses of the form `{"Address":"http://…","Id":"…","Name":"…"}`.
///
/// Triggers the iOS/tvOS local-network permission prompt on first use; a denied prompt
/// yields an empty result set (no error surfaced — the UI simply shows "no servers found").
public enum JellyfinServerDiscovery {
    /// Broadcast-and-listen sweep. Caller awaits the full `timeout` before results return.
    public static func discover(timeout: TimeInterval = 2.5) async -> [DiscoveredJellyfinServer] {
        await Task.detached(priority: .userInitiated) {
            performDiscovery(timeout: timeout)
        }.value
    }

    private static func performDiscovery(timeout: TimeInterval) -> [DiscoveredJellyfinServer] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var broadcast: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return []
        }

        // Short recv timeout so the loop checks the overall deadline frequently.
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Probe both the limited broadcast (255.255.255.255) and each interface's directed
        // broadcast (e.g. 192.168.1.255). Many consumer Wi-Fi routers silently drop limited
        // broadcasts but forward directed ones — covering both forms maximises the chance the
        // probe actually reaches a Jellyfin server on the same LAN.
        var targets = Set<in_addr_t>([in_addr_t(0xFFFF_FFFF)])
        targets.formUnion(subnetBroadcastAddresses())

        let payload = [UInt8]("Who is JellyfinServer?".utf8)
        var sentAny = false
        for target in targets {
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = in_port_t(7359).bigEndian
            dest.sin_addr.s_addr = target

            let sent: Int = payload.withUnsafeBufferPointer { buf in
                withUnsafePointer(to: &dest) { destPtr in
                    destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        sendto(fd, buf.baseAddress, payload.count, 0,
                               sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent > 0 { sentAny = true }
        }
        guard sentAny else { return [] }

        var servers: [String: DiscoveredJellyfinServer] = [:]
        let bufferSize = 2048
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var src = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let n: Int = buffer.withUnsafeMutableBufferPointer { buf in
                withUnsafeMutablePointer(to: &src) { srcPtr in
                    srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        recvfrom(fd, buf.baseAddress, bufferSize, 0, sockPtr, &srcLen)
                    }
                }
            }

            if n > 0 {
                let data = Data(buffer[0..<n])
                if let server = decode(data: data) {
                    servers[server.id] = server
                }
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                break
            }
        }

        return servers.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Directed-broadcast address (e.g. `192.168.1.255`) for every active, non-loopback,
    /// broadcast-capable IPv4 interface. Empty if the device has no IPv4 connectivity.
    private static func subnetBroadcastAddresses() -> [in_addr_t] {
        var result: [in_addr_t] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let c = cursor {
            defer { cursor = c.pointee.ifa_next }
            let flags = Int32(c.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_BROADCAST) != 0 else { continue }
            guard let addr = c.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard let dst = c.pointee.ifa_dstaddr else { continue }
            let sin = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            result.append(sin.sin_addr.s_addr)
        }
        return result
    }

    private static func decode(data: Data) -> DiscoveredJellyfinServer? {
        struct Payload: Decodable {
            let Address: String?
            let Id: String?
            let Name: String?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data),
              let id = p.Id, !id.isEmpty,
              let name = p.Name, !name.isEmpty,
              let address = p.Address, !address.isEmpty else {
            return nil
        }
        return DiscoveredJellyfinServer(id: id, name: name, address: address)
    }
}
