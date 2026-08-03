import CoreLocation
import Foundation
import SQLite3

/// A single place-name hit.
struct PlaceResult: Identifiable, Hashable {
    let id: Int64
    let name: String
    let kind: PlaceKind
    /// Set when the hit came from an alternate spelling, e.g. searching the
    /// North Sámi "Idnetčohkka" for a place displayed as "Sankthanshaugen".
    let matchedAlias: String?
    let municipality: String?
    let region: String?
    let country: Country
    let coordinate: CLLocationCoordinate2D

    var subtitle: String {
        [municipality, region]
            .compactMap { $0 }
            .reduce(into: [String]()) { partial, value in
                if !partial.contains(value) { partial.append(value) }
            }
            .joined(separator: ", ")
    }

    static func == (lhs: PlaceResult, rhs: PlaceResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum Country: Int32 {
    case sweden = 0
    case norway = 1
}

/// Mirrors the `kinds` list written into the database by
/// `Tools/build_places_db.py`. The order is part of the file format.
enum PlaceKind: Int32, CaseIterable {
    case settlement, terrain, water, watercourse, wetland
    case glacier, nature, cultural, infrastructure, other

    var symbolName: String {
        switch self {
        case .settlement: "house.fill"
        case .terrain: "mountain.2.fill"
        case .water: "drop.fill"
        case .watercourse: "water.waves"
        case .wetland: "leaf.fill"
        case .glacier: "snowflake"
        case .nature: "tree.fill"
        case .cultural: "building.columns.fill"
        case .infrastructure: "road.lanes"
        case .other: "mappin"
        }
    }

    /// Ranking demotions live in `PlaceSearch.searchSQL`, which scores against
    /// these raw values directly.
}

final class PlaceSearch {
    /// Coordinates are stored as integers to keep `place` compact; this is the
    /// divisor the build tool used, and must match `COORD_SCALE` there.
    private static let coordinateScale = 100_000.0
    private static let scanLimit: Int32 = 60_000

    private var handle: OpaquePointer?
    private var statement: OpaquePointer?

    /// Matches, scores, deduplicates and hydrates in one pass.
    private static let searchSQL = """
        WITH hit AS (
            SELECT p.id AS place_id,
                   COALESCE(a.name, p.name) AS matched,
                   a.id IS NULL AS is_primary,
                   p.kind AS kind,
                   (CASE WHEN length(COALESCE(a.name, p.name)) = ?2 THEN 0 ELSE 100 END)
                   + p.rank * 5
                   -- A mountain map cares little for road names; these demote
                   -- by PlaceKind raw value.
                   + CASE p.kind
                       WHEN 3 THEN 0.5  -- watercourse
                       WHEN 4 THEN 1.5  -- wetland
                       WHEN 7 THEN 1.0  -- cultural
                       WHEN 8 THEN 2.0  -- infrastructure
                       WHEN 9 THEN 3.0  -- other
                       ELSE 0
                     END
                   + CASE WHEN a.id IS NULL THEN 0 ELSE 2 END AS score
            FROM place_fts f
            LEFT JOIN alias a ON a.id = f.rowid
            JOIN place p ON p.id = COALESCE(a.place_id, f.rowid)
            WHERE f.place_fts MATCH ?1
            LIMIT ?3
        ),
        best AS (
            SELECT place_id, matched, is_primary, kind, MIN(score) AS score
            FROM hit
            GROUP BY place_id
            ORDER BY score
            LIMIT ?4
        )
        SELECT b.place_id, b.matched, b.is_primary, b.kind,
               p.lat, p.lon, p.country, m.name, m.region, p.name
        FROM best b
        JOIN place p ON p.id = b.place_id
        LEFT JOIN municipality m ON m.id = p.muni
        ORDER BY b.score
        """

    init?(url: URL? = Bundle.main.url(forResource: "places", withExtension: "sqlite")) {
        guard let url else {
            assertionFailure("places.sqlite missing from the app bundle")
            return nil
        }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_exec(handle, "PRAGMA mmap_size=20971520", nil, nil, nil)
        guard sqlite3_prepare_v2(handle, Self.searchSQL, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
    }

    deinit {
        sqlite3_finalize(statement)
        sqlite3_close(handle)
    }

    // MARK: - Query building

    /// Turns free text into an FTS5 expression. Every character that FTS5 treats as syntax is dropped.
    static func ftsExpression(for text: String) -> String? {
        let tokens = text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(6)
            .map { "\($0)*" }
        return tokens.isEmpty ? nil : tokens.joined(separator: " AND ")
    }

    // MARK: - Search

    func search(_ text: String, limit: Int = 40) -> [PlaceResult] {
        guard let statement, let expression = Self.ftsExpression(for: text) else { return [] }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, expression, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        // SQLite counts characters, so the needle has to be measured in the
        // same composed form the database stores.
        let needle = text.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        sqlite3_bind_int(statement, 2, Int32(needle.unicodeScalars.count))
        sqlite3_bind_int(statement, 3, Self.scanLimit)
        sqlite3_bind_int(statement, 4, Int32(limit))

        var results: [PlaceResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let isPrimary = sqlite3_column_int(statement, 2) == 1
            let matched = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let displayName = sqlite3_column_text(statement, 9).map { String(cString: $0) }

            results.append(PlaceResult(
                id: sqlite3_column_int64(statement, 0),
                name: displayName ?? matched ?? "",
                kind: PlaceKind(rawValue: sqlite3_column_int(statement, 3)) ?? .other,
                // The matched spelling is only shown when it differs from the
                // display name, which is 1.2% of entries.
                matchedAlias: isPrimary ? nil : matched,
                municipality: sqlite3_column_text(statement, 7).map { String(cString: $0) },
                region: sqlite3_column_text(statement, 8).map { String(cString: $0) },
                country: Country(rawValue: sqlite3_column_int(statement, 6)) ?? .sweden,
                coordinate: CLLocationCoordinate2D(
                    latitude: Double(sqlite3_column_int64(statement, 4)) / Self.coordinateScale,
                    longitude: Double(sqlite3_column_int64(statement, 5)) / Self.coordinateScale
                )
            ))
        }
        return results
    }
}
