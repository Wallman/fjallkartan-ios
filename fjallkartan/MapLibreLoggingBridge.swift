import MapLibre
import os

/// Routes MapLibre's own internal logging (tile/network failures, style
/// errors, etc.) into our unified-logging subsystem so it's captured by
/// `LogExporter` — MapLibre logs under its own handler by default and isn't
/// otherwise visible there. In particular this is what surfaces "couldn't
/// fetch tile" HTTP errors, which MapLibre logs but never reports through
/// `MLNMapViewDelegate`.
enum MapLibreLoggingBridge {
    private static let log = Logger(subsystem: LogExporter.mapLibreSubsystem, category: "MapLibre")

    static func start() {
        MLNLoggingConfiguration.shared.loggingLevel = .warning
        MLNLoggingConfiguration.shared.handler = { level, filePath, line, message in
            switch level {
            case .warning:
                log.warning("\(filePath, privacy: .public):\(line, privacy: .public) \(message, privacy: .public)")
            case .error:
                log.error("\(filePath, privacy: .public):\(line, privacy: .public) \(message, privacy: .public)")
            default:
                log.notice("\(filePath, privacy: .public):\(line, privacy: .public) \(message, privacy: .public)")
            }
        }
    }
}
