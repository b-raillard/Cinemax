import Foundation

/// Helpers for converting Jellyfin tick values (100-nanosecond units).
/// 1 second = 10,000,000 ticks
/// 1 minute = 600,000,000 ticks

public extension Int {
    var jellyfinMinutes: Int { self / 600_000_000 }
    var jellyfinSeconds: Double { Double(self) / 10_000_000 }
}

public extension Int64 {
    var jellyfinMinutes: Int { Int(self / 600_000_000) }
    var jellyfinSeconds: Double { Double(self) / 10_000_000 }
}
