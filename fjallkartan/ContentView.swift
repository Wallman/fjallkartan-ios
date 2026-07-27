import SwiftUI

struct ContentView: View {
    @State private var zoomLevel: Double = 0
    @State private var metersPerPoint: Double = 0

    var body: some View {
        MapView(zoomLevel: $zoomLevel, metersPerPoint: $metersPerPoint)
            .ignoresSafeArea()
            .overlay(alignment: .bottomLeading) {
                ScaleBarView(metersPerPoint: metersPerPoint)
                    .padding([.bottom, .leading], 16)
            }
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

struct ScaleBarView: View {
    let metersPerPoint: Double

    private static let niceDistances: [Double] = [
        20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000, 200_000, 500_000
    ]
    private static let maxBarWidth: Double = 120

    private var niceScale: (points: Double, label: String) {
        guard metersPerPoint > 0 else { return (60, "") }
        let maxMeters = metersPerPoint * Self.maxBarWidth
        let dist = Self.niceDistances.last(where: { $0 <= maxMeters }) ?? Self.niceDistances[0]
        let label = dist >= 1000 ? "\(Int(dist / 1000)) km" : "\(Int(dist)) m"
        return (dist / metersPerPoint, label)
    }

    var body: some View {
        let (barPts, label) = niceScale
        VStack(alignment: .center, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
            ZStack(alignment: .center) {
                Rectangle()
                    .frame(width: barPts, height: 2)
                HStack(spacing: 0) {
                    Rectangle().frame(width: 2, height: 8)
                    Spacer()
                    Rectangle().frame(width: 2, height: 8)
                }
                .frame(width: barPts)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

#Preview {
    ContentView()
}
