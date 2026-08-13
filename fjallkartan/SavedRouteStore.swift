import Foundation

/// Persistent store for saved measurements, backed by one JSON file per route.
/// Per-file storage means saving, deleting or (eventually) syncing one route
/// can never corrupt or conflict with another — a route is write-once.
final class SavedRouteStore {
    private let directory: URL

    static var defaultDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("Routes", isDirectory: true)
    }

    init(directory: URL = SavedRouteStore.defaultDirectory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        try data.write(to: url(for: route.id), options: .atomic)
    }

    func delete(_ route: SavedRoute) {
        try? FileManager.default.removeItem(at: url(for: route.id))
    }
}
