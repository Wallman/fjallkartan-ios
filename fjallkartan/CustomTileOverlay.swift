import MapKit
import UIKit

enum TileServer {
    case kartverket, lantmateriet

    /// Encoding used as the `server` column in `OfflineTileStore`.
    var storeCode: Int {
        switch self {
        case .kartverket: return 0
        case .lantmateriet: return 1
        }
    }
}

final class CustomTileOverlay: MKTileOverlay {
    private static let fetcher = TileFetcher.mapTiles

    /// Shared across both server overlays so downloaded regions are visible
    /// to each. `try?` because a store failure (e.g. disk full) should degrade
    /// to online-only behavior, not crash the map.
    static let defaultStore = try? OfflineTileStore()

    private let server: TileServer
    private let store: OfflineTileStore?

    init(server: TileServer, store: OfflineTileStore? = CustomTileOverlay.defaultStore) {
        self.server = server
        self.store = store
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        switch server {
        case .lantmateriet:
            fetch(path: path) { result($0, nil) }
        case .kartverket:
            fetch(path: path) { data in
                result(Self.kartverketNoDataToTransparentPNG(data), nil)
            }
        }
    }

    /// Lookup order is offline store → `URLCache` → network.
    private func fetch(path: MKTileOverlayPath,
                       completion: @escaping (Data?) -> Void) {
        let z = Int(path.z), x = Int(path.x), y = Int(path.y)
        let code = server.storeCode
//        print("z \(z)")

        if let store, let data = store.tileData(server: code, z: z, x: x, y: y) {
            completion(data)
            return
        }

        Self.fetcher.fetch(url: tileURL(path)) { [store] outcome in
            if case .success(let data) = outcome {
                completion(data)
                return
            }
            // No network tile available. Above the downloaded z7-z14 cap, fall
            // back to a softened upscale of the nearest stored ancestor rather
            // than leaving the tile blank. Both `noData` and `failure` end up
            // here: for the base map either way means nothing to draw.
            if let store, z > TilePyramid.maxZoom,
               let ancestor = store.nearestAncestorTile(server: code, z: z, x: x, y: y) {
                completion(TileUpscaler.upscaledTile(ancestor: ancestor, targetZ: z, targetX: x, targetY: y))
            } else {
                completion(nil)
            }
        }
    }

    // Kartverket's no-data fill is transparent at low zoom but an opaque cream
    // (255,255,230) from ~z15. Converts it to transparent.
    private static func kartverketNoDataToTransparentPNG(_ data: Data?) -> Data? {
        guard let data, let cg = UIImage(data: data)?.cgImage else { return data }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return data }
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: h * bytesPerRow)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return data
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var i = 0
        while i < buf.count {
            if buf[i] > 250, buf[i + 1] > 250, buf[i + 2] >= 222, buf[i + 2] <= 240 {
                buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; buf[i + 3] = 0
            }
            i += 4
        }
        guard let out = ctx.makeImage() else { return data }
        return UIImage(cgImage: out).pngData() ?? data
    }

    private func tileURL(_ path: MKTileOverlayPath) -> URL {
        Self.tileURL(server: server, z: Int(path.z), x: Int(path.x), y: Int(path.y))
    }

    /// Shared with `OfflineRegionDownloader`, which fetches raw tiles
    /// directly (i.e. without going through an `MKTileOverlay` instance).
    static func tileURL(server: TileServer, z: Int, x: Int, y: Int) -> URL {
        RemoteSettings.shared.tileURL(server: server, z: z, x: x, y: y)
    }
}
