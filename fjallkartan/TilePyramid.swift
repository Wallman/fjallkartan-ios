import Foundation
import MapKit

/// Pure functions for enumerating and sizing the tile pyramid that
/// `OfflineRegionDownloader` fetches and `OfflineTileStore` persists.
/// The fixed z7–z14 range for offline download is a deliberate cap.
enum TilePyramid {
    static let minZoom = 7
    static let maxZoom = 14

    /// Measured bytes per tile position at each zoom, for size estimation.
    private static let measuredBytesPerPosition: [Int: Double] = [
        11: 84_000,
        12: 61_000,
        13: 55_000,
        14: 50_000,
    ]

    static let maxDownloadBytes = 1_500_000_000

    /// All tile positions covering `rect` across the fixed z7–z14 range, in
    /// low-to-high zoom order so a cancelled download still leaves usable
    /// low-zoom coverage.
    static func tiles(in rect: MKMapRect) -> [MKTileOverlayPath] {
        let region = MKCoordinateRegion(rect)
        var paths: [MKTileOverlayPath] = []
        for z in minZoom...maxZoom {
            for (x, y) in tileIndices(for: region, z: z) {
                paths.append(MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 1))
            }
        }
        return paths
    }

    /// Estimated tile count and total download size (bytes) for `rect`,
    static func estimate(rect: MKMapRect) -> (tileCount: Int, bytes: Int) {
        let region = MKCoordinateRegion(rect)
        var positions = 0
        var bytes = 0.0
        for z in minZoom...maxZoom {
            let count = tileCount(for: region, z: z)
            positions += count
            bytes += Double(count) * bytesPerPosition(atZoom: z)
        }
        // Both servers are fetched for every position.
        return (tileCount: positions * 2, bytes: Int(bytes))
    }

    private static func bytesPerPosition(atZoom z: Int) -> Double {
        if let measured = measuredBytesPerPosition[z] { return measured }
        if z > maxZoom, let top = measuredBytesPerPosition[maxZoom] { return top }
        // Extrapolate below the lowest measured zoom, halving per level.
        let lowestMeasured = measuredBytesPerPosition.keys.min() ?? minZoom
        guard z < lowestMeasured, let base = measuredBytesPerPosition[lowestMeasured] else {
            return measuredBytesPerPosition.values.min() ?? 40_000
        }
        let levels = lowestMeasured - z
        return base / pow(2, Double(levels))
    }

    /// Tile x/y indices (Web Mercator) covering `region` at zoom `z`, with
    /// latitude clamped to the Web Mercator limit and ranges clamped to the
    /// valid `0..<2^z` span.
    static func tileIndices(for region: MKCoordinateRegion, z: Int) -> [(x: Int, y: Int)] {
        guard let bounds = tileBounds(for: region, z: z) else { return [] }

        var result: [(x: Int, y: Int)] = []
        result.reserveCapacity((bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1))
        for y in bounds.minY...bounds.maxY {
            for x in bounds.minX...bounds.maxX {
                result.append((x, y))
            }
        }
        return result
    }

    /// Number of tile positions covering `region` at zoom `z`, computed
    /// arithmetically so that estimates stay cheap.
    static func tileCount(for region: MKCoordinateRegion, z: Int) -> Int {
        guard let bounds = tileBounds(for: region, z: z) else { return 0 }
        return (bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1)
    }

    private static func tileBounds(for region: MKCoordinateRegion, z: Int) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        let n = 1 << z

        let minLat = max(region.center.latitude - region.span.latitudeDelta / 2, -85.0511)
        let maxLat = min(region.center.latitude + region.span.latitudeDelta / 2, 85.0511)
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        // Latitude decreases as tile-y increases, so the max latitude gives
        // the smallest y.
        let minX = clamp(xIndex(forLongitude: minLon, n: n), 0, n - 1)
        let maxX = clamp(xIndex(forLongitude: maxLon, n: n), 0, n - 1)
        let minY = clamp(yIndex(forLatitude: maxLat, n: n), 0, n - 1)
        let maxY = clamp(yIndex(forLatitude: minLat, n: n), 0, n - 1)

        guard minX <= maxX, minY <= maxY else { return nil }
        return (minX, maxX, minY, maxY)
    }

    private static func xIndex(forLongitude lon: Double, n: Int) -> Int {
        Int(floor((lon + 180) / 360 * Double(n)))
    }

    private static func yIndex(forLatitude lat: Double, n: Int) -> Int {
        let latRad = lat * .pi / 180
        let y = (1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * Double(n)
        return Int(floor(y))
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
