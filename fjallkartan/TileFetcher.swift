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
        diskCapacity: 50 * 1024 * 1024 // 50 MB
    )

    static let elevationTiles: TileFetcher = {
        let config = URLSessionConfiguration.default
        config.urlCache = sharedTileCache
        config.requestCachePolicy = .reloadIgnoringLocalCacheData // cache retrieval done manually, to put custom TTL
        config.httpMaximumConnectionsPerHost = 12
        return TileFetcher(session: URLSession(configuration: config), cache: sharedTileCache)
    }()

    private let session: URLSession
    private let cache: URLCache?
    private let configuration: Configuration

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "fjallkartan", category: "TileFetcher")

    init(session: URLSession,
         cache: URLCache? = nil,
         configuration: Configuration = Configuration()) {
        self.session = session
        self.cache = cache
        self.configuration = configuration
    }

    func fetchTile(server: TileServer, z: Int, x: Int, y: Int,
                   completion: @escaping (TileFetchOutcome) -> Void) {
        fetch(url: server.url(z: z, x: x, y: y), completion: completion)
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
                    Self.log.error("non-image \(http.statusCode) (\(http.mimeType ?? "no MIME type", privacy: .public)) for \(url.absoluteString, privacy: .public)")
                    completion(.noData)
                    return
                }
                store(data, for: request, url: url)
                completion(.success(data))
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
                completion(.noData)
                return
            }
            // Claims of "no connection" get their own small budget rather than
            // the full one: usually there really is nothing to wait for, but a
            // cold start can report this before the network stack is up.
            if let urlError = error as? URLError, Self.isConnectivityError(urlError) {
                guard attempt < configuration.connectivityAttempts else {
                    completion(.failure(urlError))
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
        guard let cache,
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

