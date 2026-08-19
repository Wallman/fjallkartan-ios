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
        var connectivityAttempts = 2
        var connectivityRetryDelay: TimeInterval = 1
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
        return TileFetcher(session: URLSession(configuration: config), cache: sharedTileCache, offlineStore: OfflineTileStore.shared, metrics: .shared)
    }()

    private let session: URLSession
    private let cache: URLCache?
    private let offlineStore: OfflineTileStore?
    private let storesResponses: Bool
    private let configuration: Configuration
    private let metrics: TileMetrics?

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "fjallkartan", category: "TileFetcher")

    /// The terminal state of one lookup. Kept private: it exists so the
    /// fetcher can attribute its own work.
    private struct Resolution {
        var source: TileMetrics.Source
        var attempts: Int
    }

    /// - Parameter metrics: `nil` disables recording entirely
    init(session: URLSession,
         cache: URLCache? = nil,
         offlineStore: OfflineTileStore? = nil,
         storesResponses: Bool = true,
         configuration: Configuration = Configuration(),
         metrics: TileMetrics? = nil) {
        self.session = session
        self.cache = cache
        self.offlineStore = offlineStore
        self.storesResponses = storesResponses
        self.configuration = configuration
        self.metrics = metrics
    }

    /// The full lookup for one tile of one layer: offline store → `URLCache` →
    /// network, falling back above the downloaded zoom cap to an upscale of the
    /// nearest stored ancestor rather than leaving the tile blank.
    func fetchTile(server: TileServer, z: Int, x: Int, y: Int,
                   completion: @escaping (TileFetchOutcome) -> Void) {
        let code = server.storeCode
        let started = DispatchTime.now()

        if let data = offlineStore?.tileData(server: code, z: z, x: x, y: y) {
            record(.offlineStore, server: server, z: z, attempts: 0, started: started)
            completion(.success(data))
            return
        }

        resolve(url: server.url(z: z, x: x, y: y)) { [self] outcome, resolution in
            if case .success = outcome {
                record(resolution.source, server: server, z: z, attempts: resolution.attempts, started: started)
                completion(outcome)
                return
            }
            // Both `noData` and `failure` land here: either way there is no
            // fresh tile, so an ancestor is the best available picture.
            if let offlineStore, z > server.offlineMaximumZ,
               let ancestor = offlineStore.nearestAncestorTile(server: code, z: z, x: x, y: y),
               let upscaled = TileUpscaler.upscaledTile(ancestor: ancestor, targetZ: z, targetX: x, targetY: y,
                                                        interpolation: server.upscaleInterpolation) {
                record(.upscaledAncestor, server: server, z: z, attempts: resolution.attempts, started: started)
                completion(.success(upscaled))
                return
            }
            record(resolution.source, server: server, z: z, attempts: resolution.attempts, started: started)
            completion(outcome)
        }
    }

    func fetch(url: URL, completion: @escaping (TileFetchOutcome) -> Void) {
        resolve(url: url) { outcome, _ in completion(outcome) }
    }

    private func resolve(url: URL,
                         completion: @escaping (TileFetchOutcome, Resolution) -> Void) {
        if let data = cache?.cachedResponse(for: URLRequest(url: url))?.data {
            completion(.success(data), Resolution(source: .urlCache, attempts: 0))
            return
        }
        attempt(url: url, attempt: 1,
                delay: configuration.initialRetryDelay, completion: completion)
    }

    private func record(_ source: TileMetrics.Source, server: TileServer, z: Int,
                        attempts: Int, started: DispatchTime) {
        guard let metrics else { return }
        let nanoseconds = DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds
        metrics.record(server: server, z: z, source: source,
                       attempts: attempts, seconds: Double(nanoseconds) / 1_000_000_000)
    }

    private func attempt(url: URL, attempt: Int, delay: TimeInterval,
                         completion: @escaping (TileFetchOutcome, Resolution) -> Void) {
        let request = URLRequest(url: url)
        session.dataTask(with: request) { [self] data, response, error in
            let http = response as? HTTPURLResponse

            if let data, error == nil, let http, (200...299).contains(http.statusCode) {
                guard http.mimeType?.hasPrefix("image/") ?? false else {
                    Self.log.error("non-image \(http.statusCode) (\(http.mimeType ?? "no MIME type", privacy: .public)) for \(url.absoluteString, privacy: .public)")
                    completion(.noData, Resolution(source: .unexpectedNoData, attempts: attempt))
                    return
                }
                store(data, for: request, url: url)
                completion(.success(data), Resolution(source: .network, attempts: attempt))
                return
            }

            if let http, !(200...299).contains(http.statusCode) {
                if http.statusCode != 404 {
                    Self.log.error("HTTP \(http.statusCode) for \(url.absoluteString, privacy: .public), attempt \(attempt)")
                }
            } else if let error {
                Self.log.error("request failed for \(url.absoluteString, privacy: .public), attempt \(attempt): \(error.localizedDescription, privacy: .public)")
            } else if let http {
                Self.log.error("empty \(http.statusCode) body for \(url.absoluteString, privacy: .public), attempt \(attempt)")
            }

            // A client error other than throttling is a genuine no-data tile.
            if let http, !Self.isRetryable(status: http.statusCode) {
                completion(.noData, Resolution(source: http.statusCode == 404 ? .expectedNoData : .unexpectedNoData,
                                               attempts: attempt))
                return
            }
            // Claims of "no connection" get their own small budget rather than
            // the full one: usually there really is nothing to wait for, but a
            // cold start can report this before the network stack is up.
            if let urlError = error as? URLError, Self.isConnectivityError(urlError) {
                guard attempt < configuration.connectivityAttempts else {
                    completion(.failure(urlError), Resolution(source: .failure, attempts: attempt))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + configuration.connectivityRetryDelay) {
                    self.attempt(url: url, attempt: attempt + 1,
                                 delay: delay, completion: completion)
                }
                return
            }

            guard attempt < configuration.maximumAttempts else {
                Self.log.error("giving up after \(attempt) attempts for \(url.absoluteString, privacy: .public)")
                completion(.failure(error ?? URLError(.badServerResponse)),
                           Resolution(source: .failure, attempts: attempt))
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
