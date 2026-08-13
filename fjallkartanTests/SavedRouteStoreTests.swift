import CoreLocation
import Foundation
import Testing

@testable import fjallkartan

struct SavedRouteStoreTests {
    private func makeStore() throws -> (SavedRouteStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedRouteStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (try SavedRouteStore(directory: url), url)
    }

    private func makeRoute(meters: Double = 1500, createdAt: Date = Date()) -> SavedRoute {
        SavedRoute(createdAt: createdAt,
                  meters: meters,
                  coordinates: [
                    .init(CLLocationCoordinate2D(latitude: 68.35, longitude: 18.83)),
                    .init(CLLocationCoordinate2D(latitude: 68.36, longitude: 18.83)),
                  ],
                  strokeSizes: [2])
    }

    @Test func saveAndLoadRoundTripsExactly() throws {
        let (store, _) = try makeStore()
        let route = makeRoute()
        try store.save(route)

        let loaded = try #require(store.load().first)
        #expect(loaded.id == route.id)
        #expect(loaded.meters == route.meters)
        #expect(loaded.coordinates == route.coordinates)
        #expect(loaded.strokeSizes == route.strokeSizes)
        #expect(loaded.schemaVersion == route.schemaVersion)
    }

    @Test func loadReturnsNewestFirst() throws {
        let (store, _) = try makeStore()
        let older = makeRoute(createdAt: Date(timeIntervalSinceNow: -3600))
        let newer = makeRoute(createdAt: Date())
        try store.save(older)
        try store.save(newer)

        let loaded = store.load()
        #expect(loaded.map(\.id) == [newer.id, older.id])
    }

    @Test func deleteRemovesOnlyThatRoute() throws {
        let (store, _) = try makeStore()
        let a = makeRoute()
        let b = makeRoute()
        try store.save(a)
        try store.save(b)

        store.delete(a)

        let remaining = store.load()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == b.id)
    }

    @Test func corruptFileIsSkippedNotFatal() throws {
        let (store, directory) = try makeStore()
        try store.save(makeRoute())

        let garbage = directory.appendingPathComponent("not-a-route.json")
        try Data("{ not valid json".utf8).write(to: garbage)

        #expect(store.load().count == 1)
    }

    @Test func nonJSONFilesInDirectoryAreIgnored() throws {
        let (store, directory) = try makeStore()
        try store.save(makeRoute())

        let stray = directory.appendingPathComponent("readme.txt")
        try Data("hello".utf8).write(to: stray)

        #expect(store.load().count == 1)
    }
}
