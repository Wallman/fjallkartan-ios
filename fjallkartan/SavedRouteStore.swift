import Foundation

/// Persistent store for saved measurements, backed by one JSON file per
/// route rather than a single manifest or database.
///
/// Per-file storage means saving, deleting or syncing one route can never
/// corrupt or conflict with another — a route is write-once from the user's
/// perspective (create, list, delete; no rename or edit).
final class SavedRouteStore {
    private(set) var directory: URL
    private let coordinator = NSFileCoordinator()
    private var metadataQuery: NSMetadataQuery?
    private var metadataObservers: [NSObjectProtocol] = []
    private(set) var isUsingiCloud = false

    private static let didMigrateToiCloudKey = "SavedRouteStore.didMigrateToiCloud"

    static var defaultLocalDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("Routes", isDirectory: true)
    }

    init(directory: URL = SavedRouteStore.defaultLocalDirectory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        stopObservingRemoteChanges()
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    func load() -> [SavedRoute] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let routes = urls.compactMap { url -> SavedRoute? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(SavedRoute.self, from: data)
        }
        return routes.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ route: SavedRoute) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(route)

        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url(for: route.id), options: [], error: &coordinationError) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    func delete(_ route: SavedRoute) {
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url(for: route.id), options: .forDeleting, error: &coordinationError) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - iCloud

    /// Repoints the store at the iCloud "Routes" folder if iCloud Documents
    /// is available for this app, migrating any pre-existing local files
    /// there the first time this succeeds.
    func syncWithiCloudIfAvailable() async {
        guard let ubiquityDirectory = await Self.resolveUbiquityRoutesDirectory() else { return }

        do {
            try FileManager.default.createDirectory(at: ubiquityDirectory, withIntermediateDirectories: true)
        } catch {
            return
        }

        if !UserDefaults.standard.bool(forKey: Self.didMigrateToiCloudKey) {
            migrateLocalFiles(into: ubiquityDirectory)
            UserDefaults.standard.set(true, forKey: Self.didMigrateToiCloudKey)
        }

        directory = ubiquityDirectory
        isUsingiCloud = true
    }

    private static func resolveUbiquityRoutesDirectory() async -> URL? {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil } // when no iCloud account is signed in

        return await Task.detached(priority: .utility) {
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
            return container.appendingPathComponent("Documents/Routes", isDirectory: true)
        }.value
    }

    private func migrateLocalFiles(into ubiquityDirectory: URL) {
        guard directory != ubiquityDirectory else { return }
        let localFiles = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        for localURL in localFiles where localURL.pathExtension == "json" {
            let destination = ubiquityDirectory.appendingPathComponent(localURL.lastPathComponent)
            guard let data = try? Data(contentsOf: localURL) else { continue }

            var coordinationError: NSError?
            var succeeded = false
            coordinator.coordinate(writingItemAt: destination, options: [], error: &coordinationError) { url in
                succeeded = (try? data.write(to: url, options: .atomic)) != nil
            }
            if succeeded {
                try? FileManager.default.removeItem(at: localURL)
            }
        }
    }

    // MARK: - Remote change observation

    /// Starts watching for routes added/removed elsewhere
    func startObservingRemoteChanges(onChange: @escaping () -> Void) {
        guard isUsingiCloud else { return }

        stopObservingRemoteChanges()

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.json'", NSMetadataItemFSNameKey)
        query.operationQueue = .main

        let handler: (Notification) -> Void = { [weak query] _ in
            query?.disableUpdates()
            onChange()
            query?.enableUpdates()
        }
        metadataObservers = [
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                    object: query, queue: .main, using: handler),
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate,
                                                    object: query, queue: .main, using: handler),
        ]
        metadataQuery = query
        query.start()
    }

    func stopObservingRemoteChanges() {
        metadataQuery?.stop()
        metadataQuery = nil
        metadataObservers.forEach(NotificationCenter.default.removeObserver)
        metadataObservers.removeAll()
    }
}
