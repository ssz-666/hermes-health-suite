import SwiftUI

@main
struct HermesHealthBridgeApp: App {
    init() {
        BackgroundSyncService.shared.registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await BackgroundSyncService.shared.configureAutomaticSync()
                }
        }
    }
}
