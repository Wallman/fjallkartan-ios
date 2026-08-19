import MapKit
import UIKit

final class CustomTileOverlay: MKTileOverlay {
    private let server: TileServer
    private let fetcher: TileFetcher

    init(server: TileServer, fetcher: TileFetcher = .mapTiles) {
        self.server = server
        self.fetcher = fetcher
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let z = Int(path.z), x = Int(path.x), y = Int(path.y)
        guard z > server.sourceMaximumZ else {
            fetch(z: z, x: x, y: y, result: result)
            return
        }

        let levels = z - server.sourceMaximumZ
        let ancestor = (z: server.sourceMaximumZ, x: x >> levels, y: y >> levels)

        fetch(z: ancestor.z, x: ancestor.x, y: ancestor.y) { [server] data, error in
            guard let data else {
                result(nil, error)
                return
            }
            let scaled = TileUpscaler.upscaledTile(
                ancestor: (z: ancestor.z, x: ancestor.x, y: ancestor.y, data: data),
                targetZ: z, targetX: x, targetY: y,
                interpolation: server.upscaleInterpolation
            )
            result(scaled, nil)
        }
    }

    private func fetch(z: Int, x: Int, y: Int,
                       result: @escaping (Data?, Error?) -> Void) {
        fetcher.fetchTile(server: server, z: z, x: x, y: y) { [server] outcome in
            switch outcome {
            case .success(let data):
                result(server == .kartverket ? Self.kartverketNoDataToTransparentPNG(data) : data, nil)
            case .noData:
                result(nil, nil)
            case .failure(let error):
                result(nil, error)
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
        var rewroteAnyPixel = false
        var i = 0
        while i < buf.count {
            if buf[i] > 250, buf[i + 1] > 250, buf[i + 2] >= 222, buf[i + 2] <= 240 {
                buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; buf[i + 3] = 0
                rewroteAnyPixel = true
            }
            i += 4
        }
        guard rewroteAnyPixel else { return data }
        guard let out = ctx.makeImage() else { return data }
        return UIImage(cgImage: out).pngData() ?? data
    }
}
