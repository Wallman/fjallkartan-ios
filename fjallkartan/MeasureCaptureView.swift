import MapKit
import UIKit

enum MeasurementStyle {
    static let lineWidth: CGFloat = 4
    static let strokeColor = UIColor.systemOrange
    static let casingColor = UIColor.white
    static let casingWidth: CGFloat = 7
    static let endpointRadius: CGFloat = 6
}

/// Transparent view layered over the map that captures freehand strokes.
///
/// It is only interactive while measuring; when it is, it swallows every touch,
/// which is what keeps MapKit's pan/zoom/rotate recognisers from competing with
/// drawing. Live feedback is drawn in screen space so the map never has to
/// re-render mid-drag.
final class MeasureCaptureView: UIView {
    /// Endpoint the current stroke connects back to, if a route already exists.
    var anchorProvider: (() -> CLLocationCoordinate2D?)?
    /// Running length of the in-progress stroke, including its connector.
    var onStrokeProgress: ((Double) -> Void)?
    var onStrokeFinished: (([CLLocationCoordinate2D]) -> Void)?

    private weak var mapView: MKMapView?

    private let casingLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()

    private var activeTouch: UITouch?
    private var screenPoints: [CGPoint] = []
    private var lastCoordinate: CLLocationCoordinate2D?
    private var runningMeters: Double = 0
    private var anchorScreenPoint: CGPoint?

    /// Minimum spacing between accepted samples. This is the main guard against
    /// finger jitter inflating the measured distance.
    private let minSampleSpacing: CGFloat = 3
    private let simplifyTolerance: CGFloat = 2

    init(mapView: MKMapView) {
        self.mapView = mapView
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isMultipleTouchEnabled = false

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
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

        onStrokeProgress?(runningMeters)
        redrawPreview()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
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
        // A tap without movement is not a measurement.
        onStrokeFinished?(coordinates.count >= 2 ? coordinates : [])
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
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

        // Layer geometry changes are implicitly animated, which lags behind the finger.
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
