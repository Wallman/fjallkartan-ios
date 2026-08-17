import CoreLocation
import Foundation
import Testing

@testable import fjallkartan

struct SavedPinStoreTests {
    private func makeStore() throws -> (SavedPinStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedPinStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (try SavedPinStore(directory: url), url)
    }

    private func makePin(name: String? = nil, createdAt: Date = Date()) -> SavedPin {
        SavedPin(createdAt: createdAt,
                coordinate: Coord(CLLocationCoordinate2D(latitude: 68.35, longitude: 18.83)),
                name: name)
    }

    @Test func saveAndLoadTripsExactly() throws {
        let (store, _) = try makeStore()
        let pin = makePin(name: "Kebnekaise")
        try store.save(pin)

        let loaded = try #require(store.load().first)
        #expect(loaded.id == pin.id)
        #expect(loaded.coordinate == pin.coordinate)
        #expect(loaded.name == pin.name)
        #expect(loaded.schemaVersion == pin.schemaVersion)
    }

    @Test func loadReturnsNewestFirst() throws {
        let (store, _) = try makeStore()
        let older = makePin(createdAt: Date(timeIntervalSinceNow: -3600))
        let newer = makePin(createdAt: Date())
        try store.save(older)
        try store.save(newer)

        let loaded = store.load()
        #expect(loaded.map(\.id) == [newer.id, older.id])
    }

    @Test func deleteRemovesOnlyThatPin() throws {
        let (store, _) = try makeStore()
        let a = makePin()
        let b = makePin()
        try store.save(a)
        try store.save(b)

        store.delete(a)

        let remaining = store.load()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == b.id)
    }

    @Test func renameOverwritesInPlace() throws {
        let (store, _) = try makeStore()
        let pin = makePin(name: "Old name")
        try store.save(pin)

        try store.rename(pin, to: "New name")

        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "New name")
        #expect(loaded.first?.id == pin.id)
    }

    @Test func renameToBlankClearsName() throws {
        let (store, _) = try makeStore()
        let pin = makePin(name: "Old name")
        try store.save(pin)

        try store.rename(pin, to: "   ")

        #expect(store.load().first?.name == nil)
    }

    @Test func corruptFileIsSkippedNotFatal() throws {
        let (store, directory) = try makeStore()
        try store.save(makePin())

        let garbage = directory.appendingPathComponent("not-a-pin.json")
        try Data("{ not valid json".utf8).write(to: garbage)

        #expect(store.load().count == 1)
    }
}
