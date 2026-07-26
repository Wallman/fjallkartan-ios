import Testing
import MapKit
@testable import fjallkartan

@Suite("TileCoverageResolver")
struct TileCoverageResolverTests {

    let resolver = TileCoverageResolver()

    @Test func norwayCoverage() {
        let path = MKTileOverlayPath(x: 135, y: 74, z: 8, contentScaleFactor: 1) // Oslo
        let coverage = resolver.coverage(for: path)
        #expect(coverage.norway)
        #expect(!coverage.sweden)
    }

    @Test func swedenCoverage() {
        let path = MKTileOverlayPath(x: 140, y: 75, z: 8, contentScaleFactor: 1) // Uppsala
        let coverage = resolver.coverage(for: path)
        #expect(!coverage.norway)
        #expect(coverage.sweden)
    }

    @Test func noCoverage() {
        let path = MKTileOverlayPath(x: 129, y: 88, z: 8, contentScaleFactor: 1) // Paris
        let coverage = resolver.coverage(for: path)
        #expect(!coverage.norway)
        #expect(!coverage.sweden)
    }

    @Test func borderCoverage() {
        let path = MKTileOverlayPath(x: 2206, y: 1092, z: 12, contentScaleFactor: 1)
        let coverage = resolver.coverage(for: path)
        #expect(coverage.norway)
        #expect(coverage.sweden)
    }
}
