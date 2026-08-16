import Network

enum NetworkCheck {
    static func hasConnectivity() async -> Bool {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        return await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.resume(returning: path.status == .satisfied)
                monitor.pathUpdateHandler = nil
            }
            monitor.start(queue: DispatchQueue(label: "NetworkCheck"))
        }
    }
}
