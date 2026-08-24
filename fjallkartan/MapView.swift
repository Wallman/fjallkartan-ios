import CoreLocation
import MapKit
import MapLibre
import SwiftUI
import UIKit

enum MeasurementStyle {
    static let lineWidth: CGFloat = 4
    static let strokeColor = UIColor.systemOrange
    static let casingColor = UIColor.white
    static let casingWidth: CGFloat = 7
    static let endpointRadius: CGFloat = 6
}

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

private final class RouteDistanceMarker: NSObject, MLNAnnotation {
    let coordinate: CLLocationCoordinate2D
    let meters: Double
    var title: String? { nil }
    var subtitle: String? { nil }

    var label: String { DistanceMeasurement.markerLabel(meters: meters) }

    init(coordinate: CLLocationCoordinate2D, meters: Double) {
        self.coordinate = coordinate
        self.meters = meters
    }
}

private final class RouteDistanceMarkerView: MLNAnnotationView {
    static let reuseIdentifier = "RouteDistanceMarker"

    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        isUserInteractionEnabled = false
        scalesWithViewingDistance = false
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var annotation: MLNAnnotation? {
        didSet { applyAnnotation() }
    }

    private func applyAnnotation() {
        guard let marker = annotation as? RouteDistanceMarker else { return }
        label.text = marker.label
        accessibilityLabel = marker.label

        let height: CGFloat = 20
        let width = max(height, (label.intrinsicContentSize.width + 14).rounded())
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        label.frame = bounds
        layer.cornerRadius = height / 2
    }
}

private final class SavedPinMapAnnotation: NSObject, MLNAnnotation {
    let coordinate: CLLocationCoordinate2D
    let pin: SavedPin

    var title: String? { pin.displayName.isEmpty ? nil : pin.displayName }
    var subtitle: String? { nil }

    init(pin: SavedPin) {
        coordinate = pin.coordinate.coordinate
        self.pin = pin
    }
}

private final class SavedPinMarkerView: MLNAnnotationView {
    static let reuseIdentifier = "SavedPinMarker"

    private let iconView = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        scalesWithViewingDistance = false
        let diameter: CGFloat = 28
        bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        backgroundColor = .systemIndigo
        layer.cornerRadius = diameter / 2
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)

        iconView.image = UIImage(systemName: "bookmark.fill")
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.frame = bounds.insetBy(dx: 6, dy: 6)
        addSubview(iconView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class SearchResultAnnotation: NSObject, MLNAnnotation {
    let result: PlaceResult

    var coordinate: CLLocationCoordinate2D { result.coordinate }
    var title: String? { result.name }
    var subtitle: String? {
        let subtitle = result.subtitle
        return subtitle.isEmpty ? nil : subtitle
    }

    init(result: PlaceResult) {
        self.result = result
    }
}

private final class SearchResultMarkerView: MLNAnnotationView {
    static let reuseIdentifier = "SearchResultMarker"

    private let iconView = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        scalesWithViewingDistance = false
        let diameter: CGFloat = 28
        bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        backgroundColor = .systemOrange
        layer.cornerRadius = diameter / 2
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)

        iconView.image = UIImage(systemName: "mappin")
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.frame = bounds.insetBy(dx: 6, dy: 6)
        addSubview(iconView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class MapLibreMeasureCaptureView: UIView, UIGestureRecognizerDelegate {
    var anchorProvider: (() -> CLLocationCoordinate2D?)?
    var onStrokeProgress: ((Double) -> Void)?
    var onStrokeFinished: (([CLLocationCoordinate2D]) -> Void)?

    private weak var mapView: MLNMapView?

    private let casingLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()

    private var activeTouch: UITouch?
    private var screenPoints: [CGPoint] = []
    private var lastCoordinate: CLLocationCoordinate2D?
    private var runningMeters: Double = 0
    private var anchorScreenPoint: CGPoint?

    private let minSampleSpacing: CGFloat = 3
    private let simplifyTolerance: CGFloat = 2

    init(mapView: MLNMapView) {
        self.mapView = mapView
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isMultipleTouchEnabled = true

        for (layer, color, width) in [
            (casingLayer, MeasurementStyle.casingColor, MeasurementStyle.casingWidth),
            (strokeLayer, MeasurementStyle.strokeColor, MeasurementStyle.lineWidth),
        ] {
            layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            layer.lineCap = .round
            layer.lineJoin = .round
            self.layer.addSublayer(layer)
        }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        addGestureRecognizer(twoFingerPan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    // MARK: - Map gesture handlers

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let mapView else { return }
        switch recognizer.state {
        case .began:
            cancelStroke()
        case .changed:
            let scale = recognizer.scale
            guard scale > 0 else { return }
            mapView.zoomLevel += log2(scale)
            recognizer.scale = 1.0
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard let mapView else { return }
        switch recognizer.state {
        case .began:
            cancelStroke()
        case .changed:
            let translation = recognizer.translation(in: mapView)
            let centerPt = mapView.convert(mapView.centerCoordinate, toPointTo: mapView)
            let newCenterPt = CGPoint(x: centerPt.x - translation.x, y: centerPt.y - translation.y)
            mapView.centerCoordinate = mapView.convert(newCenterPt, toCoordinateFrom: mapView)
            recognizer.setTranslation(.zero, in: mapView)
        default:
            break
        }
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if (event?.allTouches?.count ?? touches.count) > 1 {
            cancelStroke()
            return
        }
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch

        let point = touch.location(in: self)
        let coordinate = coordinate(for: point)

        screenPoints = [point]
        lastCoordinate = coordinate
        runningMeters = 0
        anchorScreenPoint = nil

        if let anchor = anchorProvider?() {
            runningMeters = DistanceMeasurement.meters(from: anchor, to: coordinate)
            anchorScreenPoint = screenPoint(for: anchor)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if (event?.allTouches?.count ?? touches.count) > 1 {
            cancelStroke()
            return
        }
        guard let active = activeTouch, touches.contains(active),
              let previousPoint = screenPoints.last else { return }

        let point = active.location(in: self)
        guard hypot(point.x - previousPoint.x, point.y - previousPoint.y) >= minSampleSpacing else { return }

        let coordinate = coordinate(for: point)
        if let last = lastCoordinate {
            runningMeters += DistanceMeasurement.meters(from: last, to: coordinate)
        }
        screenPoints.append(point)
        lastCoordinate = coordinate

        onStrokeProgress?(runningMeters)
        redrawPreview()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }

        let simplified = LineSimplifier.simplify(screenPoints, tolerance: simplifyTolerance)
        let coordinates = simplified.map(coordinate(for:))
        resetStroke()
        onStrokeFinished?(coordinates.count >= 2 ? coordinates : [])
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
        cancelStroke()
    }

    private func cancelStroke() {
        guard activeTouch != nil else { return }
        resetStroke()
        onStrokeFinished?([])
    }

    private func resetStroke() {
        activeTouch = nil
        screenPoints.removeAll()
        lastCoordinate = nil
        anchorScreenPoint = nil
        runningMeters = 0
        casingLayer.path = nil
        strokeLayer.path = nil
    }

    // MARK: - Drawing

    private func redrawPreview() {
        guard !screenPoints.isEmpty else {
            casingLayer.path = nil
            strokeLayer.path = nil
            return
        }

        let path = UIBezierPath()
        if let anchorScreenPoint {
            path.move(to: anchorScreenPoint)
            path.addLine(to: screenPoints[0])
        } else {
            path.move(to: screenPoints[0])
        }
        for point in screenPoints.dropFirst() {
            path.addLine(to: point)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        casingLayer.frame = bounds
        strokeLayer.frame = bounds
        casingLayer.path = path.cgPath
        strokeLayer.path = path.cgPath
        CATransaction.commit()
    }

    // MARK: - Conversion

    private func coordinate(for point: CGPoint) -> CLLocationCoordinate2D {
        mapView?.convert(point, toCoordinateFrom: self) ?? kCLLocationCoordinate2DInvalid
    }

    private func screenPoint(for coordinate: CLLocationCoordinate2D) -> CGPoint? {
        mapView.map { $0.convert(coordinate, toPointTo: self) }
    }
}

struct MapView: UIViewRepresentable {
    @Binding var metersPerPoint: Double
    @Binding var visibleMapRect: MKMapRect
    @Binding var centerTileCoordinate: String?
    @Binding var trackingMode: MLNUserTrackingMode

    let measurement: DistanceMeasurement
    let isMeasuring: Bool
    let routeVersion: Int
    var routeFitToken: Int = 0
    let selectedPlace: PlaceResult?

    let isRegionPreviewVisible: Bool

    var isSlopeLayerVisible: Bool = false

    let pins: [SavedPin]
    var onDropPin: ((CLLocationCoordinate2D) -> Void)?
    var onSavePlace: ((PlaceResult) -> Void)?
    var onDismissPlace: (() -> Void)?
    var onOpenPinDetail: ((SavedPin) -> Void)?

    static func buildStyleURL() -> URL {
        let settings = RemoteSettings.shared.settings
        let kartverketUrl = KartverketTileProxy.shared?.tileURLTemplate ?? settings.kartverketUrl
        let json = """
        {
          "version": 8,
          "sources": {
            "lantmateriet": {
              "type": "raster",
              "tiles": ["\(settings.lantmaterietUrl)"],
              "tileSize": 256,
              "minzoom": 0,
              "maxzoom": \(TileServer.lantmateriet.sourceMaximumZ)
            },
            "kartverket": {
              "type": "raster",
              "tiles": ["\(kartverketUrl)"],
              "tileSize": 256,
              "minzoom": 0,
              "maxzoom": \(TileServer.kartverket.sourceMaximumZ)
            },
            "norway-slope": {
              "type": "raster",
              "tiles": ["\(settings.norwaySlopeUrl)"],
              "tileSize": 256,
              "minzoom": 5,
              "maxzoom": \(TileServer.norwaySlope.sourceMaximumZ)
            },
            "sweden-slope": {
              "type": "raster",
              "tiles": ["\(settings.swedenSlopeUrl)"],
              "tileSize": 256,
              "minzoom": 5,
              "maxzoom": \(TileServer.swedenSlope.sourceMaximumZ)
            }
          },
          "layers": [
            {"id": "lantmateriet-layer", "type": "raster", "source": "lantmateriet"},
            {"id": "kartverket-layer", "type": "raster", "source": "kartverket"},
            {"id": "norway-slope-layer", "type": "raster", "source": "norway-slope", "paint": {"raster-opacity": 0.6}},
            {"id": "sweden-slope-layer", "type": "raster", "source": "sweden-slope", "paint": {"raster-opacity": 0.6}}
          ]
        }
        """
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("maplibre-map-style.json")
        try? json.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(metersPerPoint: $metersPerPoint,
                    visibleMapRect: $visibleMapRect,
                    centerTileCoordinate: $centerTileCoordinate,
                    trackingMode: $trackingMode)
    }

    func makeUIView(context: Context) -> MLNMapView {
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(500 * 1024 * 1024) { _ in } // 500mb

        let mapView = MLNMapView(frame: .zero, styleURL: Self.buildStyleURL())
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.compassViewMargins = CGPoint(x: 12, y: 12)
        mapView.showsUserLocation = false
        mapView.isPitchEnabled = false
        mapView.overrideUserInterfaceStyle = .light
        mapView.automaticallyAdjustsContentInset = false
        mapView.setCenter(
            CLLocationCoordinate2D(latitude: 67.0, longitude: 16),
            zoomLevel: 3.4,
            animated: false
        )

        mapView.maximumScreenBounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: 40.0, longitude: -10.0),
            ne: CLLocationCoordinate2D(latitude: 76.0, longitude: 50.0)
        )

        context.coordinator.start(with: mapView)
        context.coordinator.installCaptureView(on: mapView, measurement: measurement)
        context.coordinator.installRegionPreviewBorder(on: mapView)
        context.coordinator.installLongPressRecognizer(on: mapView)

        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        context.coordinator.onDropPin = onDropPin
        context.coordinator.onSavePlace = onSavePlace
        context.coordinator.onDismissPlace = onDismissPlace
        context.coordinator.onOpenPinDetail = onOpenPinDetail
        context.coordinator.setTrackingMode(trackingMode, on: uiView)
        context.coordinator.setMeasuring(isMeasuring, on: uiView)
        context.coordinator.setRoute(measurement.coordinates, version: routeVersion, on: uiView)
        context.coordinator.fitRouteIfNeeded(on: uiView, fitToken: routeFitToken)
        context.coordinator.syncSelection(selectedPlace, on: uiView)
        context.coordinator.syncRegionPreview(isVisible: isRegionPreviewVisible)
        context.coordinator.setSlopeVisible(isSlopeLayerVisible)
        context.coordinator.syncPins(on: uiView, pins: pins)
        context.coordinator.setLongPressEnabled(!isMeasuring && !isRegionPreviewVisible)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, CLLocationManagerDelegate {
        static let searchMarkerIdentifier = "SearchResultMarker"

        let locationManager = CLLocationManager()
        @Binding var metersPerPoint: Double
        @Binding var visibleMapRect: MKMapRect
        @Binding var centerTileCoordinate: String?
        @Binding var trackingMode: MLNUserTrackingMode

        private weak var mapView: MLNMapView?
        private var captureView: MapLibreMeasureCaptureView?
        private weak var longPressRecognizer: UILongPressGestureRecognizer?
        private weak var regionPreviewBorder: RegionPreviewBorderView?

        private var slopeLayers: [MLNRasterStyleLayer] = []
        private var routeSource: MLNShapeSource?
        private var endpointStartSource: MLNShapeSource?
        private var endpointEndSource: MLNShapeSource?
        private var renderedVersion = -1
        private var renderedRouteCoordinates: [CLLocationCoordinate2D] = []
        private var renderedFitToken = 0
        /// Coordinates requested before the style/sources existed (e.g. a route
        /// selected while the style was still loading), applied once ready.
        private var pendingRouteCoordinates: [CLLocationCoordinate2D] = []

        private var markerAnnotations: [RouteDistanceMarker] = []
        private var renderedMarkerSpacing: Double = 0

        private var renderedPins: [SavedPin] = []
        private var shownPlaceID: Int64?
        private var wantsTrackingOnceAuthorized = false
        private var renderedTrackingMode: MLNUserTrackingMode = .none

        var onDropPin: ((CLLocationCoordinate2D) -> Void)?
        var onSavePlace: ((PlaceResult) -> Void)?
        var onDismissPlace: (() -> Void)?
        var onOpenPinDetail: ((SavedPin) -> Void)?

        init(metersPerPoint: Binding<Double>,
             visibleMapRect: Binding<MKMapRect>,
             centerTileCoordinate: Binding<String?>,
             trackingMode: Binding<MLNUserTrackingMode>) {
            _metersPerPoint = metersPerPoint
            _visibleMapRect = visibleMapRect
            _centerTileCoordinate = centerTileCoordinate
            _trackingMode = trackingMode
        }

        func start(with mapView: MLNMapView) {
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

        func installCaptureView(on map: MLNMapView, measurement: DistanceMeasurement) {
            let capture = MapLibreMeasureCaptureView(mapView: map)
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

        /// MapLibre's own gesture recognizers are attached directly to the map
        /// view itself — an ancestor of the capture view — so they still
        /// receive the same touches even once the capture view is on top. They
        /// must be disabled explicitly, or a single-finger drag both draws
        /// *and* pans the map underneath it.
        func setMeasuring(_ isMeasuring: Bool, on map: MLNMapView) {
            guard let captureView, captureView.isUserInteractionEnabled != isMeasuring else { return }
            captureView.isUserInteractionEnabled = isMeasuring
            map.isScrollEnabled = !isMeasuring
            map.isZoomEnabled = !isMeasuring
            map.isRotateEnabled = !isMeasuring
            if isMeasuring {
                map.bringSubviewToFront(captureView)
            }
        }

        // MARK: - Route + endpoints

        func setRoute(_ coordinates: [CLLocationCoordinate2D], version: Int, on mapView: MLNMapView) {
            pendingRouteCoordinates = coordinates
            guard version != renderedVersion else { return }
            renderedVersion = version
            applyPendingRoute(on: mapView)
        }

        private func applyPendingRoute(on mapView: MLNMapView) {
            guard let routeSource, let endpointStartSource, let endpointEndSource else { return }
            let coordinates = pendingRouteCoordinates
            renderedRouteCoordinates = coordinates

            guard coordinates.count >= 2 else {
                routeSource.shape = nil
                endpointStartSource.shape = nil
                endpointEndSource.shape = nil
                renderedMarkerSpacing = 0
                syncDistanceMarkers(on: mapView, force: true)
                return
            }

            var mutableCoordinates = coordinates
            routeSource.shape = MLNPolylineFeature(coordinates: &mutableCoordinates, count: UInt(mutableCoordinates.count))

            let start = MLNPointAnnotation()
            start.coordinate = coordinates[0]
            endpointStartSource.shape = start

            let end = MLNPointAnnotation()
            end.coordinate = coordinates[coordinates.count - 1]
            endpointEndSource.shape = end

            syncDistanceMarkers(on: mapView, force: true)
        }

        /// Recenters on the route, gated by `fitToken` so this only fires when
        /// a saved route is loaded, never on every freehand stroke.
        func fitRouteIfNeeded(on mapView: MLNMapView, fitToken: Int) {
            guard fitToken != renderedFitToken else { return }
            renderedFitToken = fitToken

            let coordinates = pendingRouteCoordinates
            guard coordinates.count >= 2 else { return }

            var bounds = MLNCoordinateBounds(sw: coordinates[0], ne: coordinates[0])
            for coordinate in coordinates {
                bounds.sw.longitude = min(bounds.sw.longitude, coordinate.longitude)
                bounds.sw.latitude = min(bounds.sw.latitude, coordinate.latitude)
                bounds.ne.longitude = max(bounds.ne.longitude, coordinate.longitude)
                bounds.ne.latitude = max(bounds.ne.latitude, coordinate.latitude)
            }
            mapView.setVisibleCoordinateBounds(bounds,
                                               edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40),
                                               animated: true,
                                               completionHandler: nil)
        }

        // MARK: - Distance markers

        func syncDistanceMarkers(on mapView: MLNMapView, force: Bool = false) {
            let spacing = renderedRouteCoordinates.count >= 2
                ? DistanceMeasurement.markerSpacing(forZoomLevel: mapView.zoomLevel,
                                                    routeLength: DistanceMeasurement.length(of: renderedRouteCoordinates))
                : 0
            guard force || spacing != renderedMarkerSpacing else { return }
            renderedMarkerSpacing = spacing

            mapView.removeAnnotations(markerAnnotations)
            markerAnnotations = []
            guard spacing > 0 else { return }

            markerAnnotations = DistanceMeasurement.distanceMarkers(along: renderedRouteCoordinates, spacing: spacing).map {
                RouteDistanceMarker(coordinate: $0.coordinate, meters: $0.meters)
            }
            mapView.addAnnotations(markerAnnotations)
        }

        // MARK: - Offline region preview

        func installRegionPreviewBorder(on map: MLNMapView) {
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

        func setSlopeVisible(_ visible: Bool) {
            for layer in slopeLayers where layer.isVisible != visible {
                layer.isVisible = visible
            }
        }

        // MARK: - Search selection

        func syncSelection(_ place: PlaceResult?, on mapView: MLNMapView) {
            guard shownPlaceID != place?.id else { return }
            shownPlaceID = place?.id

            if let existing = mapView.annotations?.compactMap({ $0 as? SearchResultAnnotation }), !existing.isEmpty {
                mapView.removeAnnotations(existing)
            }
            guard let place else { return }

            let annotation = SearchResultAnnotation(result: place)
            mapView.addAnnotation(annotation)

            // Zoom in only when the map is currently wider than this; staying
            // put avoids yanking the user out of a close-up they chose.
            let currentBounds = mapView.visibleCoordinateBounds
            let currentSpan = currentBounds.ne.longitude - currentBounds.sw.longitude
            let span = min(currentSpan, 0.12)
            let halfSpan = span / 2
            let newBounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: place.coordinate.latitude - halfSpan,
                                           longitude: place.coordinate.longitude - halfSpan),
                ne: CLLocationCoordinate2D(latitude: place.coordinate.latitude + halfSpan,
                                           longitude: place.coordinate.longitude + halfSpan)
            )
            mapView.setVisibleCoordinateBounds(newBounds,
                                               edgePadding: .zero,
                                               animated: true) { [weak mapView] in
                guard let mapView, mapView.annotations?.contains(where: { $0 === annotation }) == true else { return }
                mapView.selectAnnotation(annotation, animated: true, completionHandler: nil)
            }
        }

        // MARK: - Saved pins

        func syncPins(on map: MLNMapView, pins: [SavedPin]) {
            guard pins != renderedPins else { return }
            renderedPins = pins

            let existing = map.annotations?.compactMap { $0 as? SavedPinMapAnnotation } ?? []
            map.removeAnnotations(existing)
            map.addAnnotations(pins.map { SavedPinMapAnnotation(pin: $0) })
        }

        func installLongPressRecognizer(on map: MLNMapView) {
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

        // MARK: - User tracking / location permission

        func setTrackingMode(_ mode: MLNUserTrackingMode, on mapView: MLNMapView) {
            guard mode != renderedTrackingMode else { return }
            renderedTrackingMode = mode

            guard mode != .none, !isAuthorized else {
                mapView.setUserTrackingMode(mode, animated: true, completionHandler: nil)
                return
            }
            wantsTrackingOnceAuthorized = true
            locationManager.requestWhenInUseAuthorization()
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            guard let mapView else { return }
            mapView.showsUserLocation = isAuthorized

            guard wantsTrackingOnceAuthorized else { return }
            wantsTrackingOnceAuthorized = false
            if isAuthorized {
                mapView.setUserTrackingMode(.follow, animated: true, completionHandler: nil)
                renderedTrackingMode = .follow
                trackingMode = .follow
            }
        }

        // MARK: - MLNMapViewDelegate

        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            // Keeps the button in sync when MapLibre resets tracking to
            // .none on its own, e.g. the user panning the map away.
            renderedTrackingMode = mode
            DispatchQueue.main.async { [weak self] in
                self?.trackingMode = mode
            }
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            updateRegion(for: mapView)
            syncDistanceMarkers(on: mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            updateRegion(for: mapView)
            syncDistanceMarkers(on: mapView)
        }

        private func updateRegion(for mapView: MLNMapView) {
            let bounds = mapView.visibleCoordinateBounds
            let centerLatitude = (bounds.sw.latitude + bounds.ne.latitude) / 2
            let longitudeDelta = bounds.ne.longitude - bounds.sw.longitude
            let metersPerDegree = cos(centerLatitude * .pi / 180) * 111_319.5
            let updatedMetersPerPoint = mapView.bounds.width > 0
                ? longitudeDelta * metersPerDegree / mapView.bounds.width
                : 0

            var rect = MKMapRect(origin: MKMapPoint(bounds.sw), size: MKMapSize(width: 0, height: 0))
            rect = rect.union(MKMapRect(origin: MKMapPoint(bounds.ne), size: MKMapSize(width: 0, height: 0)))
            let updatedZoomLevel = (mapView.zoomLevel + log2(512.0 / 256.0)).rounded()
            let tileZoom = Int(updatedZoomLevel)
            let updatedCenterTileCoordinate = TilePyramid
                .tileCoordinate(for: mapView.centerCoordinate, z: tileZoom)
                .map { "\(tileZoom)/\($0.x)/\($0.y)" }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                if metersPerPoint != updatedMetersPerPoint {
                    metersPerPoint = updatedMetersPerPoint
                }
                if !MKMapRectEqualToRect(visibleMapRect, rect) {
                    visibleMapRect = rect
                }
                if centerTileCoordinate != updatedCenterTileCoordinate {
                    centerTileCoordinate = updatedCenterTileCoordinate
                }
            }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if let routeMarker = annotation as? RouteDistanceMarker {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: RouteDistanceMarkerView.reuseIdentifier)
                    as? RouteDistanceMarkerView
                    ?? RouteDistanceMarkerView(reuseIdentifier: RouteDistanceMarkerView.reuseIdentifier)
                view.annotation = routeMarker
                return view
            }
            if annotation is SavedPinMapAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: SavedPinMarkerView.reuseIdentifier)
                    ?? SavedPinMarkerView(reuseIdentifier: SavedPinMarkerView.reuseIdentifier)
            }
            if annotation is SearchResultAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: Self.searchMarkerIdentifier)
                    ?? SearchResultMarkerView(reuseIdentifier: Self.searchMarkerIdentifier)
            }
            return nil
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            annotation is SearchResultAnnotation
        }

        func mapView(_ mapView: MLNMapView, leftCalloutAccessoryViewFor annotation: MLNAnnotation) -> UIView? {
            guard annotation is SearchResultAnnotation else { return nil }
            return calloutButton(systemName: "bookmark", tint: .systemOrange, tag: 0)
        }

        func mapView(_ mapView: MLNMapView, rightCalloutAccessoryViewFor annotation: MLNAnnotation) -> UIView? {
            guard annotation is SearchResultAnnotation else { return nil }
            return calloutButton(systemName: "xmark", tint: .secondaryLabel, tag: 1)
        }

        private func calloutButton(systemName: String, tint: UIColor, tag: Int) -> UIButton {
            let button = UIButton(type: .system)
            let symbol = UIImage(systemName: systemName,
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
            button.setImage(symbol, for: .normal)
            button.tintColor = tint
            button.tag = tag
            button.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            return button
        }

        func mapView(_ mapView: MLNMapView, annotation: MLNAnnotation, calloutAccessoryControlTapped control: UIControl) {
            guard let searchAnnotation = annotation as? SearchResultAnnotation else { return }
            if control.tag == 0 {
                onSavePlace?(searchAnnotation.result)
                mapView.removeAnnotation(searchAnnotation)
                onDismissPlace?()
            } else {
                mapView.removeAnnotation(searchAnnotation)
                onDismissPlace?()
            }
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let pinAnnotation = annotation as? SavedPinMapAnnotation else { return }
            onOpenPinDetail?(pinAnnotation.pin)
            mapView.deselectAnnotation(pinAnnotation, animated: false)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            slopeLayers = ["norway-slope-layer", "sweden-slope-layer"].compactMap {
                style.layer(withIdentifier: $0) as? MLNRasterStyleLayer
            }
            for layer in slopeLayers {
                layer.isVisible = false
            }

            let source = MLNShapeSource(identifier: "route", shape: nil, options: nil)
            style.addSource(source)
            routeSource = source

            let casingLayer = MLNLineStyleLayer(identifier: "route-casing", source: source)
            casingLayer.lineColor = NSExpression(forConstantValue: MeasurementStyle.casingColor)
            casingLayer.lineWidth = NSExpression(forConstantValue: MeasurementStyle.casingWidth)
            casingLayer.lineCap = NSExpression(forConstantValue: "round")
            casingLayer.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(casingLayer)

            let lineLayer = MLNLineStyleLayer(identifier: "route-line", source: source)
            lineLayer.lineColor = NSExpression(forConstantValue: MeasurementStyle.strokeColor)
            lineLayer.lineWidth = NSExpression(forConstantValue: MeasurementStyle.lineWidth)
            lineLayer.lineCap = NSExpression(forConstantValue: "round")
            lineLayer.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(lineLayer)

            let startSource = MLNShapeSource(identifier: "route-endpoint-start", shape: nil, options: nil)
            let endSource = MLNShapeSource(identifier: "route-endpoint-end", shape: nil, options: nil)
            style.addSource(startSource)
            style.addSource(endSource)
            endpointStartSource = startSource
            endpointEndSource = endSource

            let startLayer = MLNCircleStyleLayer(identifier: "route-endpoint-start-layer", source: startSource)
            startLayer.circleRadius = NSExpression(forConstantValue: MeasurementStyle.endpointRadius)
            startLayer.circleColor = NSExpression(forConstantValue: MeasurementStyle.casingColor)
            startLayer.circleStrokeColor = NSExpression(forConstantValue: MeasurementStyle.strokeColor)
            startLayer.circleStrokeWidth = NSExpression(forConstantValue: 2.5)
            style.addLayer(startLayer)

            let endLayer = MLNCircleStyleLayer(identifier: "route-endpoint-end-layer", source: endSource)
            endLayer.circleRadius = NSExpression(forConstantValue: MeasurementStyle.endpointRadius)
            endLayer.circleColor = NSExpression(forConstantValue: MeasurementStyle.strokeColor)
            endLayer.circleStrokeColor = NSExpression(forConstantValue: MeasurementStyle.casingColor)
            endLayer.circleStrokeWidth = NSExpression(forConstantValue: 2.5)
            style.addLayer(endLayer)

            applyPendingRoute(on: mapView)
        }
    }
}
