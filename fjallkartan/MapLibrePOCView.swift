import SwiftUI
import MapLibre

// Throwaway POC to compare browsing feel against the MapKit-based MapView.
// Lantmäteriet + Kartverket raster tiles, stacked like the production
// MapView (Lantmäteriet first as the opaque base, Kartverket second on top
// for the border) — but with no no-data-to-transparent pixel rewrite, so
// Kartverket's opaque cream fill (from ~z15) will cover Lantmäteriet there
// instead of showing through. No offline store, no measurement/elevation.
// Delete once the comparison is done.
struct MapLibrePOCView: View {
    @State private var trackingMode: MLNUserTrackingMode = .none

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MapLibreRasterMap(trackingMode: $trackingMode)
                .ignoresSafeArea()
            userLocationButton
                .padding()
        }
    }

    private var userLocationButton: some View {
        Button {
            trackingMode = nextTrackingMode(after: trackingMode)
        } label: {
            Image(systemName: trackingButtonSymbol(for: trackingMode))
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
        }
    }

    // .none -> .follow -> .followWithHeading -> .none.
    private func nextTrackingMode(after mode: MLNUserTrackingMode) -> MLNUserTrackingMode {
        switch mode {
        case .none: return .follow
        case .follow: return .followWithHeading
        default: return .none
        }
    }

    private func trackingButtonSymbol(for mode: MLNUserTrackingMode) -> String {
        switch mode {
        case .none: return "location"
        case .followWithHeading: return "location.north.line.fill"
        default: return "location.fill"
        }
    }
}

private struct MapLibreRasterMap: UIViewRepresentable {
    private static let lantmaterietTileURL = "https://tiles.wallman.dev/v1/{z}/{y}/{x}.png"
    private static let kartverketTileURL =
        "https://cache.kartverket.no/v1/wmts/1.0.0/topo/default/webmercator/{z}/{y}/{x}.png"
    // Empty style so we don't depend on (or pay for) any vector basemap;
    // only our raster layers get drawn.
    private static let blankStyleJSON = #"{"version":8,"sources":{},"layers":[]}"#

    @Binding var trackingMode: MLNUserTrackingMode

    func makeCoordinator() -> Coordinator { Coordinator(trackingMode: $trackingMode) }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero)
        // Set the delegate *before* triggering the style load — the
        // `styleJSON:` initializer loads synchronously inside init, before a
        // delegate could ever be assigned, so `didFinishLoading` would never
        // fire. Setting the `styleJSON` property afterward loads asynchronously.
        mapView.delegate = context.coordinator
        mapView.styleJSON = Self.blankStyleJSON
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.showsUserLocation = true
        mapView.setCenter(
            CLLocationCoordinate2D(latitude: 62.0, longitude: 15.0),
            zoomLevel: 5,
            animated: false
        )
        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        // Only push down when the button (not the map itself, e.g. via a
        // user pan) caused the change, to avoid fighting MapLibre's own
        // reset-to-.none-on-pan behaviour.
        if uiView.userTrackingMode != trackingMode {
            uiView.setUserTrackingMode(trackingMode, animated: true, completionHandler: nil)
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        @Binding var trackingMode: MLNUserTrackingMode

        init(trackingMode: Binding<MLNUserTrackingMode>) {
            _trackingMode = trackingMode
        }

        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            // Keeps the button in sync when MapLibre resets tracking to
            // .none on its own, e.g. the user panning the map away.
            trackingMode = mode
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            let lantmaterietSource = MLNRasterTileSource(
                identifier: "lantmateriet",
                tileURLTemplates: [MapLibreRasterMap.lantmaterietTileURL],
                options: [
                    .tileSize: 128,
                    .minimumZoomLevel: 0,
                    .maximumZoomLevel: 18,
                ]
            )
            style.addSource(lantmaterietSource)
            style.addLayer(MLNRasterStyleLayer(identifier: "lantmateriet-layer", source: lantmaterietSource))

            let kartverketSource = MLNRasterTileSource(
                identifier: "kartverket",
                tileURLTemplates: [MapLibreRasterMap.kartverketTileURL],
                options: [
                    .tileSize: 128,
                    .minimumZoomLevel: 0,
                    .maximumZoomLevel: 18,
                ]
            )
            style.addSource(kartverketSource)
            // Added after Lantmäteriet so it composites on top, same as the
            // production MapView's overlay order.
            style.addLayer(MLNRasterStyleLayer(identifier: "kartverket-layer", source: kartverketSource))
        }
    }
}

#Preview {
    MapLibrePOCView()
}
