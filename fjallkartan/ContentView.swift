import CoreLocation
import MapKit
import StoreKit
import SwiftUI

struct ContentView: View {
    @Environment(\.requestReview) private var requestReview
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var metersPerPoint: Double = 0
    @State private var visibleMapRect = MKMapRect.world
    @State private var measurement = DistanceMeasurement()
    @State private var elevation = ElevationProfile()
    @State private var search = PlaceSearchModel()
    @State private var isSearchPresented = false
    @State private var isPickingRegion = false
    @State private var isOfflineRegionsListPresented = false
    @State private var isLegendPresented = false
    @State private var isAboutPresented = false
    @State private var isSavedRoutesPresented = false
    @State private var isElevationPresented = false
    @State private var isSlopeLayerVisible = false
    @State private var isShowingMoreControls = false
    @State private var visibleTip: GuideTip?
    @State private var didSaveRoute = false
    @State private var offlineModel = OfflineTileStore.shared.map(OfflineRegionsModel.init)
    @State private var savedRoutesModel = (try? SavedRouteStore()).map(SavedRoutesModel.init)
    @State private var savedPinsModel = (try? SavedPinStore()).map(SavedPinsModel.init)
    @State private var routeFitToken = 0 // Needed to avoid re-centering when drawing
    @State private var pinDetail: SavedPin?

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
            && !isSavedRoutesPresented
            && !isElevationPresented
            && pinDetail == nil
    }

    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    private var isAnyMoreControlActive: Bool { isSlopeLayerVisible || isPickingRegion }

    private var tipBottomPadding: CGFloat {
        if isPickingRegion { return 130 }
        if isCompactHeight { return 120 }
        return 76
    }

    private func isStillRelevant(_ tip: GuideTip) -> Bool {
        switch tip {
        case .measuringGestures: measurement.isMeasuring
        case .elevationReadout: elevation.hasData && !isElevationPresented
        case .regionPreview: isPickingRegion
        case .routeSaved: didSaveRoute
        }
    }

    private func noteRouteSaved() {
        guard !GuideTip.routeSaved.hasBeenSeen else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            didSaveRoute = true
            updateVisibleTip()
        }
    }

    private func dismissTip() {
        visibleTip = nil
        didSaveRoute = false
        updateVisibleTip()
    }

    /// Shows the highest-priority unseen tip whose moment has arrived, and
    /// retires the visible one as soon as its moment has passed.
    private func updateVisibleTip() {
        if let visibleTip, !isStillRelevant(visibleTip) {
            self.visibleTip = nil
        }
        guard visibleTip == nil else { return }
        let candidate = [GuideTip.routeSaved, .measuringGestures, .regionPreview, .elevationReadout]
            .first { isStillRelevant($0) && !$0.hasBeenSeen }
        guard let candidate else { return }
        candidate.markSeen()
        visibleTip = candidate
    }

    @ViewBuilder
    private func mapControls() -> some View {
        let layout = isCompactHeight
            ? AnyLayout(HStackLayout(alignment: .top, spacing: ButtonStyleModifier.stackSpacing))
            : AnyLayout(VStackLayout(spacing: ButtonStyleModifier.stackSpacing))
        // Captions draw wider than their button but don't lay out that way, so
        // the column keeps the plain button inset.
        let trailingInset: CGFloat = 16

        layout {
            Button {
                isSearchPresented = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .buttonStyle()
            }

            MeasureControlsView(measurement: measurement,
                                elevation: elevation,
                                savedRoutesModel: savedRoutesModel,
                                isHorizontal: isCompactHeight,
                                onRouteSaved: noteRouteSaved)

            if let savedRoutesModel {
                Button {
                    isSavedRoutesPresented = true
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .buttonStyle()
                }
                .sheet(isPresented: $isSavedRoutesPresented) {
                    SavedRoutesSheet(model: savedRoutesModel,
                                    hasUnsavedRoute: !measurement.isEmpty
                                        && measurement.hasUnsavedChanges) { route in
                        measurement.load(route)
                        elevation.load(route)
                        routeFitToken += 1
                    }
                }
            }

            Button {
                isShowingMoreControls.toggle()
            } label: {
                Image(systemName: isShowingMoreControls ? "chevron.up" : "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    // Collapsed, this button is the only trace of a layer that
                    // may well be switched on, so it carries the active tint.
                    .foregroundStyle(!isShowingMoreControls && isAnyMoreControlActive
                                        ? Color.orange : Color.primary)
                    .buttonStyle()
            }

            if isShowingMoreControls {
                Button {
                    isSlopeLayerVisible.toggle()
                } label: {
                    Image(systemName: "triangle.righthalf.filled")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSlopeLayerVisible ? Color.orange : Color.primary)
                        .buttonStyle(MapControlLabel.slope)
                }
                .transition(.scale.combined(with: .opacity))

                Button {
                    isLegendPresented = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .buttonStyle(MapControlLabel.symbols)
                }
                .transition(.scale.combined(with: .opacity))

                if offlineModel != nil {
                    Button {
                        isPickingRegion.toggle()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isPickingRegion ? Color.orange : Color.primary)
                            .symbolVariant(isPickingRegion ? .fill : .none)
                            .buttonStyle(MapControlLabel.download)
                    }
                    .transition(.scale.combined(with: .opacity))

                    if isPickingRegion {
                        Button {
                            isOfflineRegionsListPresented = true
                        } label: {
                            Image(systemName: "tray.full")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color.blue)
                                .buttonStyle(MapControlLabel.regions)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPickingRegion)
        .environment(\.mapControlsAreHorizontal, isCompactHeight)
        .animation(.easeInOut(duration: 0.2), value: isShowingMoreControls)
        .padding(.top, isCompactHeight ? 16 : 125)
        .padding(.trailing, isCompactHeight ? trailingInset + 52 : trailingInset)
    }

    var body: some View {
        MapView(metersPerPoint: $metersPerPoint,
                visibleMapRect: $visibleMapRect,
                measurement: measurement,
                isMeasuring: measurement.isMeasuring,
                routeVersion: measurement.version,
                routeFitToken: routeFitToken,
                selectedPlace: search.selection,
                isRegionPreviewVisible: isPickingRegion,
                isSlopeLayerVisible: isSlopeLayerVisible,
                pins: savedPinsModel?.pins ?? [],
                onDropPin: { coordinate in
                    savedPinsModel?.save(SavedPin(coordinate: Coord(coordinate)))
                },
                onSavePlace: { place in
                    savedPinsModel?.save(SavedPin(coordinate: Coord(place.coordinate), name: place.name))
                },
                onDismissPlace: {
                    search.selection = nil
                },
                onOpenPinDetail: { pin in
                    pinDetail = pin
                })
            .ignoresSafeArea()
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    if isCompactHeight {
                        MeasureReadoutView(measurement: measurement, elevation: elevation) {
                            isElevationPresented = true
                        } onClose: {
                            measurement.clear()
                            elevation.clear()
                        }
                    }
                    ScaleBarView(metersPerPoint: metersPerPoint)
                }
                .padding([.bottom, .leading], 16)
            }
            .overlay(alignment: .bottomTrailing) {
                AboutButton { isAboutPresented = true }
                    .padding([.bottom, .trailing], 18)
                    .transition(.opacity)
                    .sheet(isPresented: $isAboutPresented) {
                        AboutSheet()
                    }
            }
            .overlay(alignment: .topTrailing) {
                mapControls()
            }
            .overlay(alignment: .top) {
                if !isCompactHeight {
                    MeasureReadoutView(measurement: measurement, elevation: elevation) {
                        isElevationPresented = true
                    } onClose: {
                        measurement.clear()
                        elevation.clear()
                    }
                    .padding(.top, 16)
                }
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
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .overlay(alignment: .bottom) {
                if let visibleTip {
                    GuideTipBadge(tip: visibleTip) { dismissTip() }
                        .padding(.horizontal, 24)
                        .padding(.bottom, tipBottomPadding)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: visibleTip)
            .sheet(isPresented: $isSearchPresented) {
                PlaceSearchSheet(model: search)
            }
            .sheet(isPresented: $isLegendPresented) {
                LegendSheet()
            }
            .sheet(isPresented: $isOfflineRegionsListPresented) {
                if let offlineModel {
                    OfflineRegionsSheet(model: offlineModel)
                }
            }            .sheet(isPresented: $isElevationPresented) {
                ElevationProfileSheet(profile: elevation)
            }
            .sheet(item: $pinDetail) { pin in
                PinDetailSheet(pin: pin,
                              onSave: { updated in savedPinsModel?.save(updated) },
                              onDelete: { savedPinsModel?.delete(pin) })
            }
            .onChange(of: TipTrigger(isMeasuring: measurement.isMeasuring,
                                     isPickingRegion: isPickingRegion,
                                     hasElevation: elevation.hasData,
                                     isElevationPresented: isElevationPresented,
                                     didSaveRoute: didSaveRoute),
                      initial: true) { _, _ in
                updateVisibleTip()
            }
            .task(id: visibleTip) {
                guard visibleTip != nil else { return }
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                dismissTip()
            }
            .onChange(of: measurement.isMeasuring) { _, isMeasuring in
                if isMeasuring {
                    measuringStartVersion = measurement.version
                } else if measurement.version > measuringStartVersion,
                          measurement.committedMeters >= ReviewPrompter.minimumMeasurementMeters {
                    reviewPrompter.recordCompletedMeasurement()
                }
            }
            // Debounced so tracing a long route in several strokes does not
            // start a tile fetch per stroke; `task(id:)` cancels the previous
            // run whenever the route changes again.
            .task(id: measurement.version) {
                guard !measurement.isEmpty else {
                    elevation.clear()
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await elevation.update(for: measurement.coordinates)
            }
            // Re-evaluated both when a prompt falls due and when the map goes
            // quiet again, so a prompt earned while the regions sheet was open
            // is still shown once it is dismissed.
            .task(id: ReviewPromptTrigger(token: reviewPrompter.pendingToken,
                                          isQuiet: isQuietForReviewPrompt)) {
                guard reviewPrompter.pendingToken > 0, isQuietForReviewPrompt else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, isQuietForReviewPrompt, await NetworkCheck.hasConnectivity() else { return }
                if reviewPrompter.consumePendingPrompt() { requestReview() }
            }
    }
}

private struct ReviewPromptTrigger: Equatable {
    let token: Int
    let isQuiet: Bool
}

private struct TipTrigger: Equatable {
    let isMeasuring: Bool
    let isPickingRegion: Bool
    let hasElevation: Bool
    let isElevationPresented: Bool
    let didSaveRoute: Bool
}

enum MapControlLabel {
    static let slope: LocalizedStringResource = "Slope"
    static let symbols: LocalizedStringResource = "Symbols"
    static let download: LocalizedStringResource = "Download"
    static let regions: LocalizedStringResource = "Regions"
    static let undo: LocalizedStringResource = "Undo"
    static let clear: LocalizedStringResource = "Clear"
    static let save: LocalizedStringResource = "Save"

    static let all: [LocalizedStringResource] = [
        slope, symbols, download, regions, undo, clear, save
    ]
}

extension EnvironmentValues {
    @Entry var mapControlsAreHorizontal = false
}

struct ButtonStyleModifier: ViewModifier {
    static let diameter: CGFloat = 44
    static let labelWidth: CGFloat = 64
    static let stackSpacing: CGFloat = 6
    static let unlabelledSpacing: CGFloat = 6

    let label: LocalizedStringResource?
    @Environment(\.mapControlsAreHorizontal) private var isHorizontal

    func body(content: Content) -> some View {
        VStack(spacing: 1) {
            circle(content)
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .frame(width: Self.labelWidth)
                    .frame(width: Self.diameter)
                    .shadow(color: .white.opacity(0.9), radius: 1.5)
            }
        }
        .padding(isHorizontal ? .trailing : .bottom,
                 label == nil ? Self.unlabelledSpacing : 0)
    }

    @ViewBuilder
    private func circle(_ content: Content) -> some View {
        let sized = content.frame(width: Self.diameter, height: Self.diameter)

        if #available(iOS 26.0, *) {
            sized
                .glassEffect(.regular, in: Circle())
                .environment(\.colorScheme, .light)
        } else {
            sized
                .background(.thickMaterial, in: Circle())
                .environment(\.colorScheme, .light)
        }
    }
}

extension View {
    func buttonStyle(_ label: LocalizedStringResource? = nil) -> some View {
        modifier(ButtonStyleModifier(label: label))
    }
}

struct MeasureControlsView: View {
    @Bindable var measurement: DistanceMeasurement
    let elevation: ElevationProfile
    let savedRoutesModel: SavedRoutesModel?
    var isHorizontal = false
    var onRouteSaved: () -> Void = {}
    @State private var isNamingRoute = false

    var body: some View {
        let layout = isHorizontal
            ? AnyLayout(HStackLayout(alignment: .top, spacing: ButtonStyleModifier.stackSpacing))
            : AnyLayout(VStackLayout(spacing: ButtonStyleModifier.stackSpacing))

        layout {
            Button {
                measurement.isMeasuring.toggle()
            } label: {
                Image(systemName: "ruler")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolVariant(measurement.isMeasuring ? .fill : .none)
                    .foregroundStyle(measurement.isMeasuring ? Color.orange : Color.primary)
                    .buttonStyle()
            }

            if measurement.isMeasuring {
                Button {
                    measurement.undoLastStroke()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .buttonStyle(MapControlLabel.undo)
                }
                .disabled(!measurement.canUndo)

                Button {
                    measurement.clear()
                } label: {
                    Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .buttonStyle(MapControlLabel.clear)
                }
                .disabled(measurement.isEmpty)

                if let savedRoutesModel {
                    Button {
                        isNamingRoute = true
                    } label: {
                        Image(systemName: "bookmark")
                            .font(.system(size: 15, weight: .semibold))
                            .buttonStyle(MapControlLabel.save)
                    }
                    .disabled(measurement.isEmpty)
                    .sheet(isPresented: $isNamingRoute) {
                        RouteNameSheet(title: "Name route",
                                       initialName: savedRoutesModel.nextDefaultName()) { name in
                            let saved = measurement.snapshot(elevation: elevation).renamed(to: name)
                            savedRoutesModel.save(saved)
                            measurement.markSaved(as: saved.displayName)
                            onRouteSaved()
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: measurement.isMeasuring)
        .environment(\.mapControlsAreHorizontal, isHorizontal)
    }
}

struct MeasureReadoutView: View {
    let measurement: DistanceMeasurement
    let elevation: ElevationProfile
    var onOpenElevation: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        let hasRoute = !measurement.isEmpty

        if measurement.isMeasuring || hasRoute {
            HStack(spacing: 8) {
                VStack(spacing: 2) {
                    if let name = measurement.loadedRouteName, hasRoute {
                        Text(verbatim: name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(measurement.formattedDistance)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if measurement.isEmpty {
                        Text("Drag to trace a route")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if elevation.hasData {
                        HStack(spacing: 8) {
                            Label(elevation.formattedAscent, systemImage: "arrow.up")
                            Label(elevation.formattedDescent, systemImage: "arrow.down")
                            if elevation.isPartial {
                                // The route left the tiles, so the totals shown are
                                // a floor rather than the real climb.
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard elevation.hasData else { return }
                    onOpenElevation()
                }

                if hasRoute {
                    Divider().frame(height: 24)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 260)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 12)
            .padding(.trailing, hasRoute ? 4 : 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .animation(.easeInOut(duration: 0.2), value: elevation.hasData)
            .animation(.easeInOut(duration: 0.2), value: hasRoute)
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
