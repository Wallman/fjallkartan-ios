import SwiftUI

@main
struct fjallkartanApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let reviewPrompter = ReviewPrompter.shared

    init() {
        MetricKitReporter.shared.start()
        MapLibreLoggingBridge.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                reviewPrompter.noteBecameActive()
                RemoteSettings.shared.refresh()
                KartverketTileProxy.ensureRunning()
            case .background:
                reviewPrompter.noteEnteredBackground()
                KartverketTileProxy.stop()
            default: break
            }
        }
    }
}
