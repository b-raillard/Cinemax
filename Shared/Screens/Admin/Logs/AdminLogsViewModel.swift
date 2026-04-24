#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminLogsViewModel {
    var files: [LogFile] = []
    var isLoading = false
    var errorMessage: String?

    var isEmpty: Bool {
        !isLoading && errorMessage == nil && files.isEmpty
    }

    func load(using apiClient: any APIClientProtocol) async {
        isLoading = files.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            files = try await apiClient.getServerLogs()
                .sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor @Observable
final class AdminLogViewerViewModel {
    /// Hard cap on rendered log size. Jellyfin logs can exceed 10 MB on a
    /// busy server and iOS SwiftUI `Text` chokes on those — we truncate
    /// at 200 KB which is still ~2-3k lines of typical log output.
    static let maxBytes = 200_000

    let fileName: String
    var contents: String = ""
    var isLoading = false
    var isTruncated = false
    var originalSize: Int = 0
    var errorMessage: String?

    init(fileName: String) {
        self.fileName = fileName
    }

    func load(using apiClient: any APIClientProtocol) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let full = try await apiClient.getLogFileContents(name: fileName)
            originalSize = full.utf8.count
            if originalSize > Self.maxBytes {
                // Take the LAST `maxBytes` — the tail of a log is what admins
                // actually care about (latest errors). We also rewind to the
                // next newline so the first line isn't a visually broken
                // half-line.
                let suffix = full.suffix(Self.maxBytes)
                if let newlineIdx = suffix.firstIndex(of: "\n") {
                    contents = String(suffix[suffix.index(after: newlineIdx)...])
                } else {
                    contents = String(suffix)
                }
                isTruncated = true
            } else {
                contents = full
                isTruncated = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
