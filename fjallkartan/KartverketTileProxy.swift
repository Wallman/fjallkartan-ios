import Foundation
import Network
import OSLog
import UIKit

nonisolated final class KartverketTileProxy: @unchecked Sendable {
    /// Kartverket's no-data fill is transparent at low zoom but an opaque
    /// cream (255,255,230) from ~z15. Converts it to transparent.
    enum NoDataFill {
        static func rewritten(_ data: Data?) -> Data? {
            guard let data, let cg = UIImage(data: data)?.cgImage else { return data }
            let w = cg.width, h = cg.height
            guard w > 0, h > 0 else { return data }
            let bytesPerRow = w * 4
            var buf = [UInt8](repeating: 0, count: h * bytesPerRow)
            let space = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: &buf, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return data
            }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var rewroteAnyPixel = false
            var i = 0
            while i < buf.count {
                if buf[i] > 250, buf[i + 1] > 250, buf[i + 2] >= 222, buf[i + 2] <= 240 {
                    buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; buf[i + 3] = 0
                    rewroteAnyPixel = true
                }
                i += 4
            }
            guard rewroteAnyPixel else { return data }
            guard let out = ctx.makeImage() else { return data }
            return UIImage(cgImage: out).pngData() ?? data
        }
    }

    /// `nil` if the local listener could not be started (e.g. some sandboxed
    /// CI environment); callers should fall back to Kartverket's real URL,
    /// which only loses the cream-fill fix, not the map itself.
    static let shared = KartverketTileProxy()

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "fjallkartan",
                                    category: "KartverketTileProxy")

    private let upstreamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static let port: NWEndpoint.Port = 58355

    private let listener: NWListener

    private init?() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: params, on: Self.port) else {
            Self.log.error("could not create Kartverket tile proxy listener")
            return nil
        }
        self.listener = listener

        let semaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
        _ = semaphore.wait(timeout: .now() + 5)

        guard listener.state == .ready else {
            Self.log.error("Kartverket tile proxy listener never became ready")
            listener.cancel()
            return nil
        }
        Self.log.debug("Kartverket tile proxy listening on 127.0.0.1:\(Self.port.rawValue)")
    }

    var tileURLTemplate: String {
        "http://127.0.0.1:\(Self.port.rawValue)/{z}/{x}/{y}.png"
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffered = buffered
            if let data { buffered.append(data) }

            if let range = buffered.range(of: Data("\r\n\r\n".utf8)) {
                self.handleRequest(headerData: buffered[..<range.lowerBound], on: connection)
                return
            }
            guard error == nil, !isComplete, buffered.count < 8192 else {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffered: buffered)
        }
    }

    private static let rewriteMinimumZoom = 15

    private func handleRequest(headerData: Data, on connection: NWConnection) {
        guard let headerText = String(data: headerData, encoding: .utf8),
              let requestLine = headerText.split(separator: "\r\n").first,
              let path = requestLine.split(separator: " ").dropFirst().first,
              let tile = Self.parseTile(from: String(path)) else {
            respond(status: "400 Bad Request", body: nil, contentType: nil, on: connection)
            return
        }

        let upstreamURL = RemoteSettings.shared.tileURL(server: .kartverket, z: tile.z, x: tile.x, y: tile.y)
        let shouldRewrite = tile.z >= Self.rewriteMinimumZoom
        upstreamSession.dataTask(with: upstreamURL) { [weak self] data, response, error in
            guard let self else { return }
            guard let http = response as? HTTPURLResponse else {
                // No HTTP response at all (e.g. connectivity loss)
                Self.log.error("Kartverket tile \(tile.z, privacy: .public)/\(tile.x, privacy: .public)/\(tile.y, privacy: .public) fetch failed: \(error?.localizedDescription ?? "no response", privacy: .public)")
                self.respond(status: "503 Service Unavailable", body: nil, contentType: nil, on: connection)
                return
            }
            guard (200...299).contains(http.statusCode), let data, error == nil else {
                if Self.isRetryable(status: http.statusCode) {
                    // Forward throttling/server errors as-is
                    Self.log.warning("Kartverket tile \(tile.z, privacy: .public)/\(tile.x, privacy: .public)/\(tile.y, privacy: .public) upstream status \(http.statusCode, privacy: .public)")
                    self.respond(status: "\(http.statusCode) \(Self.reasonPhrase(for: http.statusCode))",
                                 body: nil, contentType: nil, on: connection)
                } else {
                    self.respond(status: "404 Not Found", body: nil, contentType: nil, on: connection)
                }
                return
            }
            let rewritten = shouldRewrite ? (NoDataFill.rewritten(data) ?? data) : data
            self.respond(status: "200 OK", body: rewritten, contentType: "image/png",
                         cacheHeaders: Self.cacheHeaders(from: http), on: connection)
        }.resume()
    }

    private static let forwardedCacheHeaderNames = ["Date", "Cache-Control", "ETag", "Last-Modified", "Expires"]

    private static func cacheHeaders(from response: HTTPURLResponse) -> [(String, String)] {
        forwardedCacheHeaderNames.compactMap { name in
            response.value(forHTTPHeaderField: name).map { (name, $0) }
        }
    }

    private func respond(status: String, body: Data?, contentType: String?,
                          cacheHeaders: [(String, String)] = [], on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        if let contentType, let body {
            head += "Content-Type: \(contentType)\r\n"
            head += "Content-Length: \(body.count)\r\n"
        } else {
            head += "Content-Length: 0\r\n"
        }
        for (name, value) in cacheHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        if let body { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func isRetryable(status: Int) -> Bool {
        status == 429 || status >= 500
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Error"
        }
    }

    private static func parseTile(from path: String) -> (z: Int, x: Int, y: Int)? {
        var trimmed = Substring(path)
        if trimmed.hasPrefix("/") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix(".png") { trimmed = trimmed.dropLast(4) }
        let parts = trimmed.split(separator: "/")
        guard parts.count == 3,
              let z = Int(parts[0]), let x = Int(parts[1]), let y = Int(parts[2]) else { return nil }
        return (z, x, y)
    }
}
