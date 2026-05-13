import SwiftUI
import UIKit

@main
struct CinemaxApp: App {
    @UIApplicationDelegateAdaptor(CinemaxAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppNavigation()
        }
    }
}

/// Captures the system-supplied completion handler for background URLSession
/// events. Required so iOS knows our background-download bookkeeping (move to
/// `Application Support/Downloads/files/`, update the catalog) finished and the
/// process can be suspended again.
final class CinemaxAppDelegate: NSObject, UIApplicationDelegate {
    /// Set by the OS when the app is woken to handle background-download
    /// events. Read & cleared by `DownloadManager.Adapter` once
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` fires.
    nonisolated(unsafe) static var backgroundSessionCompletion: (() -> Void)?

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Self.backgroundSessionCompletion = completionHandler
    }
}
