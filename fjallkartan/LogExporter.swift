import Foundation
import OSLog

nonisolated enum LogExporter {
    enum ExportError: Error {
        case noEntries
    }

    static let mapLibreSubsystem = "org.maplibre"

    static func exportLogs(since: TimeInterval = 60 * 60 * 24) throws -> URL {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(timeIntervalSinceLatestBoot: -since)
        let ownSubsystem = Bundle.main.bundleIdentifier ?? "fjallkartan"
        let entries = try store.getEntries(at: position)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == ownSubsystem || $0.subsystem == mapLibreSubsystem }

        guard !entries.isEmpty else { throw ExportError.noEntries }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)

        let text = entries
            .map { "\(formatter.string(from: $0.date)) [\($0.category)] \(levelSymbol($0.level)) \($0.composedMessage)" }
            .joined(separator: "\n")

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fjallkartan-logs-\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension("log")
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private static func levelSymbol(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        case .undefined: return "?"
        @unknown default: return "?"
        }
    }
}
