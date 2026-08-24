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
        .onChange(of: scenePhase, initial: true) { oldPhase, phase in
            switch phase {
            case .active:
                reviewPrompter.noteBecameActive()
                RemoteSettings.shared.refresh()
                if oldPhase == .background {
                    KartverketTileProxy.restartAfterBackgrounding()
                }
            case .background:
                reviewPrompter.noteEnteredBackground()
            default: break
            }
        }
    }
}
