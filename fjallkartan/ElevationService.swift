import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import MapKit

/// Samples terrain height from the prebaked elevation tiles.
///
/// The tiles are data, not pictures: each pixel carries `metres + 32768` packed
/// into the red and green channels, with a fully transparent pixel meaning no
/// data. They are published at one zoom only, so a sample is always a direct
/// lookup — there is no pyramid to walk.
nonisolated final class ElevationService: @unchecked Sendable {
    static let shared = ElevationService()

    /// The single zoom the tiles are published at.
    static let zoom = TileServer.elevation.sourceMaximumZ

    static let tileSize = 256
    private static let encodingOffset = 32768
    /// Sentinel for a transparent (no data) pixel. Real terrain never reaches
    /// it, and it survives being stored in the same compact array as heights.
    static let noDataHeight = Int16.min

    struct TileKey: Hashable {
        let x: Int
        let y: Int
    }

    /// A decoded tile: 256×256 metres as `Int16`, so a cached tile costs 128 KB
    /// rather than the 256 KB the RGBA pixels would.
    final class HeightTile {
        let heights: [Int16]
        init(heights: [Int16]) { self.heights = heights }

        func height(atRow row: Int, column: Int) -> Double? {
            let value = heights[row * ElevationService.tileSize + column]
            return value == ElevationService.noDataHeight ? nil : Double(value)
        }
    }

    private let session: URLSession
    private let cache = NSCache<NSString, HeightTile>()
    private let lock = NSLock()
    private var inFlight: [TileKey: [(HeightTile?) -> Void]] = [:]

    init(session: URLSession = .shared, cachedTiles: Int = 64) {
        self.session = session
        cache.countLimit = cachedTiles
    }

    // MARK: - Offline cache

    private static let offlineCacheDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("ElevationTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func offlineCacheURL(for key: TileKey) -> URL {
        offlineCacheDirectory.appendingPathComponent("\(key.x)_\(key.y).png")
    }

    static func isTileCached(_ key: TileKey) -> Bool {
        FileManager.default.fileExists(atPath: offlineCacheURL(for: key).path)
    }

    private static func cachedFileSize(_ key: TileKey) -> Int {
        let values = try? offlineCacheURL(for: key).resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private static func markTileAbsent(_ key: TileKey) {
        try? Data().write(to: offlineCacheURL(for: key), options: .atomic)
    }

    private static func isTileKnownAbsent(_ key: TileKey) -> Bool {
        cachedFileSize(key) == 0 && isTileCached(key)
    }

    static func deleteTiles(_ keys: some Sequence<TileKey>) {
        for key in keys {
            try? FileManager.default.removeItem(at: offlineCacheURL(for: key))
        }
    }

    static func tileKeys(coveringRect rect: MKMapRect) -> [TileKey] {
        let region = MKCoordinateRegion(rect)
        return TilePyramid.tileIndices(for: region, z: zoom).map { TileKey(x: $0.x, y: $0.y) }
    }

    func prefetchTiles(
        _ keys: [TileKey],
        onProgress: @MainActor @escaping (_ tilesDone: Int, _ tilesTotal: Int, _ bytesDone: Int) -> Void
    ) async {
        let total = keys.count
        var done = 0
        var bytes = keys.reduce(0) { $0 + (Self.isTileCached($1) ? Self.cachedFileSize($1) : 0) }
        await onProgress(keys.filter(Self.isTileCached).count, total, bytes)

        let concurrency = 6
        var index = 0
        await withTaskGroup(of: (Bool, Int).self) { group in
            func addNext() {
                guard index < keys.count else { return }
                let key = keys[index]
                index += 1
                group.addTask { [weak self] in
                    guard let self else { return (false, 0) }
                    if Self.isTileCached(key) { return (true, 0) }
                    return await self.fetchAndCacheTile(key)
                }
            }
            for _ in 0..<min(concurrency, keys.count) { addNext() }
            while let (succeeded, addedBytes) = await group.next() {
                if succeeded {
                    done += 1
                    bytes += addedBytes
                }
                await onProgress(done, total, bytes)
                addNext()
            }
        }
    }

    private func fetchAndCacheTile(_ key: TileKey) async -> (succeeded: Bool, bytes: Int) {
        guard Task.isCancelled == false else { return (false, 0) }
        let url = TileServer.elevation.url(z: Self.zoom, x: key.x, y: key.y)
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse else {
            return (false, 0)
        }
        // The elevation tileset is sparse, so "not found" is a settled answer
        // rather than a failure: record it and count the tile as done.
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404 {
                Self.markTileAbsent(key)
                return (true, 0)
            }
            return (false, 0)
        }
        guard Self.decode(data) != nil else { return (false, 0) }
        try? data.write(to: Self.offlineCacheURL(for: key), options: .atomic)
        return (true, data.count)
    }

    // MARK: - Sampling

    /// Terrain height in metres for each coordinate, `nil` where the tiles have
    /// no data (at sea, or outside Norway and Sweden).
    ///
    /// Coordinates are grouped by tile first, so a route that crosses one tile
    /// two hundred times still fetches it once.
    func heights(for coordinates: [CLLocationCoordinate2D]) async -> [Double?] {
        guard !coordinates.isEmpty else { return [] }

        let samples = coordinates.map(Self.sample(for:))
        let keys = Set(samples.map(\.tile))

        var tiles: [TileKey: HeightTile] = [:]
        await withTaskGroup(of: (TileKey, HeightTile?).self) { group in
            for key in keys {
                group.addTask { (key, await self.tile(key)) }
            }
            for await (key, tile) in group {
                if let tile { tiles[key] = tile }
            }
        }

        return samples.map { sample in
            tiles[sample.tile]?.height(atRow: sample.row, column: sample.column)
        }
    }

    func height(for coordinate: CLLocationCoordinate2D) async -> Double? {
        await heights(for: [coordinate]).first ?? nil
    }

    // MARK: - Tile loading

    private func tile(_ key: TileKey) async -> HeightTile? {
        if let cached = cache.object(forKey: Self.cacheKey(key)) { return cached }

        return await withCheckedContinuation { continuation in
            let resume: (HeightTile?) -> Void = { continuation.resume(returning: $0) }

            lock.lock()
            if inFlight[key] != nil {
                inFlight[key]?.append(resume)
                lock.unlock()
                return
            }
            inFlight[key] = [resume]
            lock.unlock()

            Task {
                let tile = await fetchTile(key)
                if let tile {
                    cache.setObject(tile, forKey: Self.cacheKey(key))
                }
                let waiting = removeWaiters(for: key)
                for waiter in waiting { waiter(tile) }
            }
        }
    }

    /// Synchronous, so the lock is taken and released outside of an `async`
    /// context, which Swift 6 concurrency checking otherwise flags.
    private func removeWaiters(for key: TileKey) -> [(HeightTile?) -> Void] {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.removeValue(forKey: key) ?? []
    }

    private func fetchTile(_ key: TileKey) async -> HeightTile? {
        if Self.isTileKnownAbsent(key) { return nil }
        if let data = try? Data(contentsOf: Self.offlineCacheURL(for: key)),
           let tile = Self.decode(data) {
            return tile
        }

        let url = TileServer.elevation.url(z: Self.zoom, x: key.x, y: key.y)
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        return Self.decode(data)
    }

    private static func cacheKey(_ key: TileKey) -> NSString {
        "\(key.x)/\(key.y)" as NSString
    }

    /// Unpacks the RGBA pixels back into metres.
    ///
    /// The bitmap context deliberately uses the image's own colour space: a
    /// mismatch would let Core Graphics colour-manage the pixels on the way in,
    /// and shifting the red channel by one is a 256 m error.
    static func decode(_ data: Data) -> HeightTile? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == tileSize, image.height == tileSize else { return nil }

        let count = tileSize * tileSize
        var pixels = [UInt8](repeating: 0, count: count * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: tileSize,
                height: tileSize,
                bitsPerComponent: 8,
                bytesPerRow: tileSize * 4,
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
            return true
        }
        guard drawn else { return nil }

        var heights = [Int16](repeating: noDataHeight, count: count)
        for index in 0..<count {
            let base = index * 4
            guard pixels[base + 3] != 0 else { continue }
            let value = (Int(pixels[base]) << 8) | Int(pixels[base + 1])
            heights[index] = Int16(clamping: value - encodingOffset)
        }
        return HeightTile(heights: heights)
    }

    // MARK: - Web Mercator

    struct Sample: Equatable {
        let tile: TileKey
        let row: Int
        let column: Int
    }

    /// The tile, and the pixel within it, covering `coordinate` at `zoom`.
    static func sample(for coordinate: CLLocationCoordinate2D) -> Sample {
        let scale = Double(1 << zoom * tileSize)
        let latitude = min(max(coordinate.latitude, -85.05112878), 85.05112878)
        let radians = latitude * .pi / 180

        let x = (coordinate.longitude + 180) / 360 * scale
        let y = (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * scale

        let limit = 1 << zoom
        let tileX = clamp(Int(floor(x / Double(tileSize))), 0, limit - 1)
        let tileY = clamp(Int(floor(y / Double(tileSize))), 0, limit - 1)
        let column = clamp(Int(floor(x)) - tileX * tileSize, 0, tileSize - 1)
        let row = clamp(Int(floor(y)) - tileY * tileSize, 0, tileSize - 1)

        return Sample(tile: TileKey(x: tileX, y: tileY), row: row, column: column)
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
