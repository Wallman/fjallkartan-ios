import SwiftUI
import MapKit

struct ContentView: View {
    @State private var tappedTile: TileInfo?

    var body: some View {
        MapView(tappedTile: $tappedTile)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                if let info = tappedTile {
                    TileInfoBanner(info: info) {
                        tappedTile = nil
                    }
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: tappedTile != nil)
    }
}

struct TileInfoBanner: View {
    let info: TileInfo
    let onDismiss: () -> Void

    private var coverage: TileCoverage {
        let path = MKTileOverlayPath(x: info.x, y: info.y, z: info.z, contentScaleFactor: 1)
        return TileCoverageResolver.shared.coverage(for: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tile Info")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Divider()
            Label("z/x/y  \(info.z) / \(info.x) / \(info.y)", systemImage: "square.grid.2x2")
                .font(.subheadline.monospacedDigit())
            let c = coverage
            Label("Norway: \(c.norway ? "✓" : "✗")   Sweden: \(c.sweden ? "✓" : "✗")", systemImage: "map")
                .font(.subheadline.monospacedDigit())
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
        .padding(.horizontal, 20)
    }
}

#Preview {
    ContentView()
}
