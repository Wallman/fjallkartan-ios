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
    let result: PlaceResult

    var coordinate: CLLocationCoordinate2D { result.coordinate }
    var title: String? { result.name }
    var subtitle: String? {
        let subtitle = result.subtitle
        return subtitle.isEmpty ? nil : subtitle
    }
    var placeID: Int64 { result.id }

    init(result: PlaceResult) {
        self.result = result
    }
}

final class SavedPinAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let pin: SavedPin

    init(pin: SavedPin) {
        coordinate = pin.coordinate.coordinate
        title = pin.displayName
        self.pin = pin
    }
}

final class DistanceMarkerAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let meters: Double

    var label: String { DistanceMeasurement.markerLabel(meters: meters) }

    init(coordinate: CLLocationCoordinate2D, meters: Double) {
        self.coordinate = coordinate
        self.meters = meters
    }

    /// Round distances survive decluttering first, so zooming out thins the
    /// markers down to 10 km, then 50 km, rather than dropping a random subset.
    var displayPriority: MKFeatureDisplayPriority {
        let kilometers = Int((meters / 1000).rounded())
        if kilometers % 50 == 0 { return MKFeatureDisplayPriority(rawValue: 720) }
        if kilometers % 10 == 0 { return MKFeatureDisplayPriority(rawValue: 620) }
        if kilometers % 5 == 0 { return MKFeatureDisplayPriority(rawValue: 520) }
        return MKFeatureDisplayPriority(rawValue: 420)
    }
}

final class DistanceMarkerView: MKAnnotationView {
    static let reuseIdentifier = "DistanceMarker"

    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        isUserInteractionEnabled = false
        collisionMode = .rectangle
        backgroundColor = MeasurementStyle.casingColor
        layer.borderWidth = 2
        layer.borderColor = MeasurementStyle.strokeColor.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)

        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .label
        label.textAlignment = .center
        addSubview(label)

        applyAnnotation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var annotation: MKAnnotation? {
        didSet { applyAnnotation() }
    }

    /// A pill sized to its text keeps the unit on the same line as the number
    /// while staying short enough not to cover much of the route.
    private func applyAnnotation() {
        guard let marker = annotation as? DistanceMarkerAnnotation else { return }
        label.text = marker.label
        displayPriority = marker.displayPriority
        accessibilityLabel = marker.label

        let height: CGFloat = 20
        let width = max(height, (label.intrinsicContentSize.width + 14).rounded())
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        label.frame = bounds
        layer.cornerRadius = height / 2
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
    var routeFitToken: Int = 0 // Needed to re-center when loading a route already shown
    /// Most recent search result the user tapped, or nil.
    let selectedPlace: PlaceResult?

    let isRegionPreviewVisible: Bool

    var isSlopeLayerVisible: Bool = false

    let pins: [SavedPin]
    var onDropPin: ((CLLocationCoordinate2D) -> Void)?
    var onSavePlace: ((PlaceResult) -> Void)?
    var onDismissPlace: (() -> Void)?
    var onOpenPinDetail: ((SavedPin) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(metersPerPoint: $metersPerPoint, visibleMapRect: $visibleMapRect)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.showsUserTrackingButton = true
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
        map.register(DistanceMarkerView.self,
                     forAnnotationViewWithReuseIdentifier: DistanceMarkerView.reuseIdentifier)
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: Coordinator.searchMarkerIdentifier)
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: Coordinator.savedPinIdentifier)

        context.coordinator.start(with: map)
        context.coordinator.installCaptureView(on: map, measurement: measurement)
        context.coordinator.installRegionPreviewBorder(on: map)
        context.coordinator.installLongPressRecognizer(on: map)

        map.subviews
            .filter { String(describing: type(of: $0)).contains("Attribution") }
            .forEach { $0.isHidden = true }

        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.onDropPin = onDropPin
        context.coordinator.onSavePlace = onSavePlace
        context.coordinator.onDismissPlace = onDismissPlace
        context.coordinator.onOpenPinDetail = onOpenPinDetail
        context.coordinator.setMeasuring(isMeasuring, on: uiView)
        context.coordinator.syncRoute(on: uiView, measurement: measurement, version: routeVersion)
        context.coordinator.fitRouteIfNeeded(on: uiView, measurement: measurement, fitToken: routeFitToken)
        context.coordinator.syncSelection(selectedPlace, on: uiView)
        context.coordinator.syncRegionPreview(isVisible: isRegionPreviewVisible)
        context.coordinator.syncSlopeLayer(isVisible: isSlopeLayerVisible, on: uiView)
        context.coordinator.syncPins(on: uiView, pins: pins)
        context.coordinator.setLongPressEnabled(!isMeasuring && !isRegionPreviewVisible)
    }


    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
        let locationManager = CLLocationManager()
        private weak var mapView: MKMapView?
        private var captureView: MeasureCaptureView?
        private var routeOverlays: [MKOverlay] = []
        private var renderedVersion = -1
        private var routeCoordinates: [CLLocationCoordinate2D] = []
        private var renderedMarkerSpacing: Double = 0
        private var renderedFitToken = 0
        private var shownPlaceID: Int64?
        private var wantsTrackingOnceAuthorized = false
        private weak var regionPreviewBorder: RegionPreviewBorderView?
        private var slopeOverlays: [SlopeTileOverlay] = []
        static let searchMarkerIdentifier = "SearchResultMarker"
        static let savedPinIdentifier = "SavedPinMarker"
        @Binding var metersPerPoint: Double
        @Binding var visibleMapRect: MKMapRect

        private var renderedPins: [SavedPin] = []
        private weak var longPressRecognizer: UILongPressGestureRecognizer?
        var onDropPin: ((CLLocationCoordinate2D) -> Void)?
        var onSavePlace: ((PlaceResult) -> Void)?
        var onDismissPlace: (() -> Void)?
        var onOpenPinDetail: ((SavedPin) -> Void)?

        init(metersPerPoint: Binding<Double>,
             visibleMapRect: Binding<MKMapRect>) {
            _metersPerPoint = metersPerPoint
            _visibleMapRect = visibleMapRect
        }

        func start(with mapView: MKMapView) {
            self.mapView = mapView
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            mapView.showsUserLocation = isAuthorized
        }

        private var isAuthorized: Bool {
            let status = locationManager.authorizationStatus
            return status == .authorizedWhenInUse || status == .authorizedAlways
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
            map.removeAnnotations(map.annotations.filter { $0 is MeasurementEndpoint || $0 is DistanceMarkerAnnotation })

            let coordinates = measurement.coordinates
            guard coordinates.count >= 2 else {
                routeCoordinates = []
                renderedMarkerSpacing = 0
                return
            }

            routeOverlays = [
                RouteCasingPolyline(coordinates: coordinates, count: coordinates.count),
                RouteLinePolyline(coordinates: coordinates, count: coordinates.count),
            ]
            map.addOverlays(routeOverlays, level: .aboveLabels)

            map.addAnnotations([
                MeasurementEndpoint(coordinate: coordinates[0], kind: .start),
                MeasurementEndpoint(coordinate: coordinates[coordinates.count - 1], kind: .end),
            ])

            routeCoordinates = coordinates
            syncDistanceMarkers(on: map, force: true)
        }

        func syncDistanceMarkers(on map: MKMapView, force: Bool = false) {
            let spacing = routeCoordinates.count >= 2
                ? DistanceMeasurement.markerSpacing(forZoomLevel: Self.zoomLevel(of: map),
                                                    routeLength: DistanceMeasurement.length(of: routeCoordinates))
                : 0
            guard force || spacing != renderedMarkerSpacing else { return }
            renderedMarkerSpacing = spacing

            map.removeAnnotations(map.annotations.filter { $0 is DistanceMarkerAnnotation })
            guard spacing > 0 else { return }

            map.addAnnotations(
                DistanceMeasurement.distanceMarkers(along: routeCoordinates, spacing: spacing).map {
                    DistanceMarkerAnnotation(coordinate: $0.coordinate, meters: $0.meters)
                }
            )
        }

        private static func zoomLevel(of map: MKMapView) -> Double {
            let longitudeDelta = map.region.span.longitudeDelta
            guard longitudeDelta > 0, map.bounds.width > 0 else { return 0 }
            return log2(360 * (map.bounds.width / 256) / longitudeDelta)
        }

        func fitRouteIfNeeded(on map: MKMapView, measurement: DistanceMeasurement, fitToken: Int) {
            guard fitToken != renderedFitToken else { return }
            renderedFitToken = fitToken

            let coordinates = measurement.coordinates
            guard !coordinates.isEmpty else { return }

            var rect = MKMapRect.null
            for coordinate in coordinates {
                rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
            }
            // setVisibleMapRect already respects cameraBoundary/cameraZoomRange,
            // clamping a single-point or oversized route rather than fighting them.
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40),
                                  animated: true)
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

        // MARK: - Slope layer

        func syncSlopeLayer(isVisible: Bool, on map: MKMapView) {
            guard isVisible != !slopeOverlays.isEmpty else { return }
            if isVisible {
                let overlays = [SlopeTileOverlay.norway(), SlopeTileOverlay.sweden()]
                for overlay in overlays {
                    map.addOverlay(overlay, level: .aboveLabels)
                }
                slopeOverlays = overlays
            } else {
                map.removeOverlays(slopeOverlays)
                slopeOverlays = []
            }
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

        // MARK: - Saved pins

        @MainActor
        func syncPins(on map: MKMapView, pins: [SavedPin]) {
            guard pins != renderedPins else { return }
            renderedPins = pins

            let existing = map.annotations.compactMap { $0 as? SavedPinAnnotation }
            map.removeAnnotations(existing)
            map.addAnnotations(pins.map(SavedPinAnnotation.init))
        }

        func installLongPressRecognizer(on map: MKMapView) {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            recognizer.minimumPressDuration = 0.5
            map.addGestureRecognizer(recognizer)
            longPressRecognizer = recognizer
        }

        func setLongPressEnabled(_ isEnabled: Bool) {
            longPressRecognizer?.isEnabled = isEnabled
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let mapView else { return }
            let point = recognizer.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onDropPin?(coordinate)
        }

        // MARK: - CLLocationManagerDelegate

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            guard let mapView else { return }
            mapView.showsUserLocation = isAuthorized

            guard wantsTrackingOnceAuthorized else { return }
            wantsTrackingOnceAuthorized = false
            if isAuthorized {
                mapView.setUserTrackingMode(.follow, animated: true)
            }
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            guard mode != .none, locationManager.authorizationStatus == .notDetermined else { return }
            wantsTrackingOnceAuthorized = true
            locationManager.requestWhenInUseAuthorization()
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            updateRegion(for: mapView)
            syncDistanceMarkers(on: mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            updateRegion(for: mapView)
            syncDistanceMarkers(on: mapView)
        }

        private func updateRegion(for mapView: MKMapView) {
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
            if annotation is SearchResultAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: Coordinator.searchMarkerIdentifier,
                    for: annotation) as? MKMarkerAnnotationView
                view?.markerTintColor = .systemOrange
                view?.glyphImage = UIImage(systemName: "mappin")
                view?.displayPriority = .required
                view?.canShowCallout = true
                view?.leftCalloutAccessoryView = calloutButton(systemName: "bookmark", tint: .systemOrange)
                view?.rightCalloutAccessoryView = calloutButton(systemName: "xmark", tint: .secondaryLabel)
                return view
            }
            if annotation is SavedPinAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: Coordinator.savedPinIdentifier,
                    for: annotation) as? MKMarkerAnnotationView
                view?.markerTintColor = .systemIndigo
                view?.glyphImage = UIImage(systemName: "bookmark.fill")
                return view
            }
            if annotation is DistanceMarkerAnnotation {
                return mapView.dequeueReusableAnnotationView(
                    withIdentifier: DistanceMarkerView.reuseIdentifier,
                    for: annotation
                )
            }
            guard annotation is MeasurementEndpoint else { return nil }
            return mapView.dequeueReusableAnnotationView(
                withIdentifier: MeasurementEndpointView.reuseIdentifier,
                for: annotation
            )
        }

        private func calloutButton(systemName: String, tint: UIColor) -> UIButton {
            let button = UIButton(type: .system)
            let symbol = UIImage(systemName: systemName,
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
            button.setImage(symbol, for: .normal)
            button.tintColor = tint
            button.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            return button
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     calloutAccessoryControlTapped control: UIControl) {
            guard let searchAnnotation = view.annotation as? SearchResultAnnotation else { return }
            if control === view.leftCalloutAccessoryView {
                onSavePlace?(searchAnnotation.result)
                mapView.removeAnnotation(searchAnnotation)
                onDismissPlace?()
            } else {
                mapView.removeAnnotation(searchAnnotation)
                onDismissPlace?()
            }
        }

        func mapView(_ mapView: MKMapView, didSelect annotationView: MKAnnotationView) {
            guard let pinAnnotation = annotationView.annotation as? SavedPinAnnotation else { return }
            onOpenPinDetail?(pinAnnotation.pin)
            mapView.deselectAnnotation(pinAnnotation, animated: false)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let slope = overlay as? SlopeTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: slope)
                renderer.alpha = 0.6
                return renderer
            }
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
