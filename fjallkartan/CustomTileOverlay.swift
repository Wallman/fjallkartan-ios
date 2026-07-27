import MapKit
import UIKit

enum TileServer {
    case kartverket, lantmateriet
}

final class CustomTileOverlay: MKTileOverlay {
    private static let sharedCache = URLCache(
        memoryCapacity: 64 * 1024 * 1024, // 64 MB
        diskCapacity: 500 * 1024 * 1024 // 500 MB
    )
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = sharedCache
        config.requestCachePolicy = .reloadIgnoringLocalCacheData // cache retrieval done manually, to put custom TTL
        return URLSession(configuration: config)
    }()

    private let server: TileServer

    init(server: TileServer) {
        self.server = server
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        maximumZ = 18
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

    private func fetch(path: MKTileOverlayPath,
                       completion: @escaping (Data?) -> Void) {
        let url = tileURL(path)
        let request = URLRequest(url: url)

        if let cached = Self.sharedCache.cachedResponse(for: request) {
            completion(cached.data)
            return
        }

        Self.sharedSession.dataTask(with: request) { data, response, error in
            guard let data, error == nil,
                  let r = response as? HTTPURLResponse,
                  (200...299).contains(r.statusCode),
                  r.mimeType?.hasPrefix("image/") ?? false else {
                // Don't cache error responses; return nil so MapKit retries later.
                completion(nil)
                return
            }
            if let cacheResponse = HTTPURLResponse(url: url, statusCode: 200,
                                                   httpVersion: nil,
                                                   headerFields: ["Cache-Control": "max-age=31536000"]) {
                Self.sharedCache.storeCachedResponse(CachedURLResponse(response: cacheResponse, data: data), for: request)
            }
            completion(data)
        }.resume()
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
        switch server {
        case .kartverket:
            return URL(string:
                "https://cache.kartverket.no/v1/wmts/1.0.0/topo/default/webmercator/\(path.z)/\(path.y)/\(path.x).png"
            )!
        case .lantmateriet:
            var c = URLComponents(string: "https://minkarta.lantmateriet.se/map/topowebbcache")!
            c.queryItems = [
                URLQueryItem(name: "layer",         value: "topowebb"),
                URLQueryItem(name: "style",         value: "default"),
                URLQueryItem(name: "tilematrixset", value: "3857"),
                URLQueryItem(name: "Service",       value: "WMTS"),
                URLQueryItem(name: "Request",       value: "GetTile"),
                URLQueryItem(name: "Version",       value: "1.0.0"),
                URLQueryItem(name: "Format",        value: "image/png"),
                URLQueryItem(name: "TileMatrix",    value: "\(path.z)"),
                URLQueryItem(name: "TileRow",       value: "\(path.y)"),
                URLQueryItem(name: "TileCol",       value: "\(path.x)"),
            ]
            return c.url!
        }
    }
}
