import SwiftUI

@main
struct fjallkartanApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let reviewPrompter = ReviewPrompter.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: reviewPrompter.noteBecameActive()
            case .background: reviewPrompter.noteEnteredBackground()
            default: break
            }
        }
    }
}
