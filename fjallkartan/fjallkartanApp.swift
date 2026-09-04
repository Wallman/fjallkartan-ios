import SwiftUI
import BackgroundTasks

@main
struct fjallkartanApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let reviewPrompter = ReviewPrompter.shared

    init() {
        NetworkTestHooks.installIfNeeded()
        MetricKitReporter.shared.start()
        MapLibreLoggingBridge.start()
        if #available(iOS 26, *) {
            OfflineRegionsModel.registerBackgroundTask()
            OfflineRegionsModel.allowBackgroundDownloads()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                reviewPrompter.noteBecameActive()
                RemoteSettings.shared.refresh { settings in
                    guard let settings else { return }
                    Task { @MainActor in
                        ForceUpdateGate.shared.evaluate(minAppVersion: settings.minAppVersion)
                    }
                }
                NorwayTileProxy.ensureRunning()
            case .background:
                reviewPrompter.noteEnteredBackground()
                if !OfflineRegionsModel.shared.hasActiveBackgroundContinuation {
                    NorwayTileProxy.stop()
                }
            default: break
            }
        }
    }
}
