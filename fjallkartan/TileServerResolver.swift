import Foundation
import MapKit
import Turf

struct TileID: Hashable {
    let x, y, z: Int
}

enum TileServer {
    case kartverket, lantmateriet
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

final class TileServerResolver {
    static let shared = TileServerResolver()

    private let norway: MultiPolygon
    private let sweden: MultiPolygon
    private var cache: [TileID: TileServer?] = [:]

    private init() {
        norway = try! loadMultiPolygon(bundleResource: "norway_coverage")
        sweden = try! loadMultiPolygon(bundleResource: "sweden_coverage")
    }

    func getServer(for path: MKTileOverlayPath) -> TileServer? {
        let tileID = TileID(x: path.x, y: path.y, z: path.z)
        if let hit = cache[tileID] { return hit }
        let result = compute(path)
        cache[tileID] = result
        return result
    }

    private func compute(_ path: MKTileOverlayPath) -> TileServer? {
        let centre = tileCentre(x: path.x, y: path.y, z: path.z)
        if norway.contains(centre) { return .kartverket }
        if sweden.contains(centre) { return .lantmateriet }
        return nil
    }

    private func tileCentre(x: Int, y: Int, z: Int) -> LocationCoordinate2D {
        let n = Double(1 << z)
        let dx = Double(x), dy = Double(y)
        let lon = (dx + 0.5) / n * 360.0 - 180.0
        let lat = atan(sinh(.pi * (1.0 - 2.0 * (dy + 0.5) / n))) * 180.0 / .pi
        return LocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

