import MapKit
import Testing

@testable import fjallkartan

struct TilePyramidTests {
    private func region(center: CLLocationCoordinate2D, spanDegrees: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center,
                           span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees))
    }

    @Test func indicesAreClampedToValidRangeAtLowZoom() {
        // At z7, n = 128; a huge span must not overflow the valid range.
        let huge = region(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), spanDegrees: 400)
        let indices = TilePyramid.tileIndices(for: huge, z: 7)
        let n = 1 << 7
        for index in indices {
            #expect(index.x >= 0 && index.x < n)
            #expect(index.y >= 0 && index.y < n)
        }
    }

    @Test func latitudeIsClampedToWebMercatorLimit() {
        // A region reaching to the pole must not crash or invert the y range.
        let poleward = region(center: CLLocationCoordinate2D(latitude: 89, longitude: 18), spanDegrees: 10)
        let indices = TilePyramid.tileIndices(for: poleward, z: 10)
        #expect(!indices.isEmpty)
        let n = 1 << 10
        for index in indices {
            #expect(index.y >= 0 && index.y < n)
        }
    }

    @Test func singlePositionIndexIsStable() {
        // Known reference: Abisko (68.35N, 18.83E) at z13.
        let single = region(center: CLLocationCoordinate2D(latitude: 68.35, longitude: 18.83),
                            spanDegrees: 0.0001)
        let indices = TilePyramid.tileIndices(for: single, z: 13)
        #expect(indices.count == 1)
        let n = 1 << 13
        #expect(indices[0].x >= 0 && indices[0].x < n)
        #expect(indices[0].y >= 0 && indices[0].y < n)
    }

    @Test func slopeLayersAddAModestShareOfTheEstimate() {
        let rect = region(center: CLLocationCoordinate2D(latitude: 68.35, longitude: 18.83),
                          spanDegrees: 0.2).toMapRect()
        let region = MKCoordinateRegion(rect)
        // Base map alone, using the same per-position arithmetic as `estimate`.
        var baseOnly = 0.0
        for z in TilePyramid.minZoom...TilePyramid.maxZoom {
            baseOnly += Double(TilePyramid.tileCount(for: region, z: z)) * TilePyramid.baseBytesPerPosition(atZoom: z)
        }
        let total = Double(TilePyramid.estimate(rect: rect).bytes)
        // Slope is about a tenth on top of the base map, not a doubling.
        #expect(total > baseOnly * 1.05)
        #expect(total < baseOnly * 1.15)
    }

    @Test func estimateGrowsWithArea() {
        let small = region(center: CLLocationCoordinate2D(latitude: 68.35, longitude: 18.83),
                           spanDegrees: 0.1).toMapRect()
        let large = region(center: CLLocationCoordinate2D(latitude: 68.35, longitude: 18.83),
                           spanDegrees: 0.5).toMapRect()
        let smallEstimate = TilePyramid.estimate(rect: small)
        let largeEstimate = TilePyramid.estimate(rect: large)
        #expect(largeEstimate.bytes > smallEstimate.bytes)
        #expect(largeEstimate.tileCount > smallEstimate.tileCount)
    }

    @Test func estimateIsPositiveForNonEmptyRegion() {
        let rect = region(center: CLLocationCoordinate2D(latitude: 68.35, longitude: 18.83),
                          spanDegrees: 0.05).toMapRect()
        let estimate = TilePyramid.estimate(rect: rect)
        #expect(estimate.tileCount > 0)
        #expect(estimate.bytes > 0)
    }

    @Test func availableCapacityBytesReportsSomethingOnSimulator() {
        // Relocated from `OfflineTileStore` — a real device always has *some*
        // free space, so this just guards against the resource-values lookup
        // silently starting to fail.
        #expect((TilePyramid.availableCapacityBytes ?? 0) > 0)
    }
}

private extension MKCoordinateRegion {
    func toMapRect() -> MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(
            latitude: center.latitude + span.latitudeDelta / 2,
            longitude: center.longitude - span.longitudeDelta / 2))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(
            latitude: center.latitude - span.latitudeDelta / 2,
            longitude: center.longitude + span.longitudeDelta / 2))
        return MKMapRect(x: min(topLeft.x, bottomRight.x),
                         y: min(topLeft.y, bottomRight.y),
                         width: abs(topLeft.x - bottomRight.x),
                         height: abs(topLeft.y - bottomRight.y))
    }
}
