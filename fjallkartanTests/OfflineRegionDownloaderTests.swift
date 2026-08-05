import Foundation
import MapKit
import Testing

@testable import fjallkartan

final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (status: Int, data: Data, headers: [String: String])

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?

    static var handler: Handler? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
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

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

// Serialized: these tests share the process-global `StubURLProtocol.handler`,
// so running them concurrently would let one test's handler leak into another.
@Suite(.serialized)
@MainActor
struct OfflineRegionDownloaderTests {
    private static let tinyPNG = Data([0x89, 0x50, 0x4E, 0x47]) // not a valid PNG, but store round-trips raw bytes

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeStore() throws -> OfflineTileStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineRegionDownloaderTests-\(UUID().uuidString).sqlite")
        return try OfflineTileStore(url: url)
    }

    /// A rect small enough that every zoom level in the fixed z7–z13 pyramid
    /// contributes exactly one position, keeping job counts tiny and tests fast.
    private var tinyRect: MKMapRect {
        let point = MKMapPoint(CLLocationCoordinate2D(latitude: 68.35, longitude: 18.83))
        return MKMapRect(x: point.x, y: point.y, width: 1, height: 1)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func downloadsAllTilesAndCompletes() async throws {
        StubURLProtocol.handler = { _ in (200, Self.tinyPNG, ["Content-Type": "image/png"]) }
        let store = try makeStore()
        let downloader = OfflineRegionDownloader(store: store, session: makeStubSession())

        downloader.start(regionID: "r1", name: "Test", rect: tinyRect)
        await waitUntil({ downloader.status == .completed })

        #expect(downloader.status == .completed)
        #expect(downloader.tilesDone == downloader.tilesTotal)
        #expect(downloader.tilesTotal > 0)
        #expect(store.regions().first?.status == .complete)
    }

    @Test func transientFailureIsRetriedAndEventuallySucceeds() async throws {
        let attempts = Counter()
        StubURLProtocol.handler = { _ in
            let n = attempts.increment()
            if n <= 2 { return (503, Data(), ["Retry-After": "0"]) }
            return (200, Self.tinyPNG, ["Content-Type": "image/png"])
        }
        let store = try makeStore()
        let downloader = OfflineRegionDownloader(store: store, session: makeStubSession())

        downloader.start(regionID: "r1", name: "Test", rect: tinyRect)
        await waitUntil({ downloader.status == .completed }, timeout: 10)

        #expect(downloader.status == .completed)
        #expect(downloader.tilesDone == downloader.tilesTotal)
        // At least one tile round-tripped despite the transient 503s.
        #expect(store.totalBytes() > 0)
    }

    @Test func permanentFailureIsSkippedWithoutStallingDownload() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.absoluteString.contains("kartverket") == true {
                return (404, Data(), [:])
            }
            return (200, Self.tinyPNG, ["Content-Type": "image/png"])
        }
        let store = try makeStore()
        let downloader = OfflineRegionDownloader(store: store, session: makeStubSession())

        downloader.start(regionID: "r1", name: "Test", rect: tinyRect)
        await waitUntil({ downloader.status == .completed }, timeout: 10)

        #expect(downloader.status == .completed)
        #expect(downloader.tilesDone == downloader.tilesTotal)
        // Every position contributes one Lantmäteriet tile; Kartverket's 404s
        // were skipped rather than stored, so no tile has server code 0.
        let keys = store.existingTileKeys(regionID: "r1")
        #expect(!keys.isEmpty)
        #expect(keys.allSatisfy { $0.server == TileServer.lantmateriet.storeCode })
    }

    @Test func pauseStopsProgressAndResumeCompletes() async throws {
        StubURLProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 0.05) // slow enough to observe the paused state
            return (200, Self.tinyPNG, ["Content-Type": "image/png"])
        }
        let store = try makeStore()
        let downloader = OfflineRegionDownloader(store: store, session: makeStubSession())

        downloader.start(regionID: "r1", name: "Test", rect: tinyRect)
        downloader.pause()

        await waitUntil({ downloader.status == .paused }, timeout: 5)
        #expect(downloader.status == .paused)
        let doneWhilePaused = downloader.tilesDone
        #expect(doneWhilePaused < downloader.tilesTotal)

        downloader.resume()
        await waitUntil({ downloader.status == .completed }, timeout: 10)

        #expect(downloader.status == .completed)
        #expect(downloader.tilesDone == downloader.tilesTotal)
    }

    @Test func resumeAfterCancelSkipsAlreadyDownloadedTiles() async throws {
        StubURLProtocol.handler = { _ in (200, Self.tinyPNG, ["Content-Type": "image/png"]) }
        let store = try makeStore()
        let first = OfflineRegionDownloader(store: store, session: makeStubSession())

        first.start(regionID: "r1", name: "Test", rect: tinyRect)
        await waitUntil({ first.status == .completed }, timeout: 10)
        let bytesAfterFirstRun = store.totalBytes()

        // Restarting the same region id should see every tile already
        // present and finish immediately without re-fetching.
        let second = OfflineRegionDownloader(store: store, session: makeStubSession())
        second.start(regionID: "r1", name: "Test", rect: tinyRect)
        await waitUntil({ second.status == .completed }, timeout: 10)

        #expect(second.tilesDone == second.tilesTotal)
        #expect(store.totalBytes() == bytesAfterFirstRun)
    }
}

/// Thread-safe counter for stub handlers exercised by concurrent requests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
