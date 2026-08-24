import Foundation
import MapKit

/// Pure functions for sizing the tile pyramid an `MLNOfflinePack` downloads
/// (`MLNTilePyramidOfflineRegion` handles the actual per-tile enumeration and
/// fetching). The fixed z7–z14 range for offline download is a deliberate cap,
/// passed to `MLNTilePyramidOfflineRegion` as `fromZoomLevel`/`toZoomLevel`.
nonisolated enum TilePyramid {
    static let minZoom = 7
    static let maxZoom = 14

    /// Measured bytes per tile position at each zoom, for size estimation.
    private static let measuredBytesPerPosition: [Int: Double] = [
        11: 84_000,
        12: 61_000,
        13: 55_000,
        14: 50_000,
    ]

    /// Measured bytes per slope tile position at each zoom, for size estimation.
    private static let measuredSlopeBytesPerPosition: [Int: Double] = [
        7: 34_000,
        8: 31_000,
        9: 37_000,
        10: 38_000,
        11: 25_000,
        12: 21_000,
        13: 15_000,
        14: 10_000,
    ]

    private static let slopeCoverageFactor = 0.45

    /// Mean bytes of a published elevation tile, measured over all 54,801 of
    /// them. They exist at one zoom only, and only over land in Norway and
    /// Sweden — the coverage factor allows for the sea and border tiles a
    /// region usually includes.
    private static let measuredElevationBytes = 18_400.0
    private static let elevationCoverageFactor = 0.8

    static let maxDownloadBytes = 1_500_000_000

    /// Estimated tile count and total download size (bytes) for `rect`,
    static func estimate(rect: MKMapRect) -> (tileCount: Int, bytes: Int) {
        let region = MKCoordinateRegion(rect)
        var totalTiles = 0
        var bytes = 0.0
        for z in minZoom...maxZoom {
            let positions = tileCount(for: region, z: z)
            totalTiles += positions * TileServer.allCases.filter { $0.covers(zoom: z) }.count
            bytes += Double(positions) * (baseBytesPerPosition(atZoom: z)
                                          + slopeBytesPerPosition(atZoom: z)
                                          + elevationBytesPerPosition(atZoom: z))
        }
        return (tileCount: totalTiles, bytes: Int(bytes))
    }

    /// Bytes for one position of the base map, i.e. both base servers together.
    static func baseBytesPerPosition(atZoom z: Int) -> Double {
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

    static func slopeBytesPerPosition(atZoom z: Int) -> Double {
        let measured = measuredSlopeBytesPerPosition[z] ?? measuredSlopeBytesPerPosition[maxZoom] ?? 10_000
        return measured * slopeCoverageFactor
    }

    /// Bytes for one position of the elevation layer, which is published at a
    /// single zoom and so contributes nothing at any other level.
    static func elevationBytesPerPosition(atZoom z: Int) -> Double {
        guard TileServer.elevation.covers(zoom: z) else { return 0 }
        return measuredElevationBytes * elevationCoverageFactor
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

    /// The Web Mercator tile containing `coordinate` at zoom `z`.
    static func tileCoordinate(for coordinate: CLLocationCoordinate2D, z: Int) -> (x: Int, y: Int)? {
        guard CLLocationCoordinate2DIsValid(coordinate), (0...30).contains(z) else { return nil }

        let n = 1 << z
        let latitude = min(max(coordinate.latitude, -85.0511), 85.0511)
        let x = clamp(xIndex(forLongitude: coordinate.longitude, n: n), 0, n - 1)
        let y = clamp(yIndex(forLatitude: latitude, n: n), 0, n - 1)
        return (x, y)
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

    static var availableCapacityBytes: Int? {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return Int(capacity)
        }
        let fallback = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return fallback?.volumeAvailableCapacity
    }
}
