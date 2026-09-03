import Foundation
import SQLite3

/// Single SQLite store backing offline elevation tiles and the region
/// bookkeeping that ties them to `MLNOfflinePack`s.
///
/// Only elevation tiles ever get rows in `tiles`/`region_tiles` — the base
/// map and slope tiles stay inside MapLibre's own offline database.
/// `region_tiles` exists purely so two overlapping downloaded regions can
/// share a tile without either one's deletion removing it from under the
/// other: the foreign key from `region_tiles.tile_id` to `tiles.id` has no
/// `ON DELETE` action, so SQLite itself refuses to drop a tile that is still
/// referenced.
nonisolated final class OfflineRegionsStore: @unchecked Sendable {
    static let shared = OfflineRegionsStore()

    static let databaseURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OfflineRegions.sqlite")
    }()

    private var handle: OpaquePointer?
    private let lock = NSLock()

    init(url: URL = OfflineRegionsStore.databaseURL) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            assertionFailure("failed to open OfflineRegions.sqlite")
            return
        }
        handle = db
        configure()
    }

    deinit {
        sqlite3_close(handle)
    }

    private func configure() {
        // PRAGMAs matched against MapLibre-native's own offline database
        exec("PRAGMA foreign_keys = ON")
        exec("PRAGMA journal_mode = DELETE")
        exec("PRAGMA synchronous = FULL")
        // Must precede any CREATE TABLE to take effect on a fresh database
        exec("PRAGMA auto_vacuum = INCREMENTAL")
        exec("""
            BEGIN;
            CREATE TABLE IF NOT EXISTS tiles (
              id   INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
              z    INTEGER NOT NULL,
              x    INTEGER NOT NULL,
              y    INTEGER NOT NULL,
              data BLOB,
              UNIQUE (z, x, y)
            );
            CREATE TABLE IF NOT EXISTS regions (
              region_id     TEXT NOT NULL PRIMARY KEY,
              mln_region_id INTEGER,
              size          INTEGER,
              name          TEXT NOT NULL,
              created_at    INTEGER NOT NULL,
              paused        INTEGER NOT NULL DEFAULT 0,
              completed     INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS region_tiles (
              region_id TEXT    NOT NULL REFERENCES regions(region_id) ON DELETE CASCADE,
              tile_id   INTEGER NOT NULL REFERENCES tiles(id),
              UNIQUE (region_id, tile_id)
            );
            CREATE INDEX IF NOT EXISTS region_tiles_tile_id ON region_tiles (tile_id);
            COMMIT;
            """)
        // Older databases predate the `paused`/`completed` columns; adds
        // silently fail once a fresh CREATE TABLE above already has them.
        exec("ALTER TABLE regions ADD COLUMN paused INTEGER NOT NULL DEFAULT 0")
        exec("ALTER TABLE regions ADD COLUMN completed INTEGER NOT NULL DEFAULT 0")
        // Older databases still call this column `mln_size`; a fresh
        // CREATE TABLE above already names it `size`, so this fails
        // (silently) there.
        exec("ALTER TABLE regions RENAME COLUMN mln_size TO size")
    }

    // MARK: - Low-level helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    @discardableResult
    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        return body(statement)
    }

    private func transaction(_ body: () -> Void) {
        lock.lock()
        sqlite3_exec(handle, "BEGIN", nil, nil, nil)
        lock.unlock()
        body()
        lock.lock()
        sqlite3_exec(handle, "COMMIT", nil, nil, nil)
        lock.unlock()
    }

    // MARK: - Tiles

    func isTileCached(_ key: ElevationService.TileKey) -> Bool {
        withStatement("SELECT 1 FROM tiles WHERE z = ? AND x = ? AND y = ? AND data IS NOT NULL") { statement in
            sqlite3_bind_int(statement, 1, Int32(ElevationService.zoom))
            sqlite3_bind_int(statement, 2, Int32(key.x))
            sqlite3_bind_int(statement, 3, Int32(key.y))
            return sqlite3_step(statement) == SQLITE_ROW
        } ?? false
    }

    /// `nil` means not cached at all (no row, or a row with `NULL` data); a
    /// zero-length `Data` is the sentinel recorded for a tile the elevation
    /// tileset doesn't publish.
    func tileData(_ key: ElevationService.TileKey) -> Data? {
        withStatement("SELECT data FROM tiles WHERE z = ? AND x = ? AND y = ?") { statement -> Data? in
            sqlite3_bind_int(statement, 1, Int32(ElevationService.zoom))
            sqlite3_bind_int(statement, 2, Int32(key.x))
            sqlite3_bind_int(statement, 3, Int32(key.y))
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            guard let bytes = sqlite3_column_blob(statement, 0) else {
                // A NULL pointer with a non-NULL column type is a
                // zero-length blob (the known-absent sentinel).
                return Data()
            }
            let count = sqlite3_column_bytes(statement, 0)
            return Data(bytes: bytes, count: Int(count))
        }.flatMap { $0 }
    }

    func setTileData(_ key: ElevationService.TileKey, data: Data) {
        withStatement("INSERT INTO tiles (z, x, y, data) VALUES (?, ?, ?, ?) ON CONFLICT (z, x, y) DO UPDATE SET data = excluded.data") { statement in
            sqlite3_bind_int(statement, 1, Int32(ElevationService.zoom))
            sqlite3_bind_int(statement, 2, Int32(key.x))
            sqlite3_bind_int(statement, 3, Int32(key.y))
            data.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            sqlite3_step(statement)
        }
    }

    func deleteTiles(_ keys: some Sequence<ElevationService.TileKey>) {
        transaction {
            for key in keys {
                // Foreign_keys=ON means this silently no-ops (constraint
                // failure) for a tile still referenced by another region.
                withStatement("DELETE FROM tiles WHERE z = ? AND x = ? AND y = ?") { statement in
                    sqlite3_bind_int(statement, 1, Int32(ElevationService.zoom))
                    sqlite3_bind_int(statement, 2, Int32(key.x))
                    sqlite3_bind_int(statement, 3, Int32(key.y))
                    sqlite3_step(statement)
                }
            }
        }
    }

    // MARK: - Regions

    func insertRegion(id: String, name: String, createdAt: Date) {
        withStatement("INSERT OR REPLACE INTO regions (region_id, name, created_at) VALUES (?, ?, ?)") { statement in
            bindText(statement, 1, id)
            bindText(statement, 2, name)
            sqlite3_bind_int64(statement, 3, Int64(createdAt.timeIntervalSince1970))
            sqlite3_step(statement)
        }
    }

    func setMLNRegionID(_ regionID: String, mlnRegionID: Int64) {
        withStatement("UPDATE regions SET mln_region_id = ? WHERE region_id = ?") { statement in
            sqlite3_bind_int64(statement, 1, mlnRegionID)
            bindText(statement, 2, regionID)
            sqlite3_step(statement)
        }
    }

    func setSize(_ regionID: String, bytes: Int64) {
        withStatement("UPDATE regions SET size = ? WHERE region_id = ?") { statement in
            sqlite3_bind_int64(statement, 1, bytes)
            bindText(statement, 2, regionID)
            sqlite3_step(statement)
        }
    }

    func size(for regionID: String) -> Int64? {
        withStatement("SELECT size FROM regions WHERE region_id = ?") { statement -> Int64? in
            bindText(statement, 1, regionID)
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(statement, 0)
        }.flatMap { $0 }
    }

    func setPaused(_ regionID: String, _ paused: Bool) {
        withStatement("UPDATE regions SET paused = ? WHERE region_id = ?") { statement in
            sqlite3_bind_int(statement, 1, paused ? 1 : 0)
            bindText(statement, 2, regionID)
            sqlite3_step(statement)
        }
    }

    func setCompleted(_ regionID: String) {
        withStatement("UPDATE regions SET completed = 1 WHERE region_id = ?") { statement in
            bindText(statement, 1, regionID)
            sqlite3_step(statement)
        }
    }

    struct RegionInfo {
        let id: String
        let name: String
        let createdAt: Date
        let mlnRegionID: Int64?
        let size: Int64?
        let paused: Bool
        let completed: Bool
    }

    func allRegions() -> [RegionInfo] {
        var regions: [RegionInfo] = []
        withStatement("SELECT region_id, name, created_at, mln_region_id, size, paused, completed FROM regions") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let nameText = sqlite3_column_text(statement, 1) else { continue }
                regions.append(RegionInfo(
                    id: String(cString: idText),
                    name: String(cString: nameText),
                    createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 2))),
                    mlnRegionID: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 3),
                    size: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 4),
                    paused: sqlite3_column_int(statement, 5) != 0,
                    completed: sqlite3_column_int(statement, 6) != 0
                ))
            }
        }
        return regions
    }

    func regionID(forMLNRegionID mlnRegionID: Int64) -> String? {
        withStatement("SELECT region_id FROM regions WHERE mln_region_id = ?") { statement -> String? in
            sqlite3_bind_int64(statement, 1, mlnRegionID)
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        } ?? nil
    }

    func mlnRegionID(for regionID: String) -> Int64? {
        withStatement("SELECT mln_region_id FROM regions WHERE region_id = ?") { statement -> Int64? in
            bindText(statement, 1, regionID)
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(statement, 0)
        }.flatMap { $0 }
    }

    func deleteRegion(id: String) {
        withStatement("DELETE FROM regions WHERE region_id = ?") { statement in
            bindText(statement, 1, id)
            sqlite3_step(statement)
        }
        // Cascade only removed the region_tiles rows; sweep now-orphaned
        // tile rows (still referenced ones fail their DELETE, which is fine).
        withStatement("DELETE FROM tiles WHERE NOT EXISTS (SELECT 1 FROM region_tiles WHERE tile_id = tiles.id)") { statement in
            sqlite3_step(statement)
        }
        exec("PRAGMA incremental_vacuum")
    }

    /// Ensures a `tiles` row (data left `NULL` if new) and a `region_tiles`
    /// link exist for every key, so completed downloads are ref-counted
    /// correctly even across overlapping regions.
    func linkTiles(regionID: String, keys: some Sequence<ElevationService.TileKey>) {
        transaction {
            for key in keys {
                withStatement("INSERT OR IGNORE INTO tiles (z, x, y) VALUES (?, ?, ?)") { statement in
                    sqlite3_bind_int(statement, 1, Int32(ElevationService.zoom))
                    sqlite3_bind_int(statement, 2, Int32(key.x))
                    sqlite3_bind_int(statement, 3, Int32(key.y))
                    sqlite3_step(statement)
                }
                let tileID = withStatement("SELECT id FROM tiles WHERE z = ? AND x = ? AND y = ?") { statement -> Int64? in
                    sqlite3_bind_int(statement, 1, Int32(ElevationService.zoom))
                    sqlite3_bind_int(statement, 2, Int32(key.x))
                    sqlite3_bind_int(statement, 3, Int32(key.y))
                    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                    return sqlite3_column_int64(statement, 0)
                } ?? nil
                guard let tileID else { continue }
                withStatement("INSERT OR IGNORE INTO region_tiles (region_id, tile_id) VALUES (?, ?)") { statement in
                    bindText(statement, 1, regionID)
                    sqlite3_bind_int64(statement, 2, tileID)
                    sqlite3_step(statement)
                }
            }
        }
    }

    /// Count and total bytes of the tiles already fetched (including known
    /// absent) for a region — the "at rest" progress, with no per-key scan.
    func regionProgress(id: String) -> (count: Int, bytes: Int) {
        withStatement("""
            SELECT COUNT(tiles.data), SUM(LENGTH(tiles.data))
            FROM region_tiles
            JOIN tiles ON tiles.id = region_tiles.tile_id
            WHERE region_tiles.region_id = ?
            """) { statement -> (Int, Int) in
            bindText(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
            return (Int(sqlite3_column_int(statement, 0)), Int(sqlite3_column_int64(statement, 1)))
        } ?? (0, 0)
    }

    /// The subset of `keys` already fetched for a region — used to resume a
    /// download by refetching only what's still missing.
    func fetchedKeys(regionID: String) -> Set<ElevationService.TileKey> {
        var keys: Set<ElevationService.TileKey> = []
        withStatement("""
            SELECT tiles.z, tiles.x, tiles.y
            FROM region_tiles
            JOIN tiles ON tiles.id = region_tiles.tile_id
            WHERE region_tiles.region_id = ? AND tiles.data IS NOT NULL
            """) { statement in
            bindText(statement, 1, regionID)
            while sqlite3_step(statement) == SQLITE_ROW {
                keys.insert(ElevationService.TileKey(
                    x: Int(sqlite3_column_int(statement, 1)),
                    y: Int(sqlite3_column_int(statement, 2))
                ))
            }
        }
        return keys
    }

    /// Every key linked to a region, fetched or not — the full "wanted" set
    /// established once by `linkTiles` at download start.
    func allKeys(regionID: String) -> [ElevationService.TileKey] {
        var keys: [ElevationService.TileKey] = []
        withStatement("""
            SELECT tiles.x, tiles.y
            FROM region_tiles
            JOIN tiles ON tiles.id = region_tiles.tile_id
            WHERE region_tiles.region_id = ?
            """) { statement in
            bindText(statement, 1, regionID)
            while sqlite3_step(statement) == SQLITE_ROW {
                keys.append(ElevationService.TileKey(
                    x: Int(sqlite3_column_int(statement, 0)),
                    y: Int(sqlite3_column_int(statement, 1))
                ))
            }
        }
        return keys
    }

    /// One-time wipe of every region/tile row, used by the migration in step 0.
    func wipeAll() {
        exec("""
            BEGIN;
            DELETE FROM region_tiles;
            DELETE FROM regions;
            DELETE FROM tiles;
            COMMIT;
            """)
        exec("PRAGMA incremental_vacuum")
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
