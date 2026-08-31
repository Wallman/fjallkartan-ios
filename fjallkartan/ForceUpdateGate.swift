import Foundation
import Observation

@MainActor
@Observable
final class ForceUpdateGate {
    static let shared = ForceUpdateGate()
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id6798425234")!
    private(set) var isUpdateRequired = false
    private let currentVersion: String

    init(currentVersion: String = ForceUpdateGate.bundleVersion) {
        self.currentVersion = currentVersion
    }

    nonisolated static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    func evaluate(minAppVersion: String) {
        isUpdateRequired = AppVersion.isOlder(currentVersion, than: minAppVersion)
    }
}
