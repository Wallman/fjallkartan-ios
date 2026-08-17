import Foundation
import SQLite3

/// Persistent on-disk store for downloaded tiles, used both to serve tiles
/// while offline (`CustomTileOverlay`) and to track region download progress
/// (`OfflineRegionDownloader`).
///
/// Backed by SQLite rather than one file per tile: with 60k+ tiles in a
/// typical region, individual files are pathological on iOS, and SQLite gives
/// atomic refcounted deletes (`deleteRegion`) for free. Every fetched tile is stored verbatim.
nonisolated final class OfflineTileStore {
    static let shared = try? OfflineTileStore()

    enum RegionStatus: String {
        case downloading, paused, complete, failed
    }

    struct RegionSummary: Identifiable, Hashable {
        let id: String
        let name: String
        let minLat, minLon, maxLat, maxLon: Double
        let minZ, maxZ: Int
        let tileTotal, tileDone: Int
        let bytes: Int
        let status: RegionStatus
        let createdAt: Date
    }

    struct TileKey: Hashable {
        let server: Int
        let z, x, y: Int
    }

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "OfflineTileStore")

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("OfflineTiles", isDirectory: true)
            .appendingPathComponent("offline-tiles.sqlite")
    }

    private static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static var availableCapacityBytes: Int? {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return Int(capacity)
        }
        let fallback = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return fallback?.volumeAvailableCapacity
    }

    init(url: URL = OfflineTileStore.defaultURL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw StoreError.openFailed(message)
        }

        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try createSchema()
    }

    deinit {
        sqlite3_close(handle)
    }

    enum StoreError: Error {
        case openFailed(String)
        case execFailed(String)
    }

    // MARK: - Schema

    private func createSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS tiles (
                server INTEGER NOT NULL,
                z INTEGER NOT NULL,
                x INTEGER NOT NULL,
                y INTEGER NOT NULL,
                data BLOB NOT NULL,
                bytes INTEGER NOT NULL,
                PRIMARY KEY (server, z, x, y)
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS region_tiles (
                region_id TEXT NOT NULL,
                server INTEGER NOT NULL,
                z INTEGER NOT NULL,
                x INTEGER NOT NULL,
                y INTEGER NOT NULL,
                PRIMARY KEY (region_id, server, z, x, y)
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS region_tiles_tile ON region_tiles(server, z, x, y)")
        try exec("""
            CREATE TABLE IF NOT EXISTS regions (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                min_lat REAL NOT NULL,
                min_lon REAL NOT NULL,
                max_lat REAL NOT NULL,
                max_lon REAL NOT NULL,
                min_z INTEGER NOT NULL,
                max_z INTEGER NOT NULL,
                tile_total INTEGER NOT NULL,
                tile_done INTEGER NOT NULL DEFAULT 0,
                bytes INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    // MARK: - Tile lookup (read path, called from CustomTileOverlay)

    /// Exact tile lookup. Returns nil on a miss.
    func tileData(server: Int, z: Int, x: Int, y: Int) -> Data? {
        queue.sync {
            let sql = "SELECT data FROM tiles WHERE server=? AND z=? AND x=? AND y=?"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_int(statement, 1, Int32(server))
            sqlite3_bind_int(statement, 2, Int32(z))
            sqlite3_bind_int(statement, 3, Int32(x))
            sqlite3_bind_int(statement, 4, Int32(y))
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let length = Int(sqlite3_column_bytes(statement, 0))
            return Data(bytes: bytes, count: length)
        }
    }

    /// Walks up the pyramid from `(z,x,y)` towards `TilePyramid.minZoom` looking for the nearest stored ancestor.
    func nearestAncestorTile(server: Int, z: Int, x: Int, y: Int) -> (z: Int, x: Int, y: Int, data: Data)? {
        var az = z, ax = x, ay = y
        while az > TilePyramid.minZoom {
            az -= 1
            ax /= 2
            ay /= 2
            if let data = tileData(server: server, z: az, x: ax, y: ay) {
                return (az, ax, ay, data)
            }
        }
        return nil
    }

    // MARK: - Writes (download path, called from OfflineRegionDownloader)

    struct PendingTile {
        let server: Int
        let z, x, y: Int
        let data: Data
    }

    /// Inserts a batch of tiles plus their `region_tiles` membership rows in one transaction.
    func putTiles(_ tiles: [PendingTile], regionID: String) throws {
        guard !tiles.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE")
            do {
                let tileSQL = "INSERT OR REPLACE INTO tiles (server,z,x,y,data,bytes) VALUES (?,?,?,?,?,?)"
                let regionSQL = "INSERT OR IGNORE INTO region_tiles (region_id,server,z,x,y) VALUES (?,?,?,?,?)"
                var tileStatement: OpaquePointer?
                var regionStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, tileSQL, -1, &tileStatement, nil) == SQLITE_OK,
                      sqlite3_prepare_v2(handle, regionSQL, -1, &regionStatement, nil) == SQLITE_OK else {
                    throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
                }
                defer {
                    sqlite3_finalize(tileStatement)
                    sqlite3_finalize(regionStatement)
                }

                for tile in tiles {
                    sqlite3_reset(tileStatement)
                    sqlite3_clear_bindings(tileStatement)
                    sqlite3_bind_int(tileStatement, 1, Int32(tile.server))
                    sqlite3_bind_int(tileStatement, 2, Int32(tile.z))
                    sqlite3_bind_int(tileStatement, 3, Int32(tile.x))
                    sqlite3_bind_int(tileStatement, 4, Int32(tile.y))
                    tile.data.withUnsafeBytes { raw in
                        _ = sqlite3_bind_blob(tileStatement, 5, raw.baseAddress, Int32(tile.data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                    sqlite3_bind_int(tileStatement, 6, Int32(tile.data.count))
                    guard sqlite3_step(tileStatement) == SQLITE_DONE else {
                        throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
                    }

                    sqlite3_reset(regionStatement)
                    sqlite3_clear_bindings(regionStatement)
                    sqlite3_bind_text(regionStatement, 1, regionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_int(regionStatement, 2, Int32(tile.server))
                    sqlite3_bind_int(regionStatement, 3, Int32(tile.z))
                    sqlite3_bind_int(regionStatement, 4, Int32(tile.x))
                    sqlite3_bind_int(regionStatement, 5, Int32(tile.y))
                    guard sqlite3_step(regionStatement) == SQLITE_DONE else {
                        throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
                    }
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Tile keys already present for `regionID`, so a resumed download can skip rows it already fetched.
    func existingTileKeys(regionID: String) -> Set<TileKey> {
        queue.sync {
            let sql = "SELECT server,z,x,y FROM region_tiles WHERE region_id=?"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(statement, 1, regionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            var keys: Set<TileKey> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                keys.insert(TileKey(server: Int(sqlite3_column_int(statement, 0)),
                                    z: Int(sqlite3_column_int(statement, 1)),
                                    x: Int(sqlite3_column_int(statement, 2)),
                                    y: Int(sqlite3_column_int(statement, 3))))
            }
            return keys
        }
    }

    // MARK: - Regions

    func createRegion(id: String, name: String,
                      minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
                      minZ: Int, maxZ: Int, tileTotal: Int) throws {
        try queue.sync {
            let sql = """
                INSERT OR REPLACE INTO regions
                    (id,name,min_lat,min_lon,max_lat,max_lon,min_z,max_z,tile_total,tile_done,bytes,status,created_at)
                VALUES (?,?,?,?,?,?,?,?,?,0,0,?,?)
                """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(statement, 3, minLat)
            sqlite3_bind_double(statement, 4, minLon)
            sqlite3_bind_double(statement, 5, maxLat)
            sqlite3_bind_double(statement, 6, maxLon)
            sqlite3_bind_int(statement, 7, Int32(minZ))
            sqlite3_bind_int(statement, 8, Int32(maxZ))
            sqlite3_bind_int(statement, 9, Int32(tileTotal))
            sqlite3_bind_text(statement, 10, RegionStatus.downloading.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(statement, 11, Date().timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func updateRegionProgress(id: String, tileDone: Int, bytes: Int, status: RegionStatus) throws {
        try queue.sync {
            let sql = "UPDATE regions SET tile_done=?, bytes=?, status=? WHERE id=?"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_int(statement, 1, Int32(tileDone))
            sqlite3_bind_int(statement, 2, Int32(bytes))
            sqlite3_bind_text(statement, 3, status.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 4, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func regions() -> [RegionSummary] {
        queue.sync {
            let sql = """
                SELECT id,name,min_lat,min_lon,max_lat,max_lon,min_z,max_z,tile_total,tile_done,bytes,status,created_at
                FROM regions ORDER BY created_at DESC
                """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            var result: [RegionSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(RegionSummary(
                    id: String(cString: sqlite3_column_text(statement, 0)),
                    name: String(cString: sqlite3_column_text(statement, 1)),
                    minLat: sqlite3_column_double(statement, 2),
                    minLon: sqlite3_column_double(statement, 3),
                    maxLat: sqlite3_column_double(statement, 4),
                    maxLon: sqlite3_column_double(statement, 5),
                    minZ: Int(sqlite3_column_int(statement, 6)),
                    maxZ: Int(sqlite3_column_int(statement, 7)),
                    tileTotal: Int(sqlite3_column_int(statement, 8)),
                    tileDone: Int(sqlite3_column_int(statement, 9)),
                    bytes: Int(sqlite3_column_int(statement, 10)),
                    status: RegionStatus(rawValue: String(cString: sqlite3_column_text(statement, 11))) ?? .failed,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
                ))
            }
            return result
        }
    }

    /// Deletes the region row and its `region_tiles` membership, then removes
    /// any tile with no remaining owner. Tiles shared with another region are
    /// kept, so disk usage is only reclaimed for tiles that were exclusive to
    /// this region.
    func deleteRegion(id: String) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE")
            do {
                try execBound("DELETE FROM region_tiles WHERE region_id=?", text: id)
                try exec("""
                    DELETE FROM tiles
                    WHERE NOT EXISTS (
                        SELECT 1 FROM region_tiles rt
                        WHERE rt.server = tiles.server AND rt.z = tiles.z AND rt.x = tiles.x AND rt.y = tiles.y
                    )
                    """)
                try execBound("DELETE FROM regions WHERE id=?", text: id)
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    private func execBound(_ sql: String, text: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
        }
        sqlite3_bind_text(statement, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// For tests
    func totalBytes() -> Int {
        queue.sync {
            let sql = "SELECT COALESCE(SUM(bytes), 0) FROM tiles"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }
}
