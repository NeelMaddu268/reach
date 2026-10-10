import SwiftUI

@main
struct ReachApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // The phone lives on a chest mount; never let it sleep mid-demo.
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
