import Foundation

nonisolated enum NorwayBoundary {
    /// Closed ring, (longitude, latitude) pairs.
    private static let vertices: [(lon: Double, lat: Double)] = load()

    private static func load(from url: URL? = Bundle.main.url(forResource: "norway-boundary",
                                                              withExtension: "geojson")) -> [(lon: Double, lat: Double)] {
        guard let url, let data = try? Data(contentsOf: url) else {
            assertionFailure("norway-boundary.geojson missing from the app bundle")
            return []
        }
        do {
            let feature = try JSONDecoder().decode(Feature.self, from: data)
            guard let ring = feature.geometry.coordinates.first else { return [] }
            return ring.map { (lon: $0[0], lat: $0[1]) }
        } catch {
            assertionFailure("norway-boundary.geojson could not be decoded: \(error)")
            return []
        }
    }

    private struct Feature: Decodable {
        let geometry: Geometry
    }

    private struct Geometry: Decodable {
        /// One ring, `[[longitude, latitude], ...]`.
        let coordinates: [[[Double]]]
    }

    static func tileIsOutside(z: Int, x: Int, y: Int) -> Bool {
        guard z >= 0, x >= 0, y >= 0 else { return true }
        guard !vertices.isEmpty else { return false }
        let n = Double(1 << z)
        let west = Double(x) / n * 360 - 180
        let east = Double(x + 1) / n * 360 - 180
        let north = latitude(forTileY: Double(y), n: n)
        let south = latitude(forTileY: Double(y + 1), n: n)

        let corners = [(west, north), (east, north), (east, south), (west, south)]
        if corners.contains(where: { contains(lon: $0.0, lat: $0.1) }) {
            return false
        }
        if vertices.contains(where: { $0.lon >= west && $0.lon <= east && $0.lat >= south && $0.lat <= north }) {
            return false
        }
        return !edgeCrossesTile(west: west, east: east, south: south, north: north)
    }

    private static func latitude(forTileY y: Double, n: Double) -> Double {
        let yFraction = y / n
        let latRad = atan(sinh(.pi * (1 - 2 * yFraction)))
        return latRad * 180 / .pi
    }

    /// Standard ray-casting point-in-polygon test.
    private static func contains(lon: Double, lat: Double) -> Bool {
        var inside = false
        var j = vertices.count - 1
        for i in 0..<vertices.count {
            let vi = vertices[i], vj = vertices[j]
            if (vi.lat > lat) != (vj.lat > lat) {
                let x = (vj.lon - vi.lon) * (lat - vi.lat) / (vj.lat - vi.lat) + vi.lon
                if lon < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Catches the case where a polygon edge passes straight through the
    /// tile without either a tile corner or a polygon vertex landing inside
    /// the other shape.
    private static func edgeCrossesTile(west: Double, east: Double, south: Double, north: Double) -> Bool {
        let tileEdges: [((Double, Double), (Double, Double))] = [
            ((west, north), (east, north)),
            ((east, north), (east, south)),
            ((east, south), (west, south)),
            ((west, south), (west, north)),
        ]
        var j = vertices.count - 1
        for i in 0..<vertices.count {
            let a = (vertices[i].lon, vertices[i].lat)
            let b = (vertices[j].lon, vertices[j].lat)
            for (c, d) in tileEdges where segmentsIntersect(a, b, c, d) {
                return true
            }
            j = i
        }
        return false
    }

    private static func segmentsIntersect(_ p1: (Double, Double), _ p2: (Double, Double),
                                           _ p3: (Double, Double), _ p4: (Double, Double)) -> Bool {
        func cross(_ o: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
            (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
        }
        let d1 = cross(p3, p4, p1)
        let d2 = cross(p3, p4, p2)
        let d3 = cross(p1, p2, p3)
        let d4 = cross(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
               ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }
}
