import CoreLocation
import Foundation

/// Elevation profile of the measured route: the sampled heights along it, and
/// the ascent and descent totals derived from them.
@Observable
@MainActor
final class ElevationProfile {
    /// Spacing the route is resampled at. The tiles are ~18 m per pixel at 62°N,
    /// so sampling much finer than this only re-reads the same pixel.
    nonisolated static let sampleSpacingMeters: Double = 25

    /// Upper bound on samples, so a 200 km route stays as cheap as a 5 km one.
    /// Beyond this the spacing widens instead.
    nonisolated static let maxSamples = 500

    /// A climb must exceed this before it counts. Without it, metre-level noise
    /// in the model accumulates into hundreds of phantom metres over a long
    /// route; measured, it removes about 2.5% of the total.
    nonisolated static let hysteresisMeters: Double = 4

    struct Point: Equatable {
        /// Distance along the route in metres.
        let distance: Double // metres
        /// Terrain height in metres, or `nil` where the tiles have no data.
        let elevation: Double?
    }

    private(set) var points: [Point] = []
    private(set) var ascent: Double = 0
    private(set) var descent: Double = 0
    private(set) var minimum: Double?
    private(set) var maximum: Double?
    /// Fraction of samples the tiles could answer, 0...1.
    private(set) var coverage: Double = 0
    private(set) var isLoading = false

    var hasData: Bool { coverage > 0 && points.count >= 2 }

    /// Whether a meaningful part of the route fell outside the tiles
    var isPartial: Bool { hasData && coverage < 0.95 }

    private let service: ElevationService

    init(service: ElevationService = .shared) {
        self.service = service
    }

    // MARK: - Updating

    func clear() {
        points = []
        ascent = 0
        descent = 0
        minimum = nil
        maximum = nil
        coverage = 0
        isLoading = false
    }

    /// Resamples `coordinates`, looks the heights up and recomputes the totals.
    /// Safe to cancel: a superseded run leaves the previous result in place
    /// rather than blanking the readout.
    func update(for coordinates: [CLLocationCoordinate2D]) async {
        guard coordinates.count >= 2 else {
            clear()
            return
        }

        let samples = Self.resample(coordinates)
        guard samples.count >= 2 else {
            clear()
            return
        }

        isLoading = true
        let elevations = await service.heights(for: samples.map(\.coordinate))
        guard !Task.isCancelled else { return }

        let points = zip(samples, elevations).map {
            Point(distance: $0.distance, elevation: $1)
        }

        // A route loaded from disk already carries its heights. If the tiles
        // cannot be reached — offline, outside a downloaded region — keep what
        // we have rather than replacing a real profile with an empty one.
        if points.allSatisfy({ $0.elevation == nil }), hasData {
            isLoading = false
            return
        }
        apply(points)
    }

    private func apply(_ points: [Point]) {
        let known = points.compactMap(\.elevation)
        let totals = Self.gain(for: points.map(\.elevation))

        self.points = points
        ascent = totals.ascent
        descent = totals.descent
        minimum = known.min()
        maximum = known.max()
        coverage = points.isEmpty ? 0 : Double(known.count) / Double(points.count)
        isLoading = false
    }

    /// Restores a previously saved profile, so loading a route shows its climb
    /// immediately and without touching the tiles.
    func load(_ route: SavedRoute) {
        guard !route.elevations.isEmpty else {
            clear()
            return
        }
        let step = route.elevations.count > 1
            ? route.meters / Double(route.elevations.count - 1)
            : 0
        apply(route.elevations.enumerated().map {
            Point(distance: Double($0.offset) * step, elevation: $0.element)
        })
    }

    // MARK: - Resampling

    struct Sample: Equatable {
        let coordinate: CLLocationCoordinate2D
        let distance: Double

        static func == (lhs: Sample, rhs: Sample) -> Bool {
            lhs.distance == rhs.distance
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    /// Walks the route emitting a coordinate every `spacing` metres.
    ///
    /// The drawn route has vertices wherever the finger happened to be sampled,
    /// which is far too uneven to integrate climb from directly; a fixed
    /// spacing makes the totals independent of how fast the route was traced.
    nonisolated static func resample(_ coordinates: [CLLocationCoordinate2D],
                         spacing: Double = sampleSpacingMeters,
                         maxSamples: Int = maxSamples) -> [Sample] {
        guard coordinates.count >= 2, maxSamples >= 2 else {
            return coordinates.map { Sample(coordinate: $0, distance: 0) }
        }

        let total = DistanceMeasurement.length(of: coordinates)
        guard total > 0 else {
            return [Sample(coordinate: coordinates[0], distance: 0)]
        }

        // Widen the spacing rather than the sample count on a long route.
        let step = max(spacing, total / Double(maxSamples - 1))

        var samples = [Sample(coordinate: coordinates[0], distance: 0)]
        var target = step
        var travelled: Double = 0

        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            let segment = DistanceMeasurement.meters(from: start, to: end)
            guard segment > 0 else { continue }
            while target <= travelled + segment, samples.count < maxSamples {
                let fraction = (target - travelled) / segment
                samples.append(Sample(coordinate: interpolate(start, end, fraction),
                                      distance: target))
                target += step
            }
            travelled += segment
        }

        // Include the far end when the last step landed short of it — otherwise
        // a route shorter than one step would collapse to a single sample.
        if let last = coordinates.last, samples.count < maxSamples,
           total - (samples.last?.distance ?? 0) > 0.5 {
            samples.append(Sample(coordinate: last, distance: total))
        }
        return samples
    }

    nonisolated private static func interpolate(_ start: CLLocationCoordinate2D,
                                    _ end: CLLocationCoordinate2D,
                                    _ fraction: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
    }

    // MARK: - Ascent and descent

    /// Total climb and drop, ignoring wobbles smaller than `hysteresis`.
    ///
    /// A gap in the data breaks the run: heights either side of a stretch the
    /// tiles could not answer are not compared, since the terrain in between is
    /// unknown and the step across it would be invented.
    nonisolated static func gain(for elevations: [Double?],
                     hysteresis: Double = hysteresisMeters) -> (ascent: Double, descent: Double) {
        var ascent: Double = 0
        var descent: Double = 0
        var reference: Double?

        for elevation in elevations {
            guard let elevation else {
                reference = nil
                continue
            }
            guard let previous = reference else {
                reference = elevation
                continue
            }
            let delta = elevation - previous
            if delta >= hysteresis {
                ascent += delta
                reference = elevation
            } else if delta <= -hysteresis {
                descent -= delta
                reference = elevation
            }
        }
        return (ascent, descent)
    }

    // MARK: - Formatting

    nonisolated(unsafe) private static let formatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    nonisolated static func formatted(meters: Double) -> String {
        formatter.string(from: Measurement(value: meters.rounded(), unit: UnitLength.meters))
    }

    var formattedAscent: String { Self.formatted(meters: ascent) }
    var formattedDescent: String { Self.formatted(meters: descent) }
}
