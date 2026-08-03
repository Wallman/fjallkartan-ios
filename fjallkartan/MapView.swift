import CoreLocation
import MapKit
import SwiftUI

final class RouteCasingPolyline: MKPolyline {}
final class RouteLinePolyline: MKPolyline {}

final class MeasurementEndpoint: NSObject, MKAnnotation {
    enum Kind { case start, end }

    let coordinate: CLLocationCoordinate2D
    let kind: Kind

    init(coordinate: CLLocationCoordinate2D, kind: Kind) {
        self.coordinate = coordinate
        self.kind = kind
    }
}

final class MeasurementEndpointView: MKAnnotationView {
    static let reuseIdentifier = "MeasurementEndpoint"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let diameter = MeasurementStyle.endpointRadius * 2
        frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        isUserInteractionEnabled = false
        displayPriority = .required
        layer.cornerRadius = MeasurementStyle.endpointRadius
        layer.borderWidth = 2.5
        applyKind()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var annotation: MKAnnotation? {
        didSet { applyKind() }
    }

    private func applyKind() {
        let isStart = (annotation as? MeasurementEndpoint)?.kind == .start
        backgroundColor = isStart ? MeasurementStyle.casingColor : MeasurementStyle.strokeColor
        layer.borderColor = (isStart ? MeasurementStyle.strokeColor : MeasurementStyle.casingColor).cgColor
    }
}

final class SearchResultAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let placeID: Int64

    init(result: PlaceResult) {
        coordinate = result.coordinate
        title = result.name
        subtitle = result.subtitle.isEmpty ? nil : result.subtitle
        placeID = result.id
    }
}

struct MapView: UIViewRepresentable {
    @Binding var zoomLevel: Double
    @Binding var metersPerPoint: Double

    let measurement: DistanceMeasurement
    /// Mirrors of `measurement` state. Reading these in `ContentView.body` is what
    /// makes Observation schedule an `updateUIView` when the measurement changes.
    let isMeasuring: Bool
    let routeVersion: Int
    /// Most recent search result the user tapped, or nil.
    let selectedPlace: PlaceResult?

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomLevel: $zoomLevel, metersPerPoint: $metersPerPoint)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false

        let center = CLLocationCoordinate2D(latitude: 64.0, longitude: 12.5)
        map.setRegion(
            MKCoordinateRegion(center: center,
                               latitudinalMeters: 800_000,
                               longitudinalMeters: 800_000),
            animated: false
        )

        map.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: 800,
            maxCenterCoordinateDistance: 10_000_000
        )
        
        let mapBounds = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 67.5, longitude: 18.0),
            span: MKCoordinateSpan(latitudeDelta: 27.0, longitudeDelta: 28.0)
        )
        map.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: mapBounds)

        map.addOverlay(CustomTileOverlay(server: .lantmateriet), level: .aboveLabels)
        map.addOverlay(CustomTileOverlay(server: .kartverket), level: .aboveLabels)

        map.register(MeasurementEndpointView.self,
                     forAnnotationViewWithReuseIdentifier: MeasurementEndpointView.reuseIdentifier)
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: Coordinator.searchMarkerIdentifier)

        context.coordinator.start(with: map)
        context.coordinator.installCaptureView(on: map, measurement: measurement)

        map.subviews
            .filter { String(describing: type(of: $0)).contains("Attribution") }
            .forEach { $0.isHidden = true }

        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.setMeasuring(isMeasuring, on: uiView)
        context.coordinator.syncRoute(on: uiView, measurement: measurement, version: routeVersion)
        context.coordinator.syncSelection(selectedPlace, on: uiView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
        let locationManager = CLLocationManager()
        private weak var mapView: MKMapView?
        private var captureView: MeasureCaptureView?
        private var routeOverlays: [MKOverlay] = []
        private var renderedVersion = -1
        private var shownPlaceID: Int64?
        static let searchMarkerIdentifier = "SearchResultMarker"
        @Binding var zoomLevel: Double
        @Binding var metersPerPoint: Double

        init(zoomLevel: Binding<Double>,
             metersPerPoint: Binding<Double>) {
            _zoomLevel = zoomLevel
            _metersPerPoint = metersPerPoint
        }

        func start(with mapView: MKMapView) {
            self.mapView = mapView
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
        }

        // MARK: - Measuring

        func installCaptureView(on map: MKMapView, measurement: DistanceMeasurement) {
            let capture = MeasureCaptureView(mapView: map)
            capture.translatesAutoresizingMaskIntoConstraints = false
            capture.anchorProvider = { [weak measurement] in measurement?.anchor }
            capture.onStrokeProgress = { [weak measurement] meters in
                measurement?.previewMeters = meters
            }
            capture.onStrokeFinished = { [weak measurement] coordinates in
                measurement?.appendStroke(coordinates)
            }

            map.addSubview(capture)
            NSLayoutConstraint.activate([
                capture.topAnchor.constraint(equalTo: map.topAnchor),
                capture.bottomAnchor.constraint(equalTo: map.bottomAnchor),
                capture.leadingAnchor.constraint(equalTo: map.leadingAnchor),
                capture.trailingAnchor.constraint(equalTo: map.trailingAnchor),
            ])
            captureView = capture
        }

        func setMeasuring(_ isMeasuring: Bool, on map: MKMapView) {
            guard let captureView, captureView.isUserInteractionEnabled != isMeasuring else { return }
            captureView.isUserInteractionEnabled = isMeasuring
            if isMeasuring {
                // MapKit inserts its own subviews over time; stay above them.
                map.bringSubviewToFront(captureView)
            }
        }

        func syncRoute(on map: MKMapView, measurement: DistanceMeasurement, version: Int) {
            guard version != renderedVersion else { return }
            renderedVersion = version

            map.removeOverlays(routeOverlays)
            routeOverlays.removeAll()
            map.removeAnnotations(map.annotations.filter { $0 is MeasurementEndpoint })

            let coordinates = measurement.coordinates
            guard coordinates.count >= 2 else { return }

            routeOverlays = [
                RouteCasingPolyline(coordinates: coordinates, count: coordinates.count),
                RouteLinePolyline(coordinates: coordinates, count: coordinates.count),
            ]
            map.addOverlays(routeOverlays, level: .aboveLabels)

            map.addAnnotations([
                MeasurementEndpoint(coordinate: coordinates[0], kind: .start),
                MeasurementEndpoint(coordinate: coordinates[coordinates.count - 1], kind: .end),
            ])
        }

        // MARK: - Search selection

        func syncSelection(_ place: PlaceResult?, on map: MKMapView) {
            guard shownPlaceID != place?.id else { return }
            shownPlaceID = place?.id

            map.removeAnnotations(map.annotations.compactMap { $0 as? SearchResultAnnotation })
            guard let place else { return }

            let annotation = SearchResultAnnotation(result: place)
            map.addAnnotation(annotation)

            // Zoom in only when the map is currently wider than this; staying
            // put avoids yanking the user out of a close-up they chose.
            let span = min(map.region.span.latitudeDelta, 0.12)
            map.setRegion(MKCoordinateRegion(center: place.coordinate,
                                             span: MKCoordinateSpan(latitudeDelta: span,
                                                                    longitudeDelta: span)),
                          animated: true)
            map.selectAnnotation(annotation, animated: true)
        }

        // MARK: - MKMapViewDelegate

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let authorized = manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways
            mapView?.showsUserLocation = authorized
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            updateRegion(for: mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            updateRegion(for: mapView)
        }

        private func updateRegion(for mapView: MKMapView) {
            let region = mapView.region
            let updatedZoomLevel = log2(360.0 / region.span.longitudeDelta)
            let metersPerDegree = cos(region.center.latitude * .pi / 180) * 111_319.5
            let updatedMetersPerPoint = region.span.longitudeDelta * metersPerDegree / mapView.bounds.width

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                if zoomLevel != updatedZoomLevel {
                    zoomLevel = updatedZoomLevel
                }

                if metersPerPoint != updatedMetersPerPoint {
                    metersPerPoint = updatedMetersPerPoint
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is SearchResultAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: Coordinator.searchMarkerIdentifier,
                    for: annotation) as? MKMarkerAnnotationView
                view?.markerTintColor = .systemOrange
                view?.glyphImage = UIImage(systemName: "mappin")
                view?.displayPriority = .required
                view?.canShowCallout = true
                return view
            }
            guard annotation is MeasurementEndpoint else { return nil }
            return mapView.dequeueReusableAnnotationView(
                withIdentifier: MeasurementEndpointView.reuseIdentifier,
                for: annotation
            )
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                let isCasing = overlay is RouteCasingPolyline
                renderer.strokeColor = isCasing ? MeasurementStyle.casingColor : MeasurementStyle.strokeColor
                renderer.lineWidth = isCasing ? MeasurementStyle.casingWidth : MeasurementStyle.lineWidth
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
