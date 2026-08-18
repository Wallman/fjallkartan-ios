import Foundation
import MapKit
import Testing
import UIKit

@testable import fjallkartan

/// Deliberately *not* `TileFetcherStubURLProtocol`: that one keeps a global
/// request counter which `TileFetcherTests` asserts on, and separate suites run
/// in parallel, so sharing it would make both suites flaky.
final class OverlayStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _response: (status: Int, data: Data, headers: [String: String])?
    nonisolated(unsafe) private static var _error: URLError?

    nonisolated(unsafe) private static var _lastURL: URL?

    static var lastURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return _lastURL
    }

    static func stub(status: Int, data: Data, headers: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        _response = (status, data, headers)
        _error = nil
        _lastURL = nil
    }

    static func stub(error: URLError) {
        lock.lock(); defer { lock.unlock() }
        _response = nil
        _error = error
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let response = Self._response
        let error = Self._error
        Self._lastURL = request.url
        Self.lock.unlock()

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status,
                                   httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct CustomTileOverlayTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47])
    private static let imageHeaders = ["Content-Type": "image/png"]

    /// A real 256×256 PNG, needed wherever a tile is actually decoded.
    @MainActor private static let opaquePNG: Data = {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor.green.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }()

    private func makeOverlay(server: TileServer = .lantmateriet) -> CustomTileOverlay {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OverlayStubURLProtocol.self]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        var configuration = TileFetcher.Configuration()
        configuration.initialRetryDelay = 0.01
        configuration.connectivityRetryDelay = 0.01
        let fetcher = TileFetcher(session: URLSession(configuration: config),
                                  storesResponses: false, configuration: configuration)
        return CustomTileOverlay(server: server, fetcher: fetcher)
    }

    @MainActor
    private func loadTile(_ overlay: CustomTileOverlay,
                          path: MKTileOverlayPath = MKTileOverlayPath(x: 1, y: 1, z: 10,
                                                                      contentScaleFactor: 1)) async -> (data: Data?, error: Error?) {
        await withCheckedContinuation { continuation in
            overlay.loadTile(at: path) { data, error in
                continuation.resume(returning: (data, error))
            }
        }
    }

    /// The regression: a tile that failed to reach the server used to be
    /// reported as `(nil, nil)`, which MapKit reads as "legitimately empty" and
    /// caches — so one failed request left a permanent hole in the map.
    @Test func transportFailureIsReportedAsAnError() async {
        OverlayStubURLProtocol.stub(error: URLError(.notConnectedToInternet))

        let (data, error) = await loadTile(makeOverlay())

        #expect(data == nil)
        #expect(error != nil)
    }

    @Test func serverErrorIsReportedAsAnError() async {
        OverlayStubURLProtocol.stub(status: 503, data: Data(), headers: [:])

        let (data, error) = await loadTile(makeOverlay())

        #expect(data == nil)
        #expect(error != nil)
    }

    /// The other half: a tile the server simply doesn't publish must stay
    /// `(nil, nil)`, or MapKit would re-request empty ocean tiles forever.
    @Test func missingTileIsReportedAsEmpty() async {
        OverlayStubURLProtocol.stub(status: 404, data: Data(), headers: [:])

        let (data, error) = await loadTile(makeOverlay())

        #expect(data == nil)
        #expect(error == nil)
    }

    @Test func successfulTileIsPassedThrough() async {
        OverlayStubURLProtocol.stub(status: 200, data: Self.png, headers: Self.imageHeaders)

        let (data, error) = await loadTile(makeOverlay())

        #expect(data == Self.png)
        #expect(error == nil)
    }

    /// Lantmäteriet publishes to z16, so a deeper tile must be served by
    /// magnifying its z16 ancestor rather than requesting a level that 404s.
    @MainActor
    @Test func deepTileIsUpscaledFromTheDeepestPublishedAncestor() async {
        OverlayStubURLProtocol.stub(status: 200, data: Self.opaquePNG, headers: Self.imageHeaders)

        let (data, error) = await loadTile(makeOverlay(),
                                           path: MKTileOverlayPath(x: 33_000, y: 17_000, z: 18,
                                                                   contentScaleFactor: 1))

        #expect(error == nil)
        #expect(data != nil)
        let requested = OverlayStubURLProtocol.lastURL?.absoluteString ?? ""
        #expect(requested.contains("/16/"))
        #expect(requested.contains("\(17_000 >> 2)"))
        #expect(requested.contains("\(33_000 >> 2)"))
    }
}
