import Foundation
import MapKit

final class SlopeTileOverlay: MKTileOverlay {
    private static let fetcher = TileFetcher.mapTiles

    let server: TileServer

    static func norway() -> SlopeTileOverlay {
        SlopeTileOverlay(server: .norwaySlope)
    }

    static func sweden() -> SlopeTileOverlay {
        SlopeTileOverlay(server: .swedenSlope)
    }

    var sourceMaximumZ: Int { server.sourceMaximumZ }

    init(server: TileServer) {
        self.server = server
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        minimumZ = 5
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        server.url(z: Int(path.z), x: Int(path.x), y: Int(path.y))
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let z = Int(path.z)
        guard z > sourceMaximumZ else {
            fetch(path: path, result: result)
            return
        }

        let levels = z - sourceMaximumZ
        var ancestor = path
        ancestor.z = sourceMaximumZ
        ancestor.x = path.x >> levels
        ancestor.y = path.y >> levels

        fetch(path: ancestor) { data, error in
            guard let data else {
                result(nil, error)
                return
            }
            let scaled = TileUpscaler.upscaledTile(
                ancestor: (z: self.sourceMaximumZ,
                           x: Int(ancestor.x),
                           y: Int(ancestor.y),
                           data: data),
                targetZ: z, targetX: Int(path.x), targetY: Int(path.y),
                interpolation: .none
            )
            result(scaled, nil)
        }
    }

    /// Both tilesets are sparse, so a no-data response yields `(nil, nil)` — an
    /// empty tile MapKit keeps. Transport failures and 5xx are surfaced as
    /// errors instead, so MapKit re-requests them later.
    private func fetch(path: MKTileOverlayPath,
                       result: @escaping (Data?, Error?) -> Void) {
        Self.fetcher.fetchTile(server: server, z: Int(path.z), x: Int(path.x), y: Int(path.y)) { outcome in
            switch outcome {
            case .success(let data): result(data, nil)
            case .noData: result(nil, nil)
            case .failure(let error): result(nil, error)
            }
        }
    }
}
