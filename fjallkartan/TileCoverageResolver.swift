import Foundation
import MapKit
import Turf

struct TileID: Hashable {
    let x, y, z: Int
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

    private init() {
        norway = try! loadMultiPolygon(bundleResource: "norway_coverage")
        sweden = try! loadMultiPolygon(bundleResource: "sweden_coverage")
    }

    func coverage(for path: MKTileOverlayPath) -> TileCoverage {
        let tileID = TileID(x: path.x, y: path.y, z: path.z)
        if let hit = cache[tileID] { return hit }
        let result = compute(path)
        cache[tileID] = result
        return result
    }

    private func compute(_ path: MKTileOverlayPath) -> TileCoverage {
        let points = tilePoints(x: path.x, y: path.y, z: path.z)
        return TileCoverage(
            norway: points.contains { norway.contains($0) },
            sweden: points.contains { sweden.contains($0) }
        )
    }

    // Sample all corners and center
    private func tilePoints(x: Int, y: Int, z: Int) -> [LocationCoordinate2D] {
        let n = Double(1 << z)
        func coord(dx: Double, dy: Double) -> LocationCoordinate2D {
            let lon = dx / n * 360.0 - 180.0
            let lat = atan(sinh(.pi * (1.0 - 2.0 * dy / n))) * 180.0 / .pi
            return LocationCoordinate2D(latitude: lat, longitude: lon)
        }
        let fx = Double(x), fy = Double(y)
        return [
            coord(dx: fx,       dy: fy),
            coord(dx: fx + 1,   dy: fy),
            coord(dx: fx,       dy: fy + 1),
            coord(dx: fx + 1,   dy: fy + 1),
            coord(dx: fx + 0.5, dy: fy + 0.5),
        ]
    }
}

