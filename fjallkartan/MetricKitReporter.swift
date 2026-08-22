import MetricKit
import os

final class MetricKitReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitReporter()

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "fjallkartan", category: "MetricKit")

    private override init() {
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            log.info("MetricKit metric payload for \(payload.timeStampBegin, privacy: .public) – \(payload.timeStampEnd, privacy: .public)")
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
                log.error("MetricKit reported \(crashes.count, privacy: .public) crash diagnostic(s)")
            }
            if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
                log.error("MetricKit reported \(hangs.count, privacy: .public) hang diagnostic(s)")
            }
        }
    }
}
