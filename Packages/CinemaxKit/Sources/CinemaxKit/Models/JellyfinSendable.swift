import Foundation
@preconcurrency import JellyfinAPI

// MARK: - Retroactive Sendable conformances
//
// The Jellyfin SDK predates Swift 6 strict concurrency and ships its public
// enums (e.g. `BaseItemKind`) without explicit `Sendable` conformance. As
// raw-`String` enums with no associated values, they are *trivially* safe to
// send across actor boundaries — the missing conformance is purely an
// oversight in the SDK module.
//
// `@preconcurrency import JellyfinAPI` downgrades old-style Sendable warnings,
// but does **not** satisfy the newer "sending" / region-based isolation
// checks introduced in Swift 6.1. Those still see the type as non-Sendable
// and refuse to let optionals/collections of it cross an async boundary
// (e.g. `let typeFilter: [BaseItemKind]? = …` then passed to an `actor`
// method or captured by a `@Sendable` closure).
//
// Declaring an explicit `@retroactive @unchecked Sendable` conformance here
// lets the compiler treat these enums as Sendable everywhere — the closest
// approximation we can give it short of patching the SDK upstream. Keep
// additions minimal and limited to value types that genuinely *are* safe.
extension BaseItemKind: @retroactive @unchecked Sendable {}
