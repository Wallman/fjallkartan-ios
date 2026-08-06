import CoreLocation
import MapKit
import StoreKit
import SwiftUI

struct ContentView: View {
    @Environment(\.requestReview) private var requestReview
    @State private var metersPerPoint: Double = 0
    @State private var visibleMapRect = MKMapRect.world
    @State private var measurement = DistanceMeasurement()
    @State private var search = PlaceSearchModel()
    @State private var isSearchPresented = false
    @State private var isPickingRegion = false
    @State private var isOfflineRegionsListPresented = false
    @State private var isLegendPresented = false
    @State private var isAboutPresented = false
    @State private var offlineModel = CustomTileOverlay.defaultStore.map(OfflineRegionsModel.init)

    @State private var measuringStartVersion = 0
    private let reviewPrompter = ReviewPrompter.shared

    /// Nothing is covering or competing with the map, so a system review
    /// prompt would not interrupt anything the user is in the middle of.
    private var isQuietForReviewPrompt: Bool {
        !measurement.isMeasuring
            && !isSearchPresented
            && !isOfflineRegionsListPresented
            && !isLegendPresented
            && !isAboutPresented
            && !isPickingRegion
    }

    var body: some View {
        MapView(metersPerPoint: $metersPerPoint,
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
                AboutButton { isAboutPresented = true }
                    .padding([.bottom, .trailing], 20)
                    .transition(.opacity)
                    .sheet(isPresented: $isAboutPresented) {
                        AboutSheet()
                    }
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
                        .sheet(isPresented: $isOfflineRegionsListPresented) {
                            OfflineRegionsSheet(model: offlineModel)
                        }

                        if isPickingRegion {
                            Button {
                                isOfflineRegionsListPresented = true
                            } label: {
                                Image(systemName: "tray.full")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Color.blue)
                                    .frame(width: 40, height: 40)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isPickingRegion)
                .padding(.top, 64)
                .padding(.trailing, 16)
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
            .onChange(of: measurement.isMeasuring) { _, isMeasuring in
                if isMeasuring {
                    measuringStartVersion = measurement.version
                } else if measurement.version > measuringStartVersion,
                          measurement.committedMeters >= ReviewPrompter.minimumMeasurementMeters {
                    reviewPrompter.recordCompletedMeasurement()
                }
            }
            // Re-evaluated both when a prompt falls due and when the map goes
            // quiet again, so a prompt earned while the regions sheet was open
            // is still shown once it is dismissed.
            .task(id: ReviewPromptTrigger(token: reviewPrompter.pendingToken,
                                          isQuiet: isQuietForReviewPrompt)) {
                guard reviewPrompter.pendingToken > 0, isQuietForReviewPrompt else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, isQuietForReviewPrompt else { return }
                if reviewPrompter.consumePendingPrompt() { requestReview() }
            }
    }
}

private struct ReviewPromptTrigger: Equatable {
    let token: Int
    let isQuiet: Bool
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

                Button {
                    measurement.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(measurement.isEmpty)
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
                .foregroundStyle(.black)
            ZStack(alignment: .center) {
                Rectangle()
                    .frame(width: barPts, height: 2)
                    .foregroundStyle(.black)
                HStack(spacing: 0) {
                    Rectangle().frame(width: 2, height: 8)
                    Spacer()
                    Rectangle().frame(width: 2, height: 8)
                }
                .frame(width: barPts)
                .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

#Preview {
    ContentView()
}
