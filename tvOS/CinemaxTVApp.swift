import SwiftUI

@main
struct CinemaxTVApp: App {
    var body: some Scene {
        WindowGroup {
            AppNavigation()
                .preferredColorScheme(.dark)
        }
    }
}
