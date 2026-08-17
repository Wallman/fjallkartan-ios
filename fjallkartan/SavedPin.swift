import CoreLocation
import Foundation

/// A user defined pin at a fixed coordinate.
struct SavedPin: Identifiable, Codable, Hashable {
    static let currentSchemaVersion = 1

    let id: UUID
    let createdAt: Date
    let coordinate: Coord
    var name: String?
    var notes: String?
    let schemaVersion: Int

    init(id: UUID = UUID(),
         createdAt: Date = Date(),
         coordinate: Coord,
         name: String? = nil,
         notes: String? = nil,
         schemaVersion: Int = SavedPin.currentSchemaVersion) {
        self.id = id
        self.createdAt = createdAt
        self.coordinate = coordinate
        self.name = name
        self.notes = notes
        self.schemaVersion = schemaVersion
    }

    var displayName: String {
        name ?? ""
    }
}
