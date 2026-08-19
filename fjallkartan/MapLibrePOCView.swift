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
    var body: some View {
        MapLibreRasterMap()
            .ignoresSafeArea()
    }
}

private struct MapLibreRasterMap: UIViewRepresentable {
    private static let lantmaterietTileURL = "https://tiles.wallman.dev/v1/{z}/{y}/{x}.png"
    private static let kartverketTileURL =
        "https://cache.kartverket.no/v1/wmts/1.0.0/topo/default/webmercator/{z}/{y}/{x}.png"
    // Empty style so we don't depend on (or pay for) any vector basemap;
    // only our raster layers get drawn.
    private static let blankStyleJSON = #"{"version":8,"sources":{},"layers":[]}"#

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        mapView.setCenter(
            CLLocationCoordinate2D(latitude: 62.0, longitude: 15.0),
            zoomLevel: 5,
            animated: false
        )
        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {}

    final class Coordinator: NSObject, MLNMapViewDelegate {
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            let lantmaterietSource = MLNRasterTileSource(
                identifier: "lantmateriet",
                tileURLTemplates: [MapLibreRasterMap.lantmaterietTileURL],
                options: [
                    .tileSize: 256,
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
                    .tileSize: 256,
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
