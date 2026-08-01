import CoreLocation
import SwiftUI

struct ContentView: View {
    @State private var zoomLevel: Double = 0
    @State private var metersPerPoint: Double = 0
    @State private var measurement = DistanceMeasurement()
    @State private var showSearch = false
    @State private var cameraTarget: CLLocationCoordinate2D? = nil
    @State private var cameraVersion = 0

    var body: some View {
        MapView(zoomLevel: $zoomLevel,
                metersPerPoint: $metersPerPoint,
                measurement: measurement,
                isMeasuring: measurement.isMeasuring,
                routeVersion: measurement.version,
                cameraTarget: cameraTarget,
                cameraVersion: cameraVersion)
            .ignoresSafeArea()
            .overlay(alignment: .bottomLeading) {
                ScaleBarView(metersPerPoint: metersPerPoint)
                    .padding([.bottom, .leading], 16)
            }
            .overlay(alignment: .bottomTrailing) {
                CopyrightNoticeView()
                    .padding([.bottom, .trailing], 16)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Z \(Int(zoomLevel))")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Search places")
                }
                .padding([.top, .leading], 16)
            }
            .overlay(alignment: .topTrailing) {
                MeasureControlsView(measurement: measurement)
                    .padding([.top, .trailing], 16)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if showSearch {
                        SearchView(isPresented: $showSearch) { coordinate in
                            cameraTarget = coordinate
                            cameraVersion += 1
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                    MeasureReadoutView(measurement: measurement)
                        .padding(.top, showSearch ? 0 : 16)
                }
            }
    }
}

struct MeasureControlsView: View {
    @Bindable var measurement: DistanceMeasurement

    var body: some View {
        VStack(spacing: 8) {
            Button {
                measurement.isMeasuring.toggle()
            } label: {
                Image(systemName: "ruler")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolVariant(measurement.isMeasuring ? .fill : .none)
                    .foregroundStyle(measurement.isMeasuring ? Color.orange : Color.primary)
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel(measurement.isMeasuring ? "Stop measuring" : "Measure distance")

            if measurement.isMeasuring {
                Button {
                    measurement.undoLastStroke()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(!measurement.canUndo)
                .accessibilityLabel("Undo last stroke")

                Button {
                    measurement.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(measurement.isEmpty)
                .accessibilityLabel("Clear measurement")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: measurement.isMeasuring)
    }
}

struct MeasureReadoutView: View {
    let measurement: DistanceMeasurement

    var body: some View {
        if measurement.isMeasuring || !measurement.isEmpty {
            VStack(spacing: 2) {
                Text(measurement.formattedDistance)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if measurement.isEmpty {
                    Text("Drag to trace a route")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Measured distance \(measurement.formattedDistance)")
        }
    }
}

struct CopyrightNoticeView: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("©Kartverket")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Topografisk webbkarta ©Lantmäteriet")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
