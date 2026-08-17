import Foundation
import OSLog

enum TileFetchOutcome {
    case success(Data)
    case noData
    case failure(Error)
}

nonisolated final class TileFetcher: @unchecked Sendable {
    struct Configuration {
        var maximumAttempts = 3
        var initialRetryDelay: TimeInterval = 0.2
        var cacheTTL: TimeInterval = 182 * 24 * 60 * 60 // 6 months
    }

    static let sharedTileCache = URLCache(
        memoryCapacity: 0,
        diskCapacity: 500 * 1024 * 1024 // 500 MB
    )

    static let mapTiles: TileFetcher = {
        let config = URLSessionConfiguration.default
        config.urlCache = sharedTileCache
        config.requestCachePolicy = .reloadIgnoringLocalCacheData // cache retrieval done manually, to put custom TTL
        config.httpMaximumConnectionsPerHost = 12
        return TileFetcher(session: URLSession(configuration: config), cache: sharedTileCache, offlineStore: OfflineTileStore.shared)
    }()

    private let session: URLSession
    private let cache: URLCache?
    private let offlineStore: OfflineTileStore?
    private let storesResponses: Bool
    private let configuration: Configuration

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "fjallkartan", category: "TileFetcher")

    init(session: URLSession,
         cache: URLCache? = nil,
         offlineStore: OfflineTileStore? = nil,
         storesResponses: Bool = true,
         configuration: Configuration = Configuration()) {
        self.session = session
        self.cache = cache
        self.offlineStore = offlineStore
        self.storesResponses = storesResponses
        self.configuration = configuration
    }

    /// The full lookup for one tile of one layer: offline store → `URLCache` →
    /// network, falling back above the downloaded zoom cap to an upscale of the
    /// nearest stored ancestor rather than leaving the tile blank.
    func fetchTile(server: TileServer, z: Int, x: Int, y: Int,
                   completion: @escaping (TileFetchOutcome) -> Void) {
        let code = server.storeCode

        if let data = offlineStore?.tileData(server: code, z: z, x: x, y: y) {
            completion(.success(data))
            return
        }

        fetch(url: server.url(z: z, x: x, y: y)) { [offlineStore] outcome in
            if case .success = outcome {
                completion(outcome)
                return
            }
            // Both `noData` and `failure` land here: either way there is no
            // fresh tile, so an ancestor is the best available picture.
            if let offlineStore, z > server.offlineMaximumZ,
               let ancestor = offlineStore.nearestAncestorTile(server: code, z: z, x: x, y: y),
               let upscaled = TileUpscaler.upscaledTile(ancestor: ancestor, targetZ: z, targetX: x, targetY: y,
                                                        interpolation: server.upscaleInterpolation) {
                completion(.success(upscaled))
                return
            }
            completion(outcome)
        }
    }

    func fetch(url: URL, completion: @escaping (TileFetchOutcome) -> Void) {
        if let data = cache?.cachedResponse(for: URLRequest(url: url))?.data {
            completion(.success(data))
            return
        }
        attempt(url: url, attempt: 1, delay: configuration.initialRetryDelay, completion: completion)
    }

    private func attempt(url: URL, attempt: Int, delay: TimeInterval,
                         completion: @escaping (TileFetchOutcome) -> Void) {
        let request = URLRequest(url: url)
        session.dataTask(with: request) { [self] data, response, error in
            let http = response as? HTTPURLResponse

            if let data, error == nil, let http, (200...299).contains(http.statusCode) {
                guard http.mimeType?.hasPrefix("image/") ?? false else {
                    // Some tile servers answer a failure with a 200 carrying an
                    // XML/HTML error page; storing that would poison the cache
                    // for a year, or the offline store until the region is deleted.
                    completion(.noData)
                    return
                }
                store(data, for: request, url: url)
                completion(.success(data))
                return
            }

            if let http, !(200...299).contains(http.statusCode) {
                let isSparseTileset = url.path.contains("/slope/v1") || url.path.contains("/elevation/v1")
                if !(http.statusCode == 404 && isSparseTileset) {
                    Self.log.error("HTTP \(http.statusCode) for \(url.absoluteString, privacy: .public), attempt \(attempt)")
                }
            } else if let error {
                Self.log.error("request failed for \(url.absoluteString, privacy: .public), attempt \(attempt): \(error.localizedDescription, privacy: .public)")
            }

            // A client error other than throttling is a genuine no-data tile.
            if let http, !Self.isRetryable(status: http.statusCode) {
                completion(.noData)
                return
            }
            // There is no connection to wait for.
            if let urlError = error as? URLError, Self.isConnectivityError(urlError) {
                completion(.failure(urlError))
                return
            }

            guard attempt < configuration.maximumAttempts else {
                Self.log.error("giving up after \(attempt) attempts for \(url.absoluteString, privacy: .public)")
                completion(.failure(error ?? URLError(.badServerResponse)))
                return
            }

            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? delay
            DispatchQueue.global().asyncAfter(deadline: .now() + retryAfter) {
                self.attempt(url: url, attempt: attempt + 1, delay: delay * 2, completion: completion)
            }
        }.resume()
    }

    private func store(_ data: Data, for request: URLRequest, url: URL) {
        guard storesResponses, let cache,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Cache-Control": "max-age=\(Int(configuration.cacheTTL))"])
        else { return }
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
    }

    private static func isRetryable(status: Int) -> Bool {
        status == 429 || status >= 500
    }

    private static func isConnectivityError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive:
            return true
        default:
            return false
        }
    }
}
