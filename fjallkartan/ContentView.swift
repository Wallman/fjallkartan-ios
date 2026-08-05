import CoreLocation
import MapKit
import SwiftUI

struct ContentView: View {
    @State private var zoomLevel: Double = 0
    @State private var metersPerPoint: Double = 0
    @State private var visibleMapRect = MKMapRect.world
    @State private var measurement = DistanceMeasurement()
    @State private var search = PlaceSearchModel()
    @State private var isSearchPresented = false
    @State private var isPickingRegion = false
    @State private var isOfflineRegionsListPresented = false
    @State private var isLegendPresented = false
    @State private var offlineModel = CustomTileOverlay.defaultStore.map(OfflineRegionsModel.init)

    var body: some View {
        MapView(zoomLevel: $zoomLevel,
                metersPerPoint: $metersPerPoint,
                visibleMapRect: $visibleMapRect,
                measurement: measurement,
                isMeasuring: measurement.isMeasuring,
                routeVersion: measurement.version,
                selectedPlace: search.selection,
                isRegionPreviewVisible: isPickingRegion)
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
                Text("Z \(Int(zoomLevel))")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding([.top, .leading], 16)
            }
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    Button {
                        isSearchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Sök plats")

                    MeasureControlsView(measurement: measurement)

                    Button {
                        isLegendPresented = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Teckenförklaring")

                    if let offlineModel {
                        Button {
                            isPickingRegion.toggle()
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(isPickingRegion ? Color.orange : Color.primary)
                                .symbolVariant(isPickingRegion ? .fill : .none)
                                .frame(width: 40, height: 40)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityLabel(isPickingRegion ? "Cancel offline region" : "Download offline region")
                        .sheet(isPresented: $isOfflineRegionsListPresented) {
                            OfflineRegionsSheet(model: offlineModel)
                        }

                        if isPickingRegion {
                            Button {
                                isOfflineRegionsListPresented = true
                            } label: {
                                Image(systemName: "tray.full")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                    .frame(width: 40, height: 40)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .accessibilityLabel("Manage offline regions")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isPickingRegion)
                .padding([.top, .trailing], 16)
            }
            .overlay(alignment: .top) {
                MeasureReadoutView(measurement: measurement)
                    .padding(.top, 16)
            }
            .overlay(alignment: .bottom) {
                if isPickingRegion, let offlineModel {
                    RegionDownloadBar(
                        model: offlineModel,
                        rect: offlineRegionPreviewRect(for: visibleMapRect),
                        onDownload: {
                            isPickingRegion = false
                            isOfflineRegionsListPresented = true
                        }
                    )
                    .padding(.bottom, 16)
                }
            }
            .sheet(isPresented: $isSearchPresented) {
                PlaceSearchSheet(model: search)
            }
            .sheet(isPresented: $isLegendPresented) {
                LegendSheet()
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
