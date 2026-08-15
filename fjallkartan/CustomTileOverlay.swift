import MapKit
import OSLog
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
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "fjallkartan", category: "CustomTileOverlay")

    private static let sharedCache = URLCache(
        memoryCapacity: 0,
        diskCapacity: 500 * 1024 * 1024 // 500 MB
    )
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = sharedCache
        config.requestCachePolicy = .reloadIgnoringLocalCacheData // cache retrieval done manually, to put custom TTL
        config.httpMaximumConnectionsPerHost = 12
        return URLSession(configuration: config)
    }()

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

        let url = tileURL(path)
        let request = URLRequest(url: url)

        if let cached = Self.sharedCache.cachedResponse(for: request) {
            completion(cached.data)
            return
        }

        fetchWithRetry(url: url, request: request, attempt: 1, delay: 1.0) { [store] data in
            guard let data else {
                // No network tile available after retries. Above the
                // downloaded z7-z14 cap, fall back to a softened upscale of
                // the nearest stored ancestor rather than leaving the tile blank.
                if let store, z > TilePyramid.maxZoom,
                   let ancestor = store.nearestAncestorTile(server: code, z: z, x: x, y: y) {
                    completion(Self.upscaledTile(ancestor: ancestor, targetZ: z, targetX: x, targetY: y))
                } else {
                    completion(nil)
                }
                return
            }
            completion(data)
        }
    }

    /// Fetches a tile with retry + exponential backoff, mirroring
    /// `OfflineRegionDownloader.fetchTile`: `429`/`503` honor `Retry-After`,
    /// other network errors back off and retry, up to 3 attempts total.
    /// A genuine 404/no-data response is not retried.
    private func fetchWithRetry(url: URL, request: URLRequest, attempt: Int, delay: Double,
                                completion: @escaping (Data?) -> Void) {
        Self.sharedSession.dataTask(with: request) { data, response, error in
            if let data, error == nil,
               let r = response as? HTTPURLResponse,
               (200...299).contains(r.statusCode),
               r.mimeType?.hasPrefix("image/") ?? false {
                if let cacheResponse = HTTPURLResponse(url: url, statusCode: 200,
                                                       httpVersion: nil,
                                                       headerFields: ["Cache-Control": "max-age=31536000"]) {
                    Self.sharedCache.storeCachedResponse(CachedURLResponse(response: cacheResponse, data: data), for: request)
                }
                completion(data)
                return
            }
            if let r = response as? HTTPURLResponse, !(200...299).contains(r.statusCode) {
                Self.log.error("HTTP \(r.statusCode) for \(url.absoluteString, privacy: .public), attempt \(attempt)")
            } else if let error {
                Self.log.error("request failed for \(url.absoluteString, privacy: .public), attempt \(attempt): \(error.localizedDescription, privacy: .public)")
            }

            guard attempt < 3 else {
                Self.log.error("giving up after \(attempt) attempts for \(url.absoluteString, privacy: .public)")
                completion(nil)
                return
            }

            if let error = error as? URLError, Self.isConnectivityError(error) {
                // There is no connection to wait for
                completion(nil)
                return
            }

            if let r = response as? HTTPURLResponse, !(r.statusCode == 429 || r.statusCode == 503 || r.statusCode >= 500) {
                // A genuine client error (e.g. 404 no-data tile); not worth retrying.
                completion(nil)
                return
            }

            let retryAfter = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? delay
            DispatchQueue.global().asyncAfter(deadline: .now() + retryAfter) {
                self.fetchWithRetry(url: url, request: request, attempt: attempt + 1, delay: delay * 2, completion: completion)
            }
        }.resume()
    }

    private static func isConnectivityError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive:
            return true
        default:
            return false
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

    /// Crops the `1/4^n` sub-rectangle of `ancestor` that corresponds to the
    /// requested tile and scales it up to 256×256, so zooming past the
    /// downloaded z14 cap offline shows a softening map instead of a blank square. 
    private static func upscaledTile(ancestor: (z: Int, x: Int, y: Int, data: Data),
                                     targetZ: Int, targetX: Int, targetY: Int) -> Data? {
        let levels = targetZ - ancestor.z
        guard levels > 0, let cg = UIImage(data: ancestor.data)?.cgImage else { return ancestor.data }

        let n = 1 << levels
        let w = cg.width, h = cg.height
        guard w >= n, h >= n else { return ancestor.data }
        let cropW = w / n
        let cropH = h / n
        let subX = targetX - ancestor.x * n
        let subY = targetY - ancestor.y * n
        let cropRect = CGRect(x: subX * cropW, y: subY * cropH, width: cropW, height: cropH)
        guard let cropped = cg.cropping(to: cropRect) else { return nil }

        let outSize = 256
        guard let ctx = CGContext(data: nil, width: outSize, height: outSize,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outSize, height: outSize))
        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out).pngData()
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
