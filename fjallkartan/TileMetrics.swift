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

    /// Upper bound in ms of the bucket holding the p-th sample, or nil if
    /// there are no samples. A sample past the last bound is reported as that
    /// bound with `isOverflow`.
    static func percentile(_ percentile: Double, in histogram: [Int]) -> (milliseconds: Int, isOverflow: Bool)? {
        let samples = histogram.reduce(0, +)
        guard samples > 0 else { return nil }
        let target = Int((Double(samples) * percentile).rounded(.up))
        var seen = 0
        for (index, count) in histogram.enumerated() {
            seen += count
            guard seen >= max(target, 1) else { continue }
            if index < latencyBoundsMS.count {
                return (latencyBoundsMS[index], false)
            }
            return (latencyBoundsMS[latencyBoundsMS.count - 1], true)
        }
        return nil
    }

    private static func emptyHistogram() -> [Int] {
        Array(repeating: 0, count: latencyBucketCount)
    }

    // MARK: - Stored shape

    private struct Entry: Codable {
        var counts: [String: Int] = [:]
        /// Aggregate latency over every source. Kept alongside
        /// `latencyBySource` rather than derived from it because it predates
        /// it: a file written by an earlier build has only this, and dropping
        /// it would silently discard that history on upgrade.
        var latency: [Int] = TileMetrics.emptyHistogram()
        /// One histogram per `Source.rawValue`. A blended p95 can't answer
        /// whether a cache hit is fast — it mixes ~0 ms store hits with
        /// multi-second network fetches.
        var latencyBySource: [String: [Int]] = [:]
        /// Requests that needed more than one network attempt.
        var retriedRequests = 0
        /// Total retry attempts beyond the first, across those requests.
        var retryAttempts = 0

        init() {}

        /// Every field is optional on the way in: `latencyBySource` is absent
        /// from files written before it existed.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            counts = try container.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
            latency = try container.decodeIfPresent([Int].self, forKey: .latency) ?? []
            latencyBySource = try container.decodeIfPresent([String: [Int]].self, forKey: .latencyBySource) ?? [:]
            retriedRequests = try container.decodeIfPresent(Int.self, forKey: .retriedRequests) ?? 0
            retryAttempts = try container.decodeIfPresent(Int.self, forKey: .retryAttempts) ?? 0
        }

        /// Tolerates a histogram written by a build with different bounds
        /// rather than crashing on an index that no longer exists, and drops
        /// any source name this build no longer knows.
        mutating func normalize() {
            latency = Self.normalized(latency)
            var normalizedBySource: [String: [Int]] = [:]
            for (raw, histogram) in latencyBySource where Source(rawValue: raw) != nil {
                normalizedBySource[raw] = Self.normalized(histogram)
            }
            latencyBySource = normalizedBySource
        }

        private static func normalized(_ histogram: [Int]) -> [Int] {
            let expected = TileMetrics.latencyBucketCount
            if histogram.count < expected {
                return histogram + Array(repeating: 0, count: expected - histogram.count)
            }
            return histogram.count > expected ? Array(histogram.prefix(expected)) : histogram
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
        private let latencyBySource: [Source: [Int]]

        var id: Int { server.storeCode }
        var total: Int { counts.values.reduce(0, +) }

        init(server: TileServer, counts: [Source: Int], byZoom: [ZoomStats],
             retriedRequests: Int, retryAttempts: Int, latency: [Int],
             latencyBySource: [Source: [Int]] = [:]) {
            self.server = server
            self.counts = counts
            self.byZoom = byZoom
            self.retriedRequests = retriedRequests
            self.retryAttempts = retryAttempts
            self.latency = latency
            self.latencyBySource = latencyBySource
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

        /// Upper bound in ms of the bucket holding the p-th sample across every
        /// source, or nil if there are no samples.
        func latencyPercentile(_ percentile: Double) -> (milliseconds: Int, isOverflow: Bool)? {
            TileMetrics.percentile(percentile, in: latency)
        }

        /// The same figure for one source alone. This is the one that can say
        /// whether a cache hit is actually cheap; the blended figure above
        /// mixes it with network fetches and cannot.
        func latencyPercentile(_ percentile: Double, for source: Source) -> (milliseconds: Int, isOverflow: Bool)? {
            guard let histogram = latencyBySource[source] else { return nil }
            return TileMetrics.percentile(percentile, in: histogram)
        }

        /// Samples recorded for one source. Lower than `count(source)` for
        /// counters carried over from a build that only kept the blended
        /// histogram, so the UI can avoid quoting a percentile from a handful
        /// of samples.
        func latencySamples(for source: Source) -> Int {
            latencyBySource[source]?.reduce(0, +) ?? 0
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
        var perSource = entry.latencyBySource[source.rawValue] ?? Self.emptyHistogram()
        perSource[bucket] += 1
        entry.latencyBySource[source.rawValue] = perSource
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
            var latency = Self.emptyHistogram()
            var latencyBySource: [Source: [Int]] = [:]
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
                for (raw, histogram) in entry.latencyBySource {
                    guard let source = Source(rawValue: raw) else { continue }
                    var merged = latencyBySource[source] ?? Self.emptyHistogram()
                    for (index, count) in histogram.enumerated() where index < merged.count {
                        merged[index] += count
                    }
                    latencyBySource[source] = merged
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
                              latency: latency, latencyBySource: latencyBySource)
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
