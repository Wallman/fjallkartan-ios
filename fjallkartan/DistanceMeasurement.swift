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

    private(set) var hasUnsavedChanges = false

    private(set) var loadedRouteName: String?

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
        hasUnsavedChanges = true
        version += 1
    }

    func undoLastStroke() {
        guard let size = strokeSizes.popLast() else { return }
        coordinates.removeLast(size)
        committedMeters = Self.length(of: coordinates)
        previewMeters = nil
        hasUnsavedChanges = true
        version += 1
    }

    func clear() {
        guard !coordinates.isEmpty || previewMeters != nil else { return }
        coordinates.removeAll()
        strokeSizes.removeAll()
        committedMeters = 0
        previewMeters = nil
        hasUnsavedChanges = false
        loadedRouteName = nil
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
        hasUnsavedChanges = false
        loadedRouteName = route.displayName
        isMeasuring = false
        version += 1
    }

    func markSaved(as name: String? = nil) {
        hasUnsavedChanges = false
        if let name { loadedRouteName = name }
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

    // MARK: - Distance markers

    struct DistanceMarkerPoint {
        let coordinate: CLLocationCoordinate2D
        let meters: Double
    }

    private nonisolated static let markerSpacings: [Double] = [1_000, 2_000, 5_000, 10_000, 25_000, 50_000, 100_000]
    private nonisolated static let maximumMarkers = 60

    nonisolated static func markerSpacing(forRouteLength meters: Double) -> Double {
        markerSpacings.first { meters / $0 <= Double(maximumMarkers) } ?? markerSpacings[markerSpacings.count - 1]
    }

    nonisolated static func markerSpacing(forZoomLevel zoom: Double, routeLength meters: Double) -> Double {
        let byZoom: Double
        switch zoom {
        case ..<6: byZoom = 100_000
        case ..<7: byZoom = 100_000
        case ..<8: byZoom = 50_000
        case ..<9: byZoom = 25_000
        case ..<10: byZoom = 25_000
        case ..<11: byZoom = 10_000
        case ..<12: byZoom = 5_000
        case ..<13: byZoom = 2_000
        default: byZoom = 1_000
        }
        let byLength = markerSpacing(forRouteLength: meters)
        return max(byZoom, byLength)
    }

    /// Walks the route accumulating geodesic length and emits a point every
    /// `spacing` metres, interpolating inside the segment that crosses it.
    nonisolated static func distanceMarkers(along coordinates: [CLLocationCoordinate2D],
                                            spacing: Double? = nil) -> [DistanceMarkerPoint] {
        guard coordinates.count >= 2 else { return [] }
        let total = length(of: coordinates)
        let step = spacing ?? markerSpacing(forRouteLength: total)
        guard step > 0, total >= step else { return [] }

        var markers: [DistanceMarkerPoint] = []
        var travelled: Double = 0
        var next = step

        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let segment = meters(from: a, to: b)
            guard segment > 0 else { continue }
            while next <= travelled + segment {
                let t = (next - travelled) / segment
                markers.append(DistanceMarkerPoint(coordinate: interpolate(from: a, to: b, fraction: t),
                                                   meters: next))
                next += step
            }
            travelled += segment
        }
        return markers
    }

    /// Linear interpolation is accurate enough here: segments are short enough
    /// that the great-circle and the straight lat/lon path are indistinguishable.
    private nonisolated static func interpolate(from a: CLLocationCoordinate2D,
                                                to b: CLLocationCoordinate2D,
                                                fraction: Double) -> CLLocationCoordinate2D {
        var deltaLongitude = b.longitude - a.longitude
        if deltaLongitude > 180 { deltaLongitude -= 360 }
        if deltaLongitude < -180 { deltaLongitude += 360 }
        var longitude = a.longitude + deltaLongitude * fraction
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                                      longitude: longitude)
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

    private static let markerFormatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitOptions = .providedUnit
        f.unitStyle = .medium
        f.numberFormatter.maximumFractionDigits = 0
        return f
    }()

    static func markerLabel(meters: Double) -> String {
        markerFormatter.string(from: Measurement(value: (meters / 1000).rounded(),
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
