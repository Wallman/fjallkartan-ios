import CoreLocation

/// A plain lat/lon pair, since `CLLocationCoordinate2D` itself isn't `Codable`.
/// `nonisolated` because the project defaults to `MainActor` isolation, which
/// would isolate the synthesized `Hashable`/`Equatable` conformances too — and
/// this is a value type compared and persisted off the main thread.
nonisolated struct Coord: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
