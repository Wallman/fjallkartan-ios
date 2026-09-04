import SwiftUI

/// Covers the map while its first tiles are still loading, so the app never
/// shows a blank/white screen right after launch. Dismissed by `ContentView`
/// once `MapView` reports its first fully rendered frame (see
/// `MapView.Coordinator.mapViewDidFinishRenderingMap`), or after a timeout so
/// a slow/offline connection doesn't leave it on screen indefinitely.
struct MapLoadingView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading map…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
        .accessibilityIdentifier("mapLoading.overlay")
    }
}

#Preview {
    MapLoadingView()
}
