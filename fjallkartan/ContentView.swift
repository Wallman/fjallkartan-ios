import SwiftUI

struct ContentView: View {
    @State private var zoomLevel: Double = 0

    var body: some View {
        MapView(zoomLevel: $zoomLevel)
            .ignoresSafeArea()
            .overlay(alignment: .bottomTrailing) {
                Text("Z \(Int(zoomLevel))")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding([.bottom, .trailing], 16)
            }
    }
}

#Preview {
    ContentView()
}
