import CoreLocation
import MapKit
import SwiftUI

final class RouteCasingPolyline: MKPolyline {}
final class RouteLinePolyline: MKPolyline {}

/// Dashed rectangle shown while the user is picking an offline region,
final class RegionPreviewBorderView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }
    private var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        shapeLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.1).cgColor
        shapeLayer.strokeColor = UIColor.systemBlue.cgColor
        shapeLayer.lineWidth = 2
        shapeLayer.lineDashPattern = [6, 4]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.path = UIBezierPath(rect: bounds).cgPath
    }
}

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
    @Binding var metersPerPoint: Double
    @Binding var visibleMapRect: MKMapRect

    let measurement: DistanceMeasurement
    /// Mirrors of `measurement` state. Reading these in `ContentView.body` is what
    /// makes Observation schedule an `updateUIView` when the measurement changes.
    let isMeasuring: Bool
    let routeVersion: Int
    /// Most recent search result the user tapped, or nil.
    let selectedPlace: PlaceResult?

    let isRegionPreviewVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(metersPerPoint: $metersPerPoint, visibleMapRect: $visibleMapRect)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.isPitchEnabled = false
        map.overrideUserInterfaceStyle = .light

        let center = CLLocationCoordinate2D(latitude: 64.0, longitude: 12.5)
        map.setRegion(
            MKCoordinateRegion(center: center,
                               latitudinalMeters: 800_000,
                               longitudinalMeters: 800_000),
            animated: false
        )
        map.showsCompass = true

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
        map.register(UserLocationAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: UserLocationAnnotationView.reuseIdentifier)
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: Coordinator.searchMarkerIdentifier)

        context.coordinator.start(with: map)
        context.coordinator.installCaptureView(on: map, measurement: measurement)
        context.coordinator.installRegionPreviewBorder(on: map)

        map.subviews
            .filter { String(describing: type(of: $0)).contains("Attribution") }
            .forEach { $0.isHidden = true }

        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.setMeasuring(isMeasuring, on: uiView)
        context.coordinator.syncRoute(on: uiView, measurement: measurement, version: routeVersion)
        context.coordinator.syncSelection(selectedPlace, on: uiView)
        context.coordinator.syncRegionPreview(isVisible: isRegionPreviewVisible)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
        let locationManager = CLLocationManager()
        private weak var mapView: MKMapView?
        private var captureView: MeasureCaptureView?
        private var routeOverlays: [MKOverlay] = []
        private var renderedVersion = -1
        private var shownPlaceID: Int64?
        private weak var userLocationView: UserLocationAnnotationView?
        private var latestHeading: CLLocationDirection?
        private weak var regionPreviewBorder: RegionPreviewBorderView?
        static let searchMarkerIdentifier = "SearchResultMarker"
        @Binding var metersPerPoint: Double
        @Binding var visibleMapRect: MKMapRect

        init(metersPerPoint: Binding<Double>,
             visibleMapRect: Binding<MKMapRect>) {
            _metersPerPoint = metersPerPoint
            _visibleMapRect = visibleMapRect
        }

        func start(with mapView: MKMapView) {
            self.mapView = mapView
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.headingFilter = 2
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }

            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(syncHeadingOrientation),
                name: UIDevice.orientationDidChangeNotification,
                object: nil
            )
            syncHeadingOrientation()
        }

        @objc private func syncHeadingOrientation() {
            guard let orientation = CLDeviceOrientation(rawValue: Int32(UIDevice.current.orientation.rawValue)),
                  (1...4).contains(orientation.rawValue) else { return }
            locationManager.headingOrientation = orientation
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

        // MARK: - Offline region preview

        func installRegionPreviewBorder(on map: MKMapView) {
            let border = RegionPreviewBorderView()
            border.translatesAutoresizingMaskIntoConstraints = false
            map.addSubview(border)
            NSLayoutConstraint.activate([
                border.centerXAnchor.constraint(equalTo: map.centerXAnchor),
                border.centerYAnchor.constraint(equalTo: map.centerYAnchor),
                border.widthAnchor.constraint(equalTo: map.widthAnchor, multiplier: 0.8),
                border.heightAnchor.constraint(equalTo: map.heightAnchor, multiplier: 0.8),
            ])
            regionPreviewBorder = border
        }

        func syncRegionPreview(isVisible: Bool) {
            regionPreviewBorder?.isHidden = !isVisible
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

        // MARK: - CLLocationManagerDelegate

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let authorized = manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways
            mapView?.showsUserLocation = authorized
            if authorized {
                manager.startUpdatingHeading()
            } else {
                manager.stopUpdatingHeading()
                latestHeading = nil
                userLocationView?.heading = nil
            }
        }

        func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
            guard newHeading.headingAccuracy >= 0 else { return }
            // trueHeading is -1 until a location fix lets Core Location correct for declination.
            let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
            latestHeading = heading
            userLocationView?.heading = heading
        }

        // MARK: - MKMapViewDelegate

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            updateRegion(for: mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            updateRegion(for: mapView)
        }

        private func updateRegion(for mapView: MKMapView) {
            userLocationView?.mapHeading = mapView.camera.heading

            let region = mapView.region
            let metersPerDegree = cos(region.center.latitude * .pi / 180) * 111_319.5
            let updatedMetersPerPoint = region.span.longitudeDelta * metersPerDegree / mapView.bounds.width
            let updatedMapRect = mapView.visibleMapRect

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                if metersPerPoint != updatedMetersPerPoint {
                    metersPerPoint = updatedMetersPerPoint
                }

                if !MKMapRectEqualToRect(visibleMapRect, updatedMapRect) {
                    visibleMapRect = updatedMapRect
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: UserLocationAnnotationView.reuseIdentifier,
                    for: annotation) as? UserLocationAnnotationView
                view?.mapHeading = mapView.camera.heading
                view?.heading = latestHeading
                userLocationView = view
                return view
            }
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
