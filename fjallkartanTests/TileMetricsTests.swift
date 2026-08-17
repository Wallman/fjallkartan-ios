import Foundation
import Testing

@testable import fjallkartan

struct TileMetricsTests {

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TileMetricsTests-\(UUID().uuidString).json")
    }

    private func layer(_ metrics: TileMetrics, _ server: TileServer) -> TileMetrics.LayerStats? {
        metrics.snapshot().layers.first { $0.server == server }
    }

    private func record(_ metrics: TileMetrics, _ source: TileMetrics.Source, times: Int,
                        server: TileServer = .kartverket, z: Int = 12, seconds: Double = 0.05) {
        for _ in 0..<times {
            metrics.record(server: server, z: z, source: source, attempts: 1, seconds: seconds)
        }
    }

    // MARK: - Rates

    @Test func localHitRateIgnoresRequestsThatProducedNoTile() {
        let metrics = TileMetrics(url: nil)
        record(metrics, .offlineStore, times: 3)
        record(metrics, .network, times: 1)
        // 96 misses would drag a naive hit rate to 4 %, but no cache could
        // have answered them: they had no tile to serve.
        record(metrics, .expectedNoData, times: 96)

        #expect(layer(metrics, .kartverket)?.localHitRate == 0.75)
    }

    @Test func upscaledTilesCountAsServedLocally() {
        let metrics = TileMetrics(url: nil)
        record(metrics, .upscaledAncestor, times: 1)
        record(metrics, .network, times: 1)

        #expect(layer(metrics, .kartverket)?.localHitRate == 0.5)
    }

    @Test func faultRateExcludesExpectedGapsFromItsDenominator() {
        let metrics = TileMetrics(url: nil)
        record(metrics, .network, times: 3)
        record(metrics, .failure, times: 1)
        record(metrics, .expectedNoData, times: 96)

        // 1 fault out of the 4 requests that could have succeeded.
        #expect(layer(metrics, .kartverket)?.faultRate == 0.25)
    }

    @Test func ratesAreNilWithoutSamplesRatherThanZero() {
        let metrics = TileMetrics(url: nil)
        record(metrics, .expectedNoData, times: 5)

        #expect(layer(metrics, .kartverket)?.localHitRate == nil)
        #expect(layer(metrics, .kartverket)?.faultRate == nil)
    }

    // MARK: - Latency

    @Test func percentilesReportTheContainingBucketBound() {
        let metrics = TileMetrics(url: nil)
        record(metrics, .network, times: 95, seconds: 0.02)   // ≤ 30 ms
        record(metrics, .network, times: 5, seconds: 5)       // ≤ 10 s

        let stats = layer(metrics, .kartverket)
        #expect(stats?.latencyPercentile(0.5)?.milliseconds == 30)
        #expect(stats?.latencyPercentile(0.5)?.isOverflow == false)
        // The slow tail is what p99 must surface; a mean would bury it.
        #expect(stats?.latencyPercentile(0.99)?.milliseconds == 10_000)
    }

    @Test func samplesPastTheLastBoundAreFlaggedAsOverflow() {
        let metrics = TileMetrics(url: nil)
        record(metrics, .failure, times: 1, seconds: 45)

        let value = layer(metrics, .kartverket)?.latencyPercentile(0.5)
        #expect(value?.milliseconds == 10_000)
        #expect(value?.isOverflow == true)
    }

    @Test func percentileIsNilWithoutSamples() {
        let metrics = TileMetrics(url: nil)

        #expect(layer(metrics, .kartverket)?.latencyPercentile(0.5) == nil)
    }

    // MARK: - Aggregation

    @Test func layersAndZoomsAreKeptApart() {
        let metrics = TileMetrics(url: nil)
        record(metrics, .network, times: 2, server: .kartverket, z: 10)
        record(metrics, .network, times: 3, server: .kartverket, z: 14)
        record(metrics, .network, times: 5, server: .elevation, z: 12)

        let kartverket = layer(metrics, .kartverket)
        #expect(kartverket?.total == 5)
        #expect(kartverket?.byZoom.map(\.z) == [10, 14])
        #expect(kartverket?.byZoom.first?.total == 2)
        #expect(layer(metrics, .elevation)?.total == 5)
    }

    // MARK: - Persistence

    @Test func countersSurviveAReload() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let metrics = TileMetrics(url: url)
        record(metrics, .network, times: 4, server: .norwaySlope, z: 13)
        record(metrics, .expectedNoData, times: 6, server: .norwaySlope, z: 13)
        metrics.flush()

        try await waitForFile(at: url)
        let reloaded = TileMetrics(url: url)

        #expect(layer(reloaded, .norwaySlope)?.count(.network) == 4)
        #expect(layer(reloaded, .norwaySlope)?.count(.expectedNoData) == 6)
        #expect(layer(reloaded, .norwaySlope)?.latencyPercentile(0.5) != nil)
    }

    @Test func resetClearsBothMemoryAndDisk() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let metrics = TileMetrics(url: url)
        record(metrics, .network, times: 4)
        let before = metrics.snapshot().since
        metrics.reset()

        try await waitForFile(at: url)
        #expect(metrics.snapshot().isEmpty)
        #expect(TileMetrics(url: url).snapshot().isEmpty)
        #expect(metrics.snapshot().since >= before)
    }

    @Test func inMemoryMetricsWriteNothing() {
        let metrics = TileMetrics(url: nil)
        record(metrics, .network, times: 1)
        metrics.flush()

        #expect(!metrics.snapshot().isEmpty)
    }

    /// A build that changes `latencyBoundsMS` must not crash on the histogram
    /// the previous build left behind.
    @Test func aHistogramOfTheWrongWidthIsAccepted() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let json = """
        {"since":0,"records":[{"server":0,"z":12,"entry":{"counts":{"network":3},\
        "latency":[1,2],"retriedRequests":0,"retryAttempts":0}}]}
        """
        try Data(json.utf8).write(to: url)

        let metrics = TileMetrics(url: url)
        #expect(layer(metrics, .kartverket)?.count(.network) == 3)
        #expect(layer(metrics, .kartverket)?.latencyPercentile(0.5) != nil)
    }

    /// Writes are asynchronous so recording never blocks a tile completion.
    private func waitForFile(at url: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("metrics file was never written")
    }
}
