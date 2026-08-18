import CoreLocation
import Foundation

/// The handful of well known Nordic trails bundled with the app.
struct FeaturedRoute: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let country: String
    let route: SavedRoute
}

enum FeaturedRoutes {
    static let all: [FeaturedRoute] = load()

    static func load(from url: URL? = Bundle.main.url(forResource: "featured-routes",
                                                      withExtension: "json")) -> [FeaturedRoute] {
        guard let url, let data = try? Data(contentsOf: url) else {
            assertionFailure("featured-routes.json missing from the app bundle")
            return []
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            return file.routes.map(\.featured)
        } catch {
            assertionFailure("featured-routes.json could not be decoded: \(error)")
            return []
        }
    }

    // MARK: - Decoding

    private struct File: Decodable {
        let schemaVersion: Int
        let routes: [Entry]
    }

    private struct Entry: Decodable {
        let id: String
        let name: String
        let subtitle: String
        let country: String
        let meters: Double
        let ascent: Double
        let descent: Double
        /// `[[latitude, longitude], ...]`, which keeps the bundled file about a
        /// third smaller than the equivalent objects.
        let coordinates: [[Double]]
        let elevations: [Double?]

        var featured: FeaturedRoute {
            let coords = coordinates.compactMap { pair -> Coord? in
                guard pair.count == 2 else { return nil }
                return Coord(.init(latitude: pair[0], longitude: pair[1]))
            }
            let route = SavedRoute(
                id: Self.identifier(for: id),
                createdAt: Date(timeIntervalSince1970: 0),
                meters: meters,
                coordinates: coords,
                strokeSizes: [coords.count],
                ascent: ascent,
                descent: descent,
                elevations: elevations,
                name: name
            )
            return FeaturedRoute(id: id, name: name, subtitle: subtitle,
                                 country: country, route: route)
        }

        /// A stable UUID derived from the catalogue id, so saving a copy of the
        /// same featured route twice cannot collide with a different one.
        private static func identifier(for id: String) -> UUID {
            var bytes = Array(Data(id.utf8).prefix(16))
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 16 - bytes.count))
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                               bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11],
                               bytes[12], bytes[13], bytes[14], bytes[15]))
        }
    }
}
