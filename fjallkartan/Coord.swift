import CoreLocation

/// A plain lat/lon pair, since `CLLocationCoordinate2D` itself isn't `Codable`.
struct Coord: Codable, Hashable {
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
