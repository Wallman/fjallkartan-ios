import Foundation
import MapKit
import Turf

struct TileID: Hashable {
    let z, x, y: Int
}

enum TileServer {
    case kartverket, lantmateriet
    
    func covers(coverage: TileCoverage) -> Bool {
        switch self {
        case .kartverket:
            return coverage.norway
        case .lantmateriet:
            return coverage.sweden
        }
    }
}

struct TileCoverage {
    let norway: Bool
    let sweden: Bool
}

private func loadMultiPolygon(bundleResource: String) throws -> MultiPolygon {
    let url = Bundle.main.url(forResource: bundleResource, withExtension: "geojson")!
    let data = try Data(contentsOf: url)
    let feature = try JSONDecoder().decode(Feature.self, from: data)
    guard case .multiPolygon(let mp) = feature.geometry else {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(bundleResource): expected MultiPolygon geometry"))
    }
    return mp
}

final class TileCoverageResolver {
    static let shared = TileCoverageResolver()

    private let norway: MultiPolygon
    private let sweden: MultiPolygon
    private var cache: [TileID: TileCoverage] = [:]

    init() {
        norway = try! loadMultiPolygon(bundleResource: "norway_coverage")
        sweden = try! loadMultiPolygon(bundleResource: "sweden_coverage")
    }

    func coverage(for path: MKTileOverlayPath) -> TileCoverage {
        let tileID = TileID(z: path.z, x: path.x, y: path.y)
        if let hit = cache[tileID] { return hit }
        let result = compute(path)
        cache[tileID] = result
        return result
    }

    private func compute(_ path: MKTileOverlayPath) -> TileCoverage {
        let ring = tileRing(z: path.z, x: path.x, y: path.y)
        return TileCoverage(
            norway: intersects(tileRing: ring, coverage: norway),
            sweden: intersects(tileRing: ring, coverage: sweden)
        )
    }

    //  Test geometric overlap:
    //  1. any tile corner lies inside the coverage,
    //  2. any coverage vertex lies inside the tile, or
    //  3. a tile edge crosses a coverage edge.
    private func intersects(tileRing: [LocationCoordinate2D], coverage: MultiPolygon) -> Bool {
        if tileRing.contains(where: { coverage.contains($0) }) { return true }

        let tilePolygon = Polygon([tileRing])
        let tileLine = LineString(tileRing)
        for polygon in coverage.polygons {
            for coverageRing in polygon.coordinates {
                if coverageRing.contains(where: { tilePolygon.contains($0) }) { return true }
                if !tileLine.intersections(with: LineString(coverageRing)).isEmpty { return true }
            }
        }
        return false
    }

    // Closed ring of the tile's four corners (NW, NE, SE, SW, NW).
    private func tileRing(z: Int, x: Int, y: Int) -> [LocationCoordinate2D] {
        let n = Double(1 << z)
        func coord(dx: Double, dy: Double) -> LocationCoordinate2D {
            let lon = dx / n * 360.0 - 180.0
            let lat = atan(sinh(.pi * (1.0 - 2.0 * dy / n))) * 180.0 / .pi
            return LocationCoordinate2D(latitude: lat, longitude: lon)
        }
        let fx = Double(x), fy = Double(y)
        return [
            coord(dx: fx,     dy: fy),      // NW
            coord(dx: fx + 1, dy: fy),      // NE
            coord(dx: fx + 1, dy: fy + 1),  // SE
            coord(dx: fx,     dy: fy + 1),  // SW
            coord(dx: fx,     dy: fy),      // close
        ]
    }
}

