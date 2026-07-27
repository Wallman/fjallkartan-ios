import CoreLocation
import MapKit
import SwiftUI

struct MapView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

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

        context.coordinator.locationManager.requestWhenInUseAuthorization()

        map.subviews
            .filter { String(describing: type(of: $0)).contains("Attribution") }
            .forEach { $0.isHidden = true }

        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {}

    final class Coordinator: NSObject, MKMapViewDelegate {
        let locationManager = CLLocationManager()

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tile = overlay as? MKTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            return MKTileOverlayRenderer(tileOverlay: tile)
        }
    }
}
