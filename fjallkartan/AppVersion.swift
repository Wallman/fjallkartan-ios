import Foundation

nonisolated enum AppVersion {
    static func isOlder(_ version: String, than minimum: String) -> Bool {
        let lhs = components(version)
        let rhs = components(minimum)
        let count = max(lhs.count, rhs.count)
        return pad(lhs, to: count).lexicographicallyPrecedes(pad(rhs, to: count))
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func pad(_ components: [Int], to count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }
}
