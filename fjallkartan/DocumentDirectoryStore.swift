import Foundation

/// Generic persistent store for one-JSON-file-per-item collections (saved
/// routes, saved pins, …), local-first with optional iCloud Documents sync.
final class DocumentDirectoryStore<Item: Identifiable & Codable> where Item.ID == UUID {
    private(set) var directory: URL
    private let coordinator = NSFileCoordinator()
    private var metadataQuery: NSMetadataQuery?
    private var metadataObservers: [NSObjectProtocol] = []
    private(set) var isUsingiCloud = false
    private let subdirectoryName: String
    private let didMigrateToiCloudKey: String

    static func defaultLocalDirectory(subdirectoryName: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(subdirectoryName, isDirectory: true)
    }

    init(directory: URL, subdirectoryName: String, migrationKey: String) throws {
        self.directory = directory
        self.subdirectoryName = subdirectoryName
        self.didMigrateToiCloudKey = migrationKey
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        stopObservingRemoteChanges()
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    func load() -> [Item] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return urls.compactMap { url -> Item? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Item.self, from: data)
        }
    }

    func save(_ item: Item) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(item)

        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url(for: item.id), options: [], error: &coordinationError) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    func delete(_ item: Item) {
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url(for: item.id), options: .forDeleting, error: &coordinationError) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - iCloud

    func syncWithiCloudIfAvailable() async {
        guard let ubiquityDirectory = await resolveUbiquityDirectory() else { return }

        do {
            try FileManager.default.createDirectory(at: ubiquityDirectory, withIntermediateDirectories: true)
        } catch {
            return
        }

        if !UserDefaults.standard.bool(forKey: didMigrateToiCloudKey) {
            migrateLocalFiles(into: ubiquityDirectory)
            UserDefaults.standard.set(true, forKey: didMigrateToiCloudKey)
        }

        directory = ubiquityDirectory
        isUsingiCloud = true
    }

    private func resolveUbiquityDirectory() async -> URL? {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil } // when no iCloud account is signed in

        let subdirectoryName = subdirectoryName
        return await Task.detached(priority: .utility) {
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
            return container.appendingPathComponent("Documents/\(subdirectoryName)", isDirectory: true)
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

    /// Starts watching for items added/removed elsewhere
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
