import CoreLocation
import MapKit
import SwiftUI

struct MapView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true

        let center = CLLocationCoordinate2D(latitude: 63.0, longitude: 14.0)
        map.setRegion(
            MKCoordinateRegion(center: center,
                               latitudinalMeters: 2_000_000,
                               longitudinalMeters: 2_000_000),
            animated: false
        )

        map.addOverlay(CustomTileOverlay(), level: .aboveLabels)

        context.coordinator.locationManager.requestWhenInUseAuthorization()
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
