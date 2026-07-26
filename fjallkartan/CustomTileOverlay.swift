import MapKit

final class CustomTileOverlay: MKTileOverlay {
    private let session = URLSession.shared

    init() {
        super.init(urlTemplate: nil)
//        canReplaceMapContent = false
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
        session.dataTask(with: tileURL(server, path)) { data, _, error in
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
