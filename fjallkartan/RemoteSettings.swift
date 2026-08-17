import Foundation
import OSLog

nonisolated struct TileSettings: Codable, Equatable {
    var minAppVersion: String
    var lantmaterietUrl: String
    var kartverketUrl: String
    var norwaySlopeUrl: String
    var swedenSlopeUrl: String
    var elevationUrl: String

    var isUsable: Bool {
        Self.isWellFormedVersion(minAppVersion)
            && Self.isUsableTemplate(lantmaterietUrl)
            && Self.isUsableTemplate(kartverketUrl)
            && Self.isUsableTemplate(norwaySlopeUrl)
            && Self.isUsableTemplate(swedenSlopeUrl)
            && Self.isUsableTemplate(elevationUrl)
    }

    static func isWellFormedVersion(_ version: String) -> Bool {
        version.wholeMatch(of: #/[0-9]+\.[0-9]+(\.[0-9]+)?/#) != nil
    }

    private static func isUsableTemplate(_ template: String) -> Bool {
        guard template.contains("{z}"), template.contains("{x}"), template.contains("{y}") else { return false }
        return url(from: template, z: 0, x: 0, y: 0) != nil
    }

    static func url(from template: String, z: Int, x: Int, y: Int) -> URL? {
        let substituted = template
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)")
        guard let url = URL(string: substituted),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              !(url.host ?? "").isEmpty else { return nil }
        return url
    }
}

nonisolated final class RemoteSettings: @unchecked Sendable {
    static let shared = RemoteSettings()
    static let settingsURL = URL(string: "https://tiles.wallman.dev/settings.json")!
    static let refreshInterval: TimeInterval = 6 * 60 * 60 // 6h

    static let builtIn = TileSettings(
        minAppVersion: "1.0",
        lantmaterietUrl: "https://minkarta.lantmateriet.se/map/topowebbcache"
            + "?layer=topowebb&style=default&tilematrixset=3857&Service=WMTS&Request=GetTile"
            + "&Version=1.0.0&Format=image/png&TileMatrix={z}&TileRow={y}&TileCol={x}",
        kartverketUrl: "https://cache.kartverket.no/v1/wmts/1.0.0/topo/default/webmercator/{z}/{y}/{x}.png",
        norwaySlopeUrl: "https://gis3.nve.no/arcgis/rest/services/wmts/Bratthet_med_utlop_2024/MapServer/tile/{z}/{y}/{x}",
        swedenSlopeUrl: "https://tiles.wallman.dev/slope/v1/{z}/{y}/{x}.png",
        elevationUrl: "https://tiles.wallman.dev/elevation/v1/{z}/{y}/{x}.png"
    )

    private enum Key {
        static let settings = "settings.tiles"
        static let fetchedAt = "settings.fetchedAt"
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "fjallkartan",
                                    category: "RemoteSettings")

    private let defaults: UserDefaults
    private let url: URL
    private let session: URLSession
    private let now: () -> Date

    private let lock = NSLock()
    private var stored: TileSettings
    private var isRefreshing = false

    init(defaults: UserDefaults = .standard,
         url: URL = RemoteSettings.settingsURL,
         session: URLSession = RemoteSettings.makeSession(),
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.url = url
        self.session = session
        self.now = now
        self.stored = Self.persistedSettings(in: defaults) ?? Self.builtIn
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// The configuration currently in effect.
    var settings: TileSettings {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var minAppVersion: String { settings.minAppVersion }

    /// The tile URL for one tile position. Falls back to the built-in
    /// template if the active one somehow fails to produce a URL.
    func tileURL(server: TileServer, z: Int, x: Int, y: Int) -> URL {
        let current = settings
        let template: String
        let fallback: String
        switch server {
        case .kartverket:
            template = current.kartverketUrl
            fallback = Self.builtIn.kartverketUrl
        case .lantmateriet:
            template = current.lantmaterietUrl
            fallback = Self.builtIn.lantmaterietUrl
        case .norwaySlope:
            template = current.norwaySlopeUrl
            fallback = Self.builtIn.norwaySlopeUrl
        case .swedenSlope:
            template = current.swedenSlopeUrl
            fallback = Self.builtIn.swedenSlopeUrl
        case .elevation:
            template = current.elevationUrl
            fallback = Self.builtIn.elevationUrl
        }
        if let url = TileSettings.url(from: template, z: z, x: x, y: y) {
            return url
        }
        return TileSettings.url(from: fallback, z: z, x: x, y: y)!
    }

    // MARK: - Refresh

    func refresh(force: Bool = false, completion: (() -> Void)? = nil) {
        lock.lock()
        let shouldSkip = !force && (isRefreshing || !isStaleLocked())
        if !shouldSkip { isRefreshing = true }
        lock.unlock()

        guard !shouldSkip else {
            completion?()
            return
        }

        session.dataTask(with: URLRequest(url: url)) { [weak self] data, response, error in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.isRefreshing = false
                self.lock.unlock()
                completion?()
            }

            guard let data, error == nil,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                Self.log.debug("settings fetch failed: \(error?.localizedDescription ?? "bad response")")
                return
            }
            self.apply(data)
        }.resume()
    }

    @discardableResult
    func apply(_ data: Data) -> Bool {
        let decoded: TileSettings
        do {
            decoded = try JSONDecoder().decode(TileSettings.self, from: data)
        } catch {
            Self.log.error("discarding settings payload, could not decode: \(error.localizedDescription)")
            return false
        }
        if !decoded.isUsable {
            Self.log.error("discarding settings payload: unusable minAppVersion or tile template")
            return false
        }
        lock.lock()
        stored = decoded
        lock.unlock()
        defaults.set(data, forKey: Key.settings)
        defaults.set(now().timeIntervalSince1970, forKey: Key.fetchedAt)
        return true
    }

    private func isStaleLocked() -> Bool {
        let fetchedAt = defaults.double(forKey: Key.fetchedAt)
        guard fetchedAt > 0 else { return true }
        return now().timeIntervalSince1970 - fetchedAt >= Self.refreshInterval
    }

    private static func persistedSettings(in defaults: UserDefaults) -> TileSettings? {
        guard let data = defaults.data(forKey: Key.settings),
              let decoded = try? JSONDecoder().decode(TileSettings.self, from: data),
              decoded.isUsable else { return nil }
        return decoded
    }
}
