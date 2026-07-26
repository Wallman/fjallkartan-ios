import MapKit

final class CustomTileOverlay: MKTileOverlay {
    private let tileCache: URLCache
    private let session: URLSession

    init() {
        tileCache = URLCache(
            memoryCapacity: 0,
            diskCapacity: 500 * 1024 * 1024 // 500 MB
        )
        let config = URLSessionConfiguration.default
        config.urlCache = tileCache
        config.requestCachePolicy = .reloadIgnoringLocalCacheData // cache retrieval done manually, to put custom TTL
        session = URLSession(configuration: config)

        super.init(urlTemplate: nil)
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        guard let server = TileServerResolver.shared.getServer(for: path) else {
            result(nil, nil)
            return
        }
        fetch(server, path: path, result: result)
    }

    private func fetch(_ server: TileServer,
                       path: MKTileOverlayPath,
                       result: @escaping (Data?, Error?) -> Void) {
        let url = tileURL(server, path)
        let request = URLRequest(url: url)

        if let cached = tileCache.cachedResponse(for: request) {
            result(cached.data, nil)
            return
        }

        session.dataTask(with: request) { [tileCache] data, response, error in
            if let data, let r = response as? HTTPURLResponse, error == nil,
               let cacheResponse = HTTPURLResponse(url: url, statusCode: r.statusCode,
                                                   httpVersion: nil,
                                                   headerFields: ["Cache-Control": "max-age=31536000"]) {
                tileCache.storeCachedResponse(CachedURLResponse(response: cacheResponse, data: data), for: request)
            }
            result(data, error)
        }.resume()
    }

    private func tileURL(_ server: TileServer, _ path: MKTileOverlayPath) -> URL {
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
