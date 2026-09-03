import Foundation
import Testing

@testable import fjallkartan

/// Each test opens its own throwaway database file so tests can run in
/// parallel and never see another test's rows.
private func makeStore() -> OfflineRegionsStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("OfflineRegionsStoreTests-\(UUID().uuidString).sqlite")
    return OfflineRegionsStore(url: url)
}

struct OfflineRegionsStoreTileTests {

    @Test func tileRoundTripsWrittenData() {
        let store = makeStore()
        let key = ElevationService.TileKey(x: 10, y: 20)

        #expect(!store.isTileCached(key))
        #expect(store.tileData(key) == nil)

        let payload = Data([1, 2, 3, 4])
        store.setTileData(key, data: payload)

        #expect(store.isTileCached(key))
        #expect(store.tileData(key) == payload)
    }

    @Test func absentSentinelIsCachedButEmpty() {
        let store = makeStore()
        let key = ElevationService.TileKey(x: 1, y: 1)

        store.setTileData(key, data: Data())

        #expect(store.isTileCached(key))
        #expect(store.tileData(key) == Data())
    }

    @Test func deleteRemovesAnUnreferencedTile() {
        let store = makeStore()
        let key = ElevationService.TileKey(x: 5, y: 5)
        store.setTileData(key, data: Data([9]))

        store.deleteTiles([key])

        #expect(!store.isTileCached(key))
        #expect(store.tileData(key) == nil)
    }

    @Test func overwritingATileReplacesItsData() {
        let store = makeStore()
        let key = ElevationService.TileKey(x: 2, y: 3)

        store.setTileData(key, data: Data([1]))
        store.setTileData(key, data: Data([2, 2]))

        #expect(store.tileData(key) == Data([2, 2]))
    }
}

struct OfflineRegionsStoreRegionTests {

    @Test func linkingTilesCreatesRowsAndProgressStartsAtZero() {
        let store = makeStore()
        let keys = [
            ElevationService.TileKey(x: 1, y: 1),
            ElevationService.TileKey(x: 1, y: 2),
        ]

        store.insertRegion(id: "region-a", name: "A", createdAt: Date())
        store.linkTiles(regionID: "region-a", keys: keys)

        let progress = store.regionProgress(id: "region-a")
        #expect(progress.count == 0)
        #expect(progress.bytes == 0)
        #expect(store.fetchedKeys(regionID: "region-a").isEmpty)
    }

    @Test func progressReflectsFetchedTiles() {
        let store = makeStore()
        let keys = [
            ElevationService.TileKey(x: 1, y: 1),
            ElevationService.TileKey(x: 1, y: 2),
        ]
        store.insertRegion(id: "region-a", name: "A", createdAt: Date())
        store.linkTiles(regionID: "region-a", keys: keys)

        store.setTileData(keys[0], data: Data([1, 2, 3]))

        let progress = store.regionProgress(id: "region-a")
        #expect(progress.count == 1)
        #expect(progress.bytes == 3)
        #expect(store.fetchedKeys(regionID: "region-a") == [keys[0]])
    }

    @Test func deletingARegionRemovesItsOwnUnsharedTiles() {
        let store = makeStore()
        let key = ElevationService.TileKey(x: 1, y: 1)
        store.insertRegion(id: "region-a", name: "A", createdAt: Date())
        store.linkTiles(regionID: "region-a", keys: [key])
        store.setTileData(key, data: Data([1]))

        store.deleteRegion(id: "region-a")

        #expect(!store.isTileCached(key))
    }

    /// The core ref-counting guarantee: two overlapping regions sharing a
    /// tile must not have that tile deleted out from under the survivor.
    @Test func sharedTilesSurviveDeletingOneOfTwoOverlappingRegions() {
        let store = makeStore()
        let shared = ElevationService.TileKey(x: 1, y: 1)
        let onlyInA = ElevationService.TileKey(x: 2, y: 2)

        store.insertRegion(id: "region-a", name: "A", createdAt: Date())
        store.insertRegion(id: "region-b", name: "B", createdAt: Date())
        store.linkTiles(regionID: "region-a", keys: [shared, onlyInA])
        store.linkTiles(regionID: "region-b", keys: [shared])
        store.setTileData(shared, data: Data([1]))
        store.setTileData(onlyInA, data: Data([2]))

        store.deleteRegion(id: "region-a")

        #expect(!store.isTileCached(onlyInA))
        #expect(store.isTileCached(shared))
        #expect(store.regionProgress(id: "region-b").count == 1)
    }

    @Test func mlnRegionIDAndSizeRoundTrip() {
        let store = makeStore()
        store.insertRegion(id: "region-a", name: "A", createdAt: Date())

        store.setMLNRegionID("region-a", mlnRegionID: 42)
        store.setSize("region-a", bytes: 12_345)

        #expect(store.regionID(forMLNRegionID: 42) == "region-a")
        #expect(store.size(for: "region-a") == 12_345)
    }

    @Test func wipeAllClearsEverything() {
        let store = makeStore()
        let key = ElevationService.TileKey(x: 1, y: 1)
        store.insertRegion(id: "region-a", name: "A", createdAt: Date())
        store.linkTiles(regionID: "region-a", keys: [key])
        store.setTileData(key, data: Data([1]))

        store.wipeAll()

        #expect(!store.isTileCached(key))
        #expect(store.regionProgress(id: "region-a").count == 0)
        #expect(store.regionID(forMLNRegionID: 42) == nil)
    }
}
