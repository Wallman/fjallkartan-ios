import Foundation

final class SavedRouteStore {
    private let base: DocumentDirectoryStore<SavedRoute>

    private static let didMigrateToiCloudKey = "SavedRouteStore.didMigrateToiCloud"

    static var defaultLocalDirectory: URL {
        DocumentDirectoryStore<SavedRoute>.defaultLocalDirectory(subdirectoryName: "Routes")
    }

    var directory: URL { base.directory }
    var isUsingiCloud: Bool { base.isUsingiCloud }

    init(directory: URL = SavedRouteStore.defaultLocalDirectory) throws {
        base = try DocumentDirectoryStore(directory: directory,
                                          subdirectoryName: "Routes",
                                          migrationKey: Self.didMigrateToiCloudKey)
    }

    func load() -> [SavedRoute] {
        base.load().sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ route: SavedRoute) throws {
        try base.save(route)
    }

    func delete(_ route: SavedRoute) {
        base.delete(route)
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
