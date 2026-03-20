import SwiftUI

@main
struct CinemaxApp: App {
    var body: some Scene {
        WindowGroup {
            AppNavigation()
                .preferredColorScheme(.dark)
        }
    }
}
