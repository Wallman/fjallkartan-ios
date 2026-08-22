import SwiftUI

enum DebugSettings {
    static let showsZoomOverlayKey = "debug.showsZoomOverlay"
}

struct DebugSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DebugSettings.showsZoomOverlayKey) private var showsZoomOverlay = false

    var body: some View {
        NavigationStack {
            List {
                Toggle(isOn: $showsZoomOverlay) {
                    Text(verbatim: "Show zoom level")
                }
            }
            .navigationTitle(Text(verbatim: "Debug"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
        }
    }
}

#Preview {
    DebugSheet()
}
