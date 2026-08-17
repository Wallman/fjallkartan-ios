import CoreLocation
import Foundation

/// Holds the freehand distance measurement drawn on the map.
///
/// The route is stored as one continuous list of coordinates. Each finger stroke
/// appends to it, so the user can pan between strokes and keep tracing a long
/// route; consecutive strokes are joined by a straight connecting segment.
@Observable
final class DistanceMeasurement {
    var isMeasuring = false {
        didSet {
            if !isMeasuring { previewMeters = nil }
        }
    }

    /// Route vertices in draw order.
    private(set) var coordinates: [CLLocationCoordinate2D] = []

    /// Distance of the committed route.
    private(set) var committedMeters: Double = 0

    /// Length of the in-progress stroke (including its connector to the committed
    /// route), shown live while the finger is down.
    var previewMeters: Double?

    /// Bumped on every mutation so `MapView` knows when to rebuild its overlay.
    private(set) var version = 0

    /// Number of coordinates contributed by each committed stroke, used for undo.
    private(set) var strokeSizes: [Int] = []

    var totalMeters: Double { committedMeters + (previewMeters ?? 0) }
    var isEmpty: Bool { coordinates.isEmpty }
    var canUndo: Bool { !strokeSizes.isEmpty }

    /// Endpoint a new stroke connects back to.
    var anchor: CLLocationCoordinate2D? { coordinates.last }

    func appendStroke(_ stroke: [CLLocationCoordinate2D]) {
        previewMeters = nil
        guard stroke.count >= 2 else { return }
        coordinates.append(contentsOf: stroke)
        strokeSizes.append(stroke.count)
        committedMeters = Self.length(of: coordinates)
        version += 1
    }

    func undoLastStroke() {
        guard let size = strokeSizes.popLast() else { return }
        coordinates.removeLast(size)
        committedMeters = Self.length(of: coordinates)
        previewMeters = nil
        version += 1
    }

    func clear() {
        guard !coordinates.isEmpty || previewMeters != nil else { return }
        coordinates.removeAll()
        strokeSizes.removeAll()
        committedMeters = 0
        previewMeters = nil
        version += 1
    }

    // MARK: - Saved routes

    func snapshot(elevation: ElevationProfile? = nil) -> SavedRoute {
        SavedRoute(meters: committedMeters,
                   coordinates: coordinates.map { Coord($0) },
                   strokeSizes: strokeSizes,
                   ascent: elevation?.ascent ?? 0,
                   descent: elevation?.descent ?? 0,
                   elevations: elevation?.points.map(\.elevation) ?? [])
    }

    func load(_ route: SavedRoute) {
        coordinates = route.coordinates.map(\.coordinate)
        strokeSizes = route.strokeSizes
        committedMeters = route.meters
        previewMeters = nil
        version += 1
    }

    // MARK: - Distance

    /// Geodesic distance, which stays accurate at Nordic latitudes where a
    /// Mercator-space measurement would overstate by a factor of ~2.5.
    nonisolated static func meters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    nonisolated static func length(of coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        return zip(coordinates, coordinates.dropFirst())
            .reduce(0) { $0 + meters(from: $1.0, to: $1.1) }
    }

    // MARK: - Formatting

    private static let metersFormatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitOptions = .providedUnit
        f.numberFormatter.maximumFractionDigits = 0
        return f
    }()

    private static let kilometersFormatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitOptions = .providedUnit
        f.numberFormatter.minimumFractionDigits = 2
        f.numberFormatter.maximumFractionDigits = 2
        return f
    }()

    var formattedDistance: String {
        Self.formattedDistance(meters: totalMeters)
    }

    static func formattedDistance(meters: Double) -> String {
        if meters < 1000 {
            return metersFormatter.string(from: Measurement(value: meters.rounded(),
                                                             unit: UnitLength.meters))
        }
        return kilometersFormatter.string(from: Measurement(value: meters / 1000,
                                                             unit: UnitLength.kilometers))
    }
}

/// Ramer–Douglas–Peucker simplification to counter ~3% finger jitter, run in screen space so the tolerance scales naturally with zoom.
enum LineSimplifier {
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var maxDistance: CGFloat = -1
            var farthest = first
            for i in (first + 1)..<last {
                let d = perpendicularDistance(points[i], from: points[first], to: points[last])
                if d > maxDistance {
                    maxDistance = d
                    farthest = i
                }
            }
            if maxDistance > tolerance {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }

        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    private static func perpendicularDistance(_ p: CGPoint,
                                              from a: CGPoint,
                                              to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        guard dx != 0 || dy != 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)
        let clamped = max(0, min(1, t))
        return hypot(p.x - (a.x + clamped * dx), p.y - (a.y + clamped * dy))
    }
}
