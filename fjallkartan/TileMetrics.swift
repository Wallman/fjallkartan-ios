import Foundation

/// Aggregate counters describing how tile requests were answered
nonisolated final class TileMetrics: @unchecked Sendable {

    enum Source: String, Codable, CaseIterable {
        /// Served from a downloaded offline region.
        case offlineStore
        /// Served from the shared `URLCache` of previously browsed tiles.
        case urlCache
        /// Fetched over the network.
        case network
        /// Faked by magnifying the deepest stored ancestor, past the offline
        /// zoom cap. Counts as served, but the user is looking at a blur.
        case upscaledAncestor
        /// A 404 from a sparse tileset: outside coverage, working as intended.
        case expectedNoData
        /// A no-data answer from a layer that should have had a tile here.
        case unexpectedNoData
        /// Gave up: transport error, connectivity loss, or retries exhausted.
        case failure

        var servedTile: Bool {
            switch self {
            case .offlineStore, .urlCache, .network, .upscaledAncestor: return true
            case .expectedNoData, .unexpectedNoData, .failure: return false
            }
        }

        /// Whether the answer was produced without touching the network.
        var servedLocally: Bool {
            switch self {
            case .offlineStore, .urlCache, .upscaledAncestor: return true
            case .network, .expectedNoData, .unexpectedNoData, .failure: return false
            }
        }

        /// `expectedNoData` is not a fault and must not inflate the failure
        /// rate; on the slope layers it is the majority answer.
        var isFault: Bool {
            self == .unexpectedNoData || self == .failure
        }

        var label: String {
            switch self {
            case .offlineStore: return "Offline store"
            case .urlCache: return "Browse cache"
            case .network: return "Network"
            case .upscaledAncestor: return "Upscaled"
            case .expectedNoData: return "No coverage"
            case .unexpectedNoData: return "Missing"
            case .failure: return "Failed"
            }
        }
    }

    // MARK: - Latency histogram

    /// Upper bounds in milliseconds; a final overflow bucket holds the rest.
    /// Buckets rather than a running mean because the tail is the interesting
    /// part — a mean hides the 8-second tile that made the map look broken.
    static let latencyBoundsMS = [1, 3, 10, 30, 100, 300, 1_000, 3_000, 10_000]
    static var latencyBucketCount: Int { latencyBoundsMS.count + 1 }

    private static func latencyBucket(milliseconds: Double) -> Int {
        for (index, bound) in latencyBoundsMS.enumerated() where milliseconds <= Double(bound) {
            return index
        }
        return latencyBoundsMS.count
    }

    // MARK: - Stored shape

    private struct Entry: Codable {
        var counts: [String: Int] = [:]
        var latency: [Int] = Array(repeating: 0, count: TileMetrics.latencyBucketCount)
        /// Requests that needed more than one network attempt.
        var retriedRequests = 0
        /// Total retry attempts beyond the first, across those requests.
        var retryAttempts = 0

        /// Tolerates a histogram written by a build with different bounds
        /// rather than crashing on an index that no longer exists.
        mutating func normalize() {
            let expected = TileMetrics.latencyBucketCount
            if latency.count < expected {
                latency.append(contentsOf: Array(repeating: 0, count: expected - latency.count))
            } else if latency.count > expected {
                latency = Array(latency.prefix(expected))
            }
        }
    }

    /// JSON objects can only be keyed by strings, so the (server, zoom) key is
    /// flattened into the record instead of being a dictionary key.
    private struct Record: Codable {
        var server: Int
        var z: Int
        var entry: Entry
    }

    private struct Payload: Codable {
        var since: Date
        var records: [Record]
    }

    private struct Key: Hashable {
        let server: Int
        let z: Int
    }

    // MARK: - Snapshot for the UI

    struct ZoomStats: Identifiable {
        let z: Int
        let counts: [Source: Int]
        var id: Int { z }
        var total: Int { counts.values.reduce(0, +) }
    }

    struct LayerStats: Identifiable {
        let server: TileServer
        let counts: [Source: Int]
        let byZoom: [ZoomStats]
        let retriedRequests: Int
        let retryAttempts: Int
        private let latency: [Int]

        var id: Int { server.storeCode }
        var total: Int { counts.values.reduce(0, +) }

        init(server: TileServer, counts: [Source: Int], byZoom: [ZoomStats],
             retriedRequests: Int, retryAttempts: Int, latency: [Int]) {
            self.server = server
            self.counts = counts
            self.byZoom = byZoom
            self.retriedRequests = retriedRequests
            self.retryAttempts = retryAttempts
            self.latency = latency
        }

        func count(_ source: Source) -> Int { counts[source] ?? 0 }

        /// Share of requests answered without the network, over the requests
        /// that produced a tile at all — a layer that is mostly out of
        /// coverage would otherwise look like a cache failure.
        var localHitRate: Double? {
            let served = Source.allCases.filter(\.servedTile).map(count).reduce(0, +)
            guard served > 0 else { return nil }
            let local = Source.allCases.filter { $0.servedTile && $0.servedLocally }.map(count).reduce(0, +)
            return Double(local) / Double(served)
        }

        /// Faults over all requests, with expected sparse gaps excluded.
        var faultRate: Double? {
            let considered = total - count(.expectedNoData)
            guard considered > 0 else { return nil }
            let faults = Source.allCases.filter(\.isFault).map(count).reduce(0, +)
            return Double(faults) / Double(considered)
        }

        /// Upper bound in ms of the bucket holding the p-th sample, or nil if
        /// there are no samples. `nil` inside `.some` overflow is reported by
        /// returning the last bound with `isOverflow`.
        func latencyPercentile(_ percentile: Double) -> (milliseconds: Int, isOverflow: Bool)? {
            let samples = latency.reduce(0, +)
            guard samples > 0 else { return nil }
            let target = Int((Double(samples) * percentile).rounded(.up))
            var seen = 0
            for (index, count) in latency.enumerated() {
                seen += count
                guard seen >= max(target, 1) else { continue }
                if index < TileMetrics.latencyBoundsMS.count {
                    return (TileMetrics.latencyBoundsMS[index], false)
                }
                return (TileMetrics.latencyBoundsMS[TileMetrics.latencyBoundsMS.count - 1], true)
            }
            return nil
        }
    }

    struct Snapshot {
        let since: Date
        let layers: [LayerStats]
        var isEmpty: Bool { layers.allSatisfy { $0.total == 0 } }
    }

    // MARK: - Lifetime

    static let shared = TileMetrics()

    static var defaultURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("tile-metrics.json")
    }

    private let url: URL?
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "TileMetrics.write", qos: .utility)

    private var entries: [Key: Entry] = [:]
    private var since = Date()
    private var unsavedRecords = 0

    /// Flush after this many records rather than on every one: a pan across
    /// the map produces hundreds of fetches, and each is a few microseconds of
    /// bookkeeping that must not turn into a file write.
    private static let flushThreshold = 200

    /// - Parameter url: `nil` keeps everything in memory, which is what the
    ///   tests want — no shared file, no surviving state between runs.
    init(url: URL? = TileMetrics.defaultURL) {
        self.url = url
        load()
    }

    // MARK: - Recording

    func record(server: TileServer, z: Int, source: Source, attempts: Int, seconds: Double) {
        let key = Key(server: server.storeCode, z: z)
        let bucket = Self.latencyBucket(milliseconds: seconds * 1000)

        lock.lock()
        var entry = entries[key] ?? Entry()
        entry.counts[source.rawValue, default: 0] += 1
        entry.latency[bucket] += 1
        if attempts > 1 {
            entry.retriedRequests += 1
            entry.retryAttempts += attempts - 1
        }
        entries[key] = entry
        unsavedRecords += 1
        let shouldFlush = unsavedRecords >= Self.flushThreshold
        lock.unlock()

        if shouldFlush { flush() }
    }

    // MARK: - Reading

    func snapshot() -> Snapshot {
        lock.lock()
        let entries = self.entries
        let since = self.since
        lock.unlock()

        let layers = TileServer.allCases.map { server -> LayerStats in
            let forServer = entries.filter { $0.key.server == server.storeCode }

            var counts: [Source: Int] = [:]
            var latency = [Int](repeating: 0, count: Self.latencyBucketCount)
            var retriedRequests = 0
            var retryAttempts = 0

            for (_, entry) in forServer {
                for (raw, count) in entry.counts {
                    guard let source = Source(rawValue: raw) else { continue }
                    counts[source, default: 0] += count
                }
                for (index, count) in entry.latency.enumerated() where index < latency.count {
                    latency[index] += count
                }
                retriedRequests += entry.retriedRequests
                retryAttempts += entry.retryAttempts
            }

            let byZoom = forServer
                .map { key, entry in
                    ZoomStats(z: key.z, counts: entry.counts.reduce(into: [Source: Int]()) { result, pair in
                        guard let source = Source(rawValue: pair.key) else { return }
                        result[source, default: 0] += pair.value
                    })
                }
                .sorted { $0.z < $1.z }

            return LayerStats(server: server, counts: counts, byZoom: byZoom,
                              retriedRequests: retriedRequests, retryAttempts: retryAttempts,
                              latency: latency)
        }

        return Snapshot(since: since, layers: layers)
    }

    func reset() {
        lock.lock()
        entries.removeAll()
        since = Date()
        unsavedRecords = 0
        let payload = Payload(since: since, records: [])
        lock.unlock()

        write(payload)
    }

    // MARK: - Persistence

    func flush() {
        lock.lock()
        guard unsavedRecords > 0 else { lock.unlock(); return }
        unsavedRecords = 0
        let payload = Payload(since: since,
                              records: entries.map { Record(server: $0.key.server, z: $0.key.z, entry: $0.value) })
        lock.unlock()

        write(payload)
    }

    private func write(_ payload: Payload) {
        guard let url else { return }
        writeQueue.async {
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }

        since = payload.since
        for record in payload.records {
            var entry = record.entry
            entry.normalize()
            entries[Key(server: record.server, z: record.z)] = entry
        }
    }
}
