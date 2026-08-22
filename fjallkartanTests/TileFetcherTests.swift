import Foundation
import Testing

@testable import fjallkartan

final class TileFetcherStubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (status: Int, data: Data, headers: [String: String])

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?
    nonisolated(unsafe) private static var _errorHandler: ((URLRequest) -> URLError?)?
    nonisolated(unsafe) private static var _requestCount = 0

    static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue; _errorHandler = nil; _requestCount = 0 }
    }

    /// Set after `handler`: returning a non-nil error for a request makes the
    /// stub fail at the transport level instead of answering `handler`.
    static var errorHandler: ((URLRequest) -> URLError?)? {
        get { lock.lock(); defer { lock.unlock() }; return _errorHandler }
        set { lock.lock(); defer { lock.unlock() }; _errorHandler = newValue }
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }; return _requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requestCount += 1
        let handler = Self._handler
        let errorHandler = Self._errorHandler
        Self.lock.unlock()

        if let error = errorHandler?(request) {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, data, headers) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// Serialized: these tests share the process-global stub handler and its
// request counter, so running them concurrently would interleave the counts.
@Suite(.serialized)
struct TileFetcherTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47])
    private static let imageHeaders = ["Content-Type": "image/png"]

    private func makeSession(cache: URLCache?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TileFetcherStubURLProtocol.self]
        config.urlCache = cache
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    private func makeCache() -> URLCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TileFetcherTests-\(UUID().uuidString)")
        return URLCache(memoryCapacity: 0, diskCapacity: 8 * 1024 * 1024, directory: directory)
    }

    private func makeFetcher(cache: URLCache? = nil, metrics: TileMetrics? = nil) -> TileFetcher {
        var configuration = TileFetcher.Configuration()
        configuration.initialRetryDelay = 0.01
        configuration.connectivityRetryDelay = 0.01
        return TileFetcher(session: makeSession(cache: cache), cache: cache,
                           configuration: configuration,
                           metrics: metrics)
    }

    /// In-memory: no shared file, nothing surviving between runs.
    private func makeMetrics() -> TileMetrics { TileMetrics(url: nil) }

    private func count(_ metrics: TileMetrics, _ server: TileServer, _ source: TileMetrics.Source) -> Int {
        metrics.snapshot().layers.first { $0.server == server }?.count(source) ?? 0
    }

    private func fetchTile(_ fetcher: TileFetcher, server: TileServer, z: Int, x: Int, y: Int) async -> TileFetchOutcome {
        await withCheckedContinuation { continuation in
            fetcher.fetchTile(server: server, z: z, x: x, y: y) { continuation.resume(returning: $0) }
        }
    }

    /// `TileFetcher` is callback-based; bridge it once for the assertions.
    private func fetch(_ fetcher: TileFetcher, url: URL) async -> TileFetchOutcome {
        await withCheckedContinuation { continuation in
            fetcher.fetch(url: url) { continuation.resume(returning: $0) }
        }
    }

    private var url: URL { URL(string: "https://example.test/tile/7/1/2.png")! }

    @Test func successReturnsTheTileBytes() async {
        TileFetcherStubURLProtocol.handler = { _ in (200, Self.png, Self.imageHeaders) }

        let outcome = await fetch(makeFetcher(), url: url)

        guard case .success(let data) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(data == Self.png)
    }

    @Test func clientErrorIsNoDataAndIsNotRetried() async {
        TileFetcherStubURLProtocol.handler = { _ in (404, Data(), [:]) }

        let outcome = await fetch(makeFetcher(), url: url)

        guard case .noData = outcome else {
            Issue.record("expected noData, got \(outcome)")
            return
        }
        #expect(TileFetcherStubURLProtocol.requestCount == 1)
    }

    @Test func nonImageSuccessIsTreatedAsNoData() async {
        TileFetcherStubURLProtocol.handler = { _ in (200, Data("<html>oops</html>".utf8), ["Content-Type": "text/html"]) }

        let outcome = await fetch(makeFetcher(), url: url)

        guard case .noData = outcome else {
            Issue.record("expected noData, got \(outcome)")
            return
        }
        #expect(TileFetcherStubURLProtocol.requestCount == 1)
    }

    @Test func throttlingIsRetriedThenSucceeds() async {
        TileFetcherStubURLProtocol.handler = { _ in
            TileFetcherStubURLProtocol.requestCount <= 2
                ? (503, Data(), ["Retry-After": "0"])
                : (200, Self.png, Self.imageHeaders)
        }

        let outcome = await fetch(makeFetcher(), url: url)

        guard case .success = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(TileFetcherStubURLProtocol.requestCount == 3)
    }

    @Test func serverErrorSurvivingEveryRetryIsAFailure() async {
        TileFetcherStubURLProtocol.handler = { _ in (500, Data(), [:]) }

        let outcome = await fetch(makeFetcher(), url: url)

        guard case .failure = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        // Failures must be distinguishable from no-data: the slope layer
        // returns them to MapKit so the tile is requested again.
        #expect(TileFetcherStubURLProtocol.requestCount == 3)
    }

    @Test func connectionResetIsRetriedThenSucceeds() async {
        TileFetcherStubURLProtocol.handler = { _ in (200, Self.png, Self.imageHeaders) }
        // "Connection reset by peer" reaches URLSession as networkConnectionLost.
        TileFetcherStubURLProtocol.errorHandler = { _ in
            TileFetcherStubURLProtocol.requestCount <= 2 ? URLError(.networkConnectionLost) : nil
        }

        let outcome = await fetch(makeFetcher(), url: url)

        guard case .success(let data) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(data == Self.png)
        #expect(TileFetcherStubURLProtocol.requestCount == 3)
    }

    @Test func offlineIsRetriedOnceThenGivesUp() async {
        TileFetcherStubURLProtocol.handler = { _ in (200, Self.png, Self.imageHeaders) }
        TileFetcherStubURLProtocol.errorHandler = { _ in URLError(.notConnectedToInternet) }

        let outcome = await fetch(makeFetcher(), url: url)

        guard case .failure = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        // Burning the full budget on a device that really is offline is
        // pointless, but one retry covers a cold start that reports "offline"
        // before the network stack is up.
        #expect(TileFetcherStubURLProtocol.requestCount == 2)
    }

    @Test func connectivityErrorOnColdStartIsRetriedThenSucceeds() async {
        TileFetcherStubURLProtocol.handler = { _ in (200, Self.png, Self.imageHeaders) }
        TileFetcherStubURLProtocol.errorHandler = { _ in
            TileFetcherStubURLProtocol.requestCount <= 1 ? URLError(.notConnectedToInternet) : nil
        }

        let outcome = await fetch(makeFetcher(), url: url)

        guard case .success(let data) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(data == Self.png)
        #expect(TileFetcherStubURLProtocol.requestCount == 2)
    }

    @Test func cachedTileIsServedWithoutHittingTheNetwork() async {
        TileFetcherStubURLProtocol.handler = { _ in (200, Self.png, Self.imageHeaders) }
        let cache = makeCache()
        let fetcher = makeFetcher(cache: cache)

        _ = await fetch(fetcher, url: url)
        let countAfterFirst = TileFetcherStubURLProtocol.requestCount
        let outcome = await fetch(fetcher, url: url)

        guard case .success(let data) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(data == Self.png)
        #expect(TileFetcherStubURLProtocol.requestCount == countAfterFirst)
        cache.removeAllCachedResponses()
    }

    @Test func failuresAreNotCached() async {
        TileFetcherStubURLProtocol.handler = { _ in (404, Data(), [:]) }
        let cache = makeCache()
        let fetcher = makeFetcher(cache: cache)

        _ = await fetch(fetcher, url: url)
        let countAfterFirst = TileFetcherStubURLProtocol.requestCount
        _ = await fetch(fetcher, url: url)

        // Nothing was cached, so the second fetch has to ask the server again.
        #expect(TileFetcherStubURLProtocol.requestCount == countAfterFirst + 1)
        cache.removeAllCachedResponses()
    }

    // MARK: - Metrics attribution

    @Test func networkThenCacheAreAttributedSeparately() async {
        TileFetcherStubURLProtocol.handler = { _ in (200, Self.png, Self.imageHeaders) }
        let metrics = makeMetrics()
        let cache = makeCache()
        let fetcher = makeFetcher(cache: cache, metrics: metrics)

        _ = await fetchTile(fetcher, server: .kartverket, z: 10, x: 1, y: 2)
        _ = await fetchTile(fetcher, server: .kartverket, z: 10, x: 1, y: 2)

        #expect(count(metrics, .kartverket, .network) == 1)
        #expect(count(metrics, .kartverket, .urlCache) == 1)
        cache.removeAllCachedResponses()
    }

    /// Every tileset here is sparse in some direction — the slope and elevation
    /// sets exist only where data does, and each base layer stops at its own
    /// country's border — so a 404 must not read as breakage, otherwise the
    /// fault rate is dominated by the layers working exactly as designed.
    @Test(arguments: [TileServer.swedenSlope, .kartverket, .lantmateriet])
    func notFoundIsNotCountedAsAFault(server: TileServer) async {
        TileFetcherStubURLProtocol.handler = { _ in (404, Data(), [:]) }
        let metrics = makeMetrics()

        _ = await fetchTile(makeFetcher(metrics: metrics), server: server, z: 12, x: 3, y: 4)

        #expect(count(metrics, server, .expectedNoData) == 1)
        #expect(count(metrics, server, .unexpectedNoData) == 0)
        #expect(metrics.snapshot().layers.first { $0.server == server }?.faultRate == nil)
    }

    /// A 404 is the shape a missing tile takes; any other client error is the
    /// server telling us the request itself was wrong, which is a real fault.
    @Test func otherClientErrorIsCountedAsAFault() async {
        TileFetcherStubURLProtocol.handler = { _ in (400, Data(), [:]) }
        let metrics = makeMetrics()

        _ = await fetchTile(makeFetcher(metrics: metrics), server: .kartverket, z: 10, x: 1, y: 2)

        #expect(count(metrics, .kartverket, .unexpectedNoData) == 1)
        #expect(metrics.snapshot().layers.first { $0.server == .kartverket }?.faultRate == 1)
    }

    @Test func nonImageSuccessIsCountedAsAFault() async {
        TileFetcherStubURLProtocol.handler = { _ in (200, Data("<html>oops</html>".utf8), ["Content-Type": "text/html"]) }
        let metrics = makeMetrics()

        _ = await fetchTile(makeFetcher(metrics: metrics), server: .lantmateriet, z: 9, x: 1, y: 1)

        #expect(count(metrics, .lantmateriet, .unexpectedNoData) == 1)
        #expect(count(metrics, .lantmateriet, .network) == 0)
    }

    @Test func retriesAreCountedAgainstTheSucceedingRequest() async {
        TileFetcherStubURLProtocol.handler = { _ in
            TileFetcherStubURLProtocol.requestCount <= 2
                ? (500, Data(), [:])
                : (200, Self.png, Self.imageHeaders)
        }
        let metrics = makeMetrics()

        _ = await fetchTile(makeFetcher(metrics: metrics), server: .kartverket, z: 8, x: 1, y: 1)

        let layer = metrics.snapshot().layers.first { $0.server == .kartverket }
        #expect(count(metrics, .kartverket, .network) == 1)
        #expect(layer?.retriedRequests == 1)
        #expect(layer?.retryAttempts == 2)
    }

    @Test func connectivityLossIsRecordedAsFailure() async {
        TileFetcherStubURLProtocol.handler = { _ in (200, Self.png, Self.imageHeaders) }
        TileFetcherStubURLProtocol.errorHandler = { _ in URLError(.notConnectedToInternet) }
        let metrics = makeMetrics()

        _ = await fetchTile(makeFetcher(metrics: metrics), server: .lantmateriet, z: 11, x: 5, y: 6)

        #expect(count(metrics, .lantmateriet, .failure) == 1)
    }

    @Test func everyRequestContributesALatencySample() async {
        TileFetcherStubURLProtocol.handler = { _ in (200, Self.png, Self.imageHeaders) }
        let metrics = makeMetrics()

        _ = await fetchTile(makeFetcher(metrics: metrics), server: .kartverket, z: 12, x: 1, y: 1)

        #expect(metrics.snapshot().layers.first { $0.server == .kartverket }?.latencyPercentile(0.5) != nil)
    }

    /// The bulk region downloader goes through `fetch(url:)`, which is
    /// never recorded: a region download is tens of thousands of fetches in a
    /// burst and would drown out what ordinary browsing looks like.
    @Test func theBulkDownloadEntryPointIsNotRecorded() async {
        TileFetcherStubURLProtocol.handler = { _ in (200, Self.png, Self.imageHeaders) }
        let metrics = makeMetrics()

        _ = await withCheckedContinuation { continuation in
            makeFetcher(metrics: metrics).fetch(url: url) {
                continuation.resume(returning: $0)
            }
        }

        #expect(metrics.snapshot().isEmpty)
    }
}
