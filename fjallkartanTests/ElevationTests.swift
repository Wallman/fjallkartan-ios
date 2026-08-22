import CoreLocation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import fjallkartan

/// Builds a 256×256 elevation tile in the same RGBA encoding the build script
/// writes: `metres + 32768` across red and green, transparent for no data.
private func makeElevationTilePNG(height: (_ row: Int, _ column: Int) -> Int?) -> Data {
    let size = ElevationService.tileSize
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for row in 0..<size {
        for column in 0..<size {
            let base = (row * size + column) * 4
            guard let metres = height(row, column) else { continue }
            let value = metres + 32768
            pixels[base] = UInt8((value >> 8) & 0xFF)
            pixels[base + 1] = UInt8(value & 0xFF)
            pixels[base + 2] = 0
            pixels[base + 3] = 255
        }
    }

    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: size, height: size,
                        bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: size * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)!

    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

struct ElevationServiceTests {

    @Test func decodesPackedHeightsExactly() throws {
        // Values chosen to exercise both bytes, the offset and below sea level.
        let expected = [0, 1, 255, 256, 1489, -5, 2469]
        let png = makeElevationTilePNG { row, column in
            row == 0 && column < expected.count ? expected[column] : 100
        }

        let tile = try #require(ElevationService.decode(png))
        for (column, metres) in expected.enumerated() {
            #expect(tile.height(atRow: 0, column: column) == Double(metres))
        }
    }

    @Test func decodesTransparentPixelsAsNoData() throws {
        let png = makeElevationTilePNG { row, _ in row == 0 ? nil : 500 }
        let tile = try #require(ElevationService.decode(png))

        #expect(tile.height(atRow: 0, column: 0) == nil)
        #expect(tile.height(atRow: 1, column: 0) == 500)
    }

    @Test func rejectsDataThatIsNotATile() {
        #expect(ElevationService.decode(Data([0x89, 0x50, 0x4E, 0x47])) == nil)
    }

    /// The tile this maps to was verified against Geonorge during the build, so
    /// a regression in the projection maths would show up here.
    @Test func mapsCoordinatesToThePublishedTileGrid() {
        let sample = ElevationService.sample(
            for: CLLocationCoordinate2D(latitude: 61.05, longitude: 12.15))

        #expect(ElevationService.zoom == 12)
        #expect(sample.tile == ElevationService.TileKey(x: 2186, y: 1165))
        #expect((0..<256).contains(sample.row))
        #expect((0..<256).contains(sample.column))
    }

    @Test func clampsCoordinatesToTheTileGrid() {
        let north = ElevationService.sample(for: CLLocationCoordinate2D(latitude: 89, longitude: 179.999))
        #expect(north.tile.x < 1 << ElevationService.zoom)
        #expect(north.tile.y < 1 << ElevationService.zoom)
        #expect(north.tile.y >= 0)
    }
}

struct ElevationProfileMathTests {

    private func line(from start: CLLocationCoordinate2D, metres: Double) -> [CLLocationCoordinate2D] {
        // ~111,320 m per degree of latitude, so a due-north line of a known length.
        [start, CLLocationCoordinate2D(latitude: start.latitude + metres / 111_320,
                                       longitude: start.longitude)]
    }

    @Test func resamplesAtTheRequestedSpacing() {
        let route = line(from: CLLocationCoordinate2D(latitude: 62, longitude: 12), metres: 1_000)
        let total = DistanceMeasurement.length(of: route)
        let samples = ElevationProfile.resample(route, spacing: 25, maxSamples: 500)

        #expect(samples.first?.distance == 0)
        #expect(abs((samples.last?.distance ?? 0) - total) < 0.001)

        let steps = zip(samples, samples.dropFirst()).map { $1.distance - $0.distance }
        // Every step but the last is exactly the requested spacing; the last is
        // whatever remains, so the far end of the route is always sampled.
        for step in steps.dropLast() {
            #expect(abs(step - 25) < 0.001)
        }
        #expect((steps.last ?? 0) > 0)
        #expect((steps.last ?? 0) <= 25.001)
    }

    @Test func widensSpacingInsteadOfExceedingTheSampleCap() {
        let route = line(from: CLLocationCoordinate2D(latitude: 62, longitude: 12), metres: 200_000)
        let samples = ElevationProfile.resample(route, spacing: 25, maxSamples: 500)

        #expect(samples.count <= 500)
        let step = samples[1].distance - samples[0].distance
        #expect(step > 25)
        #expect(abs(step - 200_000 / 499) < 1)
    }

    @Test func resamplingIsIndependentOfHowDenselyTheRouteWasDrawn() {
        let start = CLLocationCoordinate2D(latitude: 62, longitude: 12)
        let sparse = line(from: start, metres: 1_000)
        // Same line, but with a vertex every 10 m the way a slow trace produces.
        let dense = stride(from: 0.0, through: 1_000, by: 10).map {
            CLLocationCoordinate2D(latitude: start.latitude + $0 / 111_320, longitude: start.longitude)
        }

        let a = ElevationProfile.resample(sparse)
        let b = ElevationProfile.resample(dense)

        #expect(a.count == b.count)
        for (first, second) in zip(a, b) {
            #expect(abs(first.distance - second.distance) < 1)
            #expect(abs(first.coordinate.latitude - second.coordinate.latitude) < 1e-6)
        }
    }

    @Test func shortRouteStillYieldsBothEnds() {
        let route = line(from: CLLocationCoordinate2D(latitude: 62, longitude: 12), metres: 10)
        let samples = ElevationProfile.resample(route, spacing: 25, maxSamples: 500)

        #expect(samples.count == 2)
        #expect(samples.first?.distance == 0)
        #expect(abs((samples.last?.distance ?? 0) - 10) < 0.5)
    }

    @Test func gainSumsClimbAndDrop() {
        let elevations: [Double?] = [100, 200, 150, 300]
        let totals = ElevationProfile.gain(for: elevations, hysteresis: 0)

        #expect(totals.ascent == 250)
        #expect(totals.descent == 50)
    }

    @Test func hysteresisIgnoresNoiseButKeepsRealClimb() {
        // 1 m jitter around a flat line: without hysteresis this accumulates.
        let jitter: [Double?] = (0..<200).map { $0.isMultiple(of: 2) ? 500 : 501 }

        #expect(ElevationProfile.gain(for: jitter, hysteresis: 0).ascent > 90)
        #expect(ElevationProfile.gain(for: jitter, hysteresis: 4).ascent == 0)

        let climb: [Double?] = [500, 501, 500, 600, 599, 700]
        let totals = ElevationProfile.gain(for: climb, hysteresis: 4)
        #expect(totals.ascent == 200)
        #expect(totals.descent == 0)
    }

    @Test func gapsAreNotBridged() {
        // The step across the gap is unknown terrain and must not be invented.
        let withGap: [Double?] = [100, nil, 900]
        #expect(ElevationProfile.gain(for: withGap, hysteresis: 4).ascent == 0)

        let withoutGap: [Double?] = [100, 900]
        #expect(ElevationProfile.gain(for: withoutGap, hysteresis: 4).ascent == 800)
    }

    @Test func emptyAndSingleSampleInputsAreSafe() {
        #expect(ElevationProfile.gain(for: []).ascent == 0)
        #expect(ElevationProfile.gain(for: [nil, nil]).descent == 0)
        #expect(ElevationProfile.resample([]).isEmpty)
    }
}

@MainActor
struct ElevationProfileModelTests {

    @Test func loadsStoredProfileFromASavedRoute() {
        let profile = ElevationProfile()
        let route = SavedRoute(meters: 300,
                               coordinates: [],
                               strokeSizes: [],
                               ascent: 0,
                               descent: 0,
                               elevations: [100, 200, 150, 300])
        profile.load(route)

        #expect(profile.points.count == 4)
        #expect(profile.ascent == 250)
        #expect(profile.descent == 50)
        #expect(profile.minimum == 100)
        #expect(profile.maximum == 300)
        #expect(profile.coverage == 1)
        #expect(profile.hasData)
        #expect(profile.points.last?.distance == 300)
    }

    @Test func partialCoverageIsReported() {
        let profile = ElevationProfile()
        let elevations: [Double?] = [100, nil, nil, 300]
        profile.load(SavedRoute(meters: 300, coordinates: [], strokeSizes: [],
                                elevations: elevations))

        #expect(profile.coverage == 0.5)
        #expect(profile.isPartial)
    }

    @Test func clearResetsEverything() {
        let profile = ElevationProfile()
        profile.load(SavedRoute(meters: 100, coordinates: [], strokeSizes: [],
                                elevations: [10, 20]))
        #expect(profile.hasData)

        profile.clear()
        #expect(!profile.hasData)
        #expect(profile.ascent == 0)
        #expect(profile.points.isEmpty)
    }
}

struct ElevationTileServerTests {

    @Test func elevationTilesAreDataNotPicture() {
        #expect(TileServer.elevation.isData)
        #expect(!TileServer.elevation.isSlope)
    }

    @Test func elevationIsDownloadedAtItsSingleZoomOnly() {
        let server = TileServer.elevation
        #expect(server.offlineMinimumZ == 12)
        #expect(server.offlineMaximumZ == 12)
        #expect(server.covers(zoom: 12))
        #expect(!server.covers(zoom: 11))
        #expect(!server.covers(zoom: 13))
    }

    @Test func pictureLayersStillStartAtTheLowestZoom() {
        for server in TileServer.allCases where !server.isData {
            #expect(server.offlineMinimumZ == TilePyramid.minZoom)
        }
    }
}

@MainActor
struct SavedRouteElevationTests {

    @Test func roundTripsElevationIncludingGaps() throws {
        let route = SavedRoute(meters: 1_000,
                               coordinates: [Coord(CLLocationCoordinate2D(latitude: 62, longitude: 12))],
                               strokeSizes: [1],
                               ascent: 250,
                               descent: 50,
                               elevations: [100, nil, 300])

        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(SavedRoute.self, from: data)

        #expect(decoded.ascent == 250)
        #expect(decoded.descent == 50)
        #expect(decoded.elevations.count == 3)
        #expect(decoded.elevations[1] == nil)
        #expect(decoded.elevations[2] == 300)
        #expect(decoded.schemaVersion == SavedRoute.currentSchemaVersion)
        #expect(decoded.hasElevation)
    }

    @Test func routeWithoutElevationReportsNone() {
        let route = SavedRoute(meters: 100, coordinates: [], strokeSizes: [])
        #expect(!route.hasElevation)
        #expect(route.ascent == 0)
    }
}
