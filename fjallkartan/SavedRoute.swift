import CoreLocation
import Foundation

struct SavedRoute: Identifiable, Codable, Hashable {
    static let currentSchemaVersion = 1

    let id: UUID
    let createdAt: Date
    let meters: Double
    let coordinates: [Coord]
    let strokeSizes: [Int] // To support undo
    let ascent: Double
    let descent: Double
    /// Sampled terrain heights along the route, evenly spaced by
    /// `ElevationProfile.sampleSpacingMeters`. Stored so a saved route can draw
    /// its profile without the elevation tiles, which a device that never
    /// downloaded the region would otherwise have to fetch. A `nil` element is
    /// a stretch the tiles had no data for.
    let elevations: [Double?]
    let schemaVersion: Int

    init(id: UUID = UUID(),
         createdAt: Date = Date(),
         meters: Double,
         coordinates: [Coord],
         strokeSizes: [Int],
         ascent: Double = 0,
         descent: Double = 0,
         elevations: [Double?] = [],
         schemaVersion: Int = SavedRoute.currentSchemaVersion) {
        self.id = id
        self.createdAt = createdAt
        self.meters = meters
        self.coordinates = coordinates
        self.strokeSizes = strokeSizes
        self.ascent = ascent
        self.descent = descent
        self.elevations = elevations
        self.schemaVersion = schemaVersion
    }

    var displayName: String {
        Self.nameFormatter.string(from: createdAt)
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var formattedDistance: String {
        DistanceMeasurement.formattedDistance(meters: meters)
    }

    var hasElevation: Bool { elevations.contains { $0 != nil } }

    var formattedAscent: String { ElevationProfile.formatted(meters: ascent) }
    var formattedDescent: String { ElevationProfile.formatted(meters: descent) }
}
