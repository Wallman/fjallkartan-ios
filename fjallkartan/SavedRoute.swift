import CoreLocation
import Foundation

struct SavedRoute: Identifiable, Codable, Hashable {
    static let currentSchemaVersion = 1

    let id: UUID
    let createdAt: Date
    let meters: Double
    let coordinates: [Coord]
    let strokeSizes: [Int] // To support undo
    let schemaVersion: Int

    init(id: UUID = UUID(),
         createdAt: Date = Date(),
         meters: Double,
         coordinates: [Coord],
         strokeSizes: [Int],
         schemaVersion: Int = SavedRoute.currentSchemaVersion) {
        self.id = id
        self.createdAt = createdAt
        self.meters = meters
        self.coordinates = coordinates
        self.strokeSizes = strokeSizes
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
}
