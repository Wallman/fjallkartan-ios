import CoreLocation
import MapKit
import SwiftUI

struct TileInfo {
    let coordinate: CLLocationCoordinate2D
    let x: Int
    let y: Int
    let z: Int
}

struct MapView: UIViewRepresentable {
    @Binding var tappedTile: TileInfo?

    func makeCoordinator() -> Coordinator { Coordinator(tappedTile: $tappedTile) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true

        let center = CLLocationCoordinate2D(latitude: 64.0, longitude: 12.5)
        map.setRegion(
            MKCoordinateRegion(center: center,
                               latitudinalMeters: 800_000,
                               longitudinalMeters: 800_000),
            animated: false
        )

        map.cameraZoomRange = MKMapView.CameraZoomRange(maxCenterCoordinateDistance: 10_000_000)
        
        let europeBounds = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 64.0, longitude: 12.5),
            span: MKCoordinateSpan(latitudeDelta: 10.0, longitudeDelta: 20.0)
        )
        map.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: europeBounds)

        map.addOverlay(CustomTileOverlay(server: .lantmateriet), level: .aboveLabels)
        map.addOverlay(CustomTileOverlay(server: .kartverket), level: .aboveLabels)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        map.addGestureRecognizer(tap)

        context.coordinator.locationManager.requestWhenInUseAuthorization()

        map.subviews
            .filter { String(describing: type(of: $0)).contains("Attribution") }
            .forEach { $0.isHidden = true }

        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {}

    final class Coordinator: NSObject, MKMapViewDelegate {
        let locationManager = CLLocationManager()
        @Binding var tappedTile: TileInfo?

        init(tappedTile: Binding<TileInfo?>) {
            _tappedTile = tappedTile
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let mapView = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            let z = zoomLevel(for: mapView)
            let (x, y) = tileXY(for: coordinate, zoom: z)
            tappedTile = TileInfo(coordinate: coordinate, x: x, y: y, z: z)
        }

        private func zoomLevel(for mapView: MKMapView) -> Int {
            let width = Double(mapView.frame.width)
            guard width > 0 else { return 0 }
            let zoom = log2(360 * width / 256.0 / mapView.region.span.longitudeDelta)
            return max(0, min(22, Int(zoom)))
        }

        private func tileXY(for coordinate: CLLocationCoordinate2D, zoom: Int) -> (Int, Int) {
            let n = pow(2.0, Double(zoom))
            let x = Int(floor((coordinate.longitude + 180.0) / 360.0 * n))
            let latRad = coordinate.latitude * .pi / 180.0
            let y = Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n))
            return (x, y)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tile = overlay as? MKTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            return MKTileOverlayRenderer(tileOverlay: tile)
        }
    }
}
