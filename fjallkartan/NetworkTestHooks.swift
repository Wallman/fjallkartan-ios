import Foundation
import MapLibre

#if DEBUG
nonisolated enum NetworkTestHooks {
    static let isNetworkDisabled = ProcessInfo.processInfo.environment["UITEST_DISABLE_NETWORK"] == "1"

    @MainActor
    static func installIfNeeded() {
        guard isNetworkDisabled else { return }
        URLProtocol.registerClass(BlockingURLProtocol.self)
        let config = URLSessionConfiguration.default
        config.protocolClasses = [BlockingURLProtocol.self] + (config.protocolClasses ?? [])
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = config
    }
}

extension URLSessionConfiguration {
    nonisolated func uitestAware() -> URLSessionConfiguration {
        guard NetworkTestHooks.isNetworkDisabled else { return self }
        protocolClasses = [BlockingURLProtocol.self] + (protocolClasses ?? [])
        return self
    }
}

private final class BlockingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
#else
nonisolated enum NetworkTestHooks {
    static let isNetworkDisabled = false
    @MainActor static func installIfNeeded() {}
}

extension URLSessionConfiguration {
    nonisolated func uitestAware() -> URLSessionConfiguration { self }
}
#endif
