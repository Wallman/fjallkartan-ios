import Foundation

final class SavedPinStore {
    private let base: DocumentDirectoryStore<SavedPin>

    private static let didMigrateToiCloudKey = "SavedPinStore.didMigrateToiCloud"

    static var defaultLocalDirectory: URL {
        DocumentDirectoryStore<SavedPin>.defaultLocalDirectory(subdirectoryName: "Pins")
    }

    var directory: URL { base.directory }
    var isUsingiCloud: Bool { base.isUsingiCloud }

    init(directory: URL = SavedPinStore.defaultLocalDirectory) throws {
        base = try DocumentDirectoryStore(directory: directory,
                                          subdirectoryName: "Pins",
                                          migrationKey: Self.didMigrateToiCloudKey)
    }

    func load() -> [SavedPin] {
        base.load().sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ pin: SavedPin) throws {
        try base.save(pin)
    }

    func delete(_ pin: SavedPin) {
        base.delete(pin)
    }

    func rename(_ pin: SavedPin, to name: String) throws {
        var updated = pin
        updated.name = name.isEmpty ? nil : name
        try base.save(updated)
    }

    func syncWithiCloudIfAvailable() async {
        await base.syncWithiCloudIfAvailable()
    }

    func startObservingRemoteChanges(onChange: @escaping () -> Void) {
        base.startObservingRemoteChanges(onChange: onChange)
    }

    func stopObservingRemoteChanges() {
        base.stopObservingRemoteChanges()
    }
}
