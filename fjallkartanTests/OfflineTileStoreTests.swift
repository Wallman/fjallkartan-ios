import Foundation
import Testing

@testable import fjallkartan

struct OfflineTileStoreTests {
    private func makeStore() throws -> (OfflineTileStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineTileStoreTests-\(UUID().uuidString).sqlite")
        return (try OfflineTileStore(url: url), url)
    }

    @Test func putAndGetRoundTripsExactBytes() throws {
        let (store, _) = try makeStore()
        let data = Data([1, 2, 3, 4])
        try store.putTiles([.init(server: 0, z: 10, x: 5, y: 6, data: data)], regionID: "r1")
        #expect(store.tileData(server: 0, z: 10, x: 5, y: 6) == data)
    }

    @Test func storeDirectoryIsExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineTileStoreBackup-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("offline-tiles.sqlite")
        let store = try OfflineTileStore(url: url)
        try store.putTiles([.init(server: 0, z: 10, x: 1, y: 1, data: Data([0xAB]))], regionID: "r1")

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
    }

    @Test func missReturnsNil() throws {
        let (store, _) = try makeStore()
        #expect(store.tileData(server: 0, z: 10, x: 1, y: 1) == nil)
    }

    @Test func sameTileDifferentServersAreDistinct() throws {
        let (store, _) = try makeStore()
        try store.putTiles([
            .init(server: 0, z: 10, x: 1, y: 1, data: Data([0xAA])),
            .init(server: 1, z: 10, x: 1, y: 1, data: Data([0xBB])),
        ], regionID: "r1")
        #expect(store.tileData(server: 0, z: 10, x: 1, y: 1) == Data([0xAA]))
        #expect(store.tileData(server: 1, z: 10, x: 1, y: 1) == Data([0xBB]))
    }

    @Test func nearestAncestorWalksUpToStoredTile() throws {
        let (store, _) = try makeStore()
        // Store only a z9 tile; ask for its z12 descendant.
        try store.putTiles([.init(server: 0, z: 9, x: 3, y: 4, data: Data([9]))], regionID: "r1")
        let ancestor = store.nearestAncestorTile(server: 0, z: 12, x: 3 * 8, y: 4 * 8)
        #expect(ancestor?.z == 9)
        #expect(ancestor?.x == 3)
        #expect(ancestor?.y == 4)
        #expect(ancestor?.data == Data([9]))
    }

    @Test func nearestAncestorReturnsNilWhenNoneStored() throws {
        let (store, _) = try makeStore()
        #expect(store.nearestAncestorTile(server: 0, z: 12, x: 0, y: 0) == nil)
    }

    @Test func createRegionAndUpdateProgress() throws {
        let (store, _) = try makeStore()
        try store.createRegion(id: "r1", name: "Abisko",
                               minLat: 68.0, minLon: 18.0, maxLat: 68.5, maxLon: 19.0,
                               minZ: 7, maxZ: 13, tileTotal: 100)
        try store.updateRegionProgress(id: "r1", tileDone: 50, bytes: 1_000_000, status: .downloading)

        let regions = store.regions()
        #expect(regions.count == 1)
        #expect(regions[0].id == "r1")
        #expect(regions[0].name == "Abisko")
        #expect(regions[0].tileDone == 50)
        #expect(regions[0].bytes == 1_000_000)
        #expect(regions[0].status == .downloading)
    }

    @Test func existingTileKeysReflectsWrittenTiles() throws {
        let (store, _) = try makeStore()
        try store.putTiles([
            .init(server: 0, z: 10, x: 1, y: 1, data: Data([1])),
            .init(server: 1, z: 10, x: 1, y: 1, data: Data([2])),
        ], regionID: "r1")
        let keys = store.existingTileKeys(regionID: "r1")
        #expect(keys.count == 2)
        #expect(keys.contains(.init(server: 0, z: 10, x: 1, y: 1)))
        #expect(keys.contains(.init(server: 1, z: 10, x: 1, y: 1)))
    }

    @Test func deleteRegionRemovesExclusiveTilesButKeepsSharedOnes() throws {
        let (store, _) = try makeStore()
        // Tile A is exclusive to r1; tile B is shared by r1 and r2.
        try store.putTiles([.init(server: 0, z: 10, x: 1, y: 1, data: Data([1]))], regionID: "r1")
        try store.putTiles([.init(server: 0, z: 10, x: 2, y: 2, data: Data([2]))], regionID: "r1")
        try store.putTiles([.init(server: 0, z: 10, x: 2, y: 2, data: Data([2]))], regionID: "r2")
        try store.createRegion(id: "r1", name: "R1", minLat: 0, minLon: 0, maxLat: 1, maxLon: 1,
                               minZ: 7, maxZ: 13, tileTotal: 2)
        try store.createRegion(id: "r2", name: "R2", minLat: 0, minLon: 0, maxLat: 1, maxLon: 1,
                               minZ: 7, maxZ: 13, tileTotal: 1)

        try store.deleteRegion(id: "r1")

        #expect(store.tileData(server: 0, z: 10, x: 1, y: 1) == nil) // exclusive tile gone
        #expect(store.tileData(server: 0, z: 10, x: 2, y: 2) == Data([2])) // shared tile kept
        #expect(store.regions().map(\.id) == ["r2"])
    }

    @Test func totalBytesSumsDistinctTilesOnly() throws {
        let (store, _) = try makeStore()
        try store.putTiles([
            .init(server: 0, z: 10, x: 1, y: 1, data: Data(repeating: 0, count: 10)),
            .init(server: 0, z: 10, x: 2, y: 2, data: Data(repeating: 0, count: 20)),
        ], regionID: "r1")
        #expect(store.totalBytes() == 30)
    }

    @Test func putTilesOverwritesExistingTileData() throws {
        let (store, _) = try makeStore()
        try store.putTiles([.init(server: 0, z: 10, x: 1, y: 1, data: Data([1, 2]))], regionID: "r1")
        try store.putTiles([.init(server: 0, z: 10, x: 1, y: 1, data: Data([3, 4, 5]))], regionID: "r1")
        #expect(store.tileData(server: 0, z: 10, x: 1, y: 1) == Data([3, 4, 5]))
        #expect(store.totalBytes() == 3)
    }
}
