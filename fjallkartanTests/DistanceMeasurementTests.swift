import CoreLocation
import Foundation
import Testing

@testable import fjallkartan

@MainActor
struct DistanceMeasurementTests {
    // Straight north-south hop used as a building block: 0.01 degrees of
    // latitude is ~1113 m anywhere on the globe.
    private static func north(_ start: CLLocationCoordinate2D, steps: Int) -> [CLLocationCoordinate2D] {
        (0...steps).map {
            CLLocationCoordinate2D(latitude: start.latitude + 0.01 * Double($0),
                                   longitude: start.longitude)
        }
    }

    private let abisko = CLLocationCoordinate2D(latitude: 68.35, longitude: 18.83)

    @Test func geodesicDistanceMatchesKnownReference() {
        // Stockholm -> Gothenburg, ~398 km great-circle.
        let stockholm = CLLocationCoordinate2D(latitude: 59.3293, longitude: 18.0686)
        let gothenburg = CLLocationCoordinate2D(latitude: 57.7089, longitude: 11.9746)
        let km = DistanceMeasurement.meters(from: stockholm, to: gothenburg) / 1000
        #expect(abs(km - 398) < 5)
    }

    /// At 68°N a Mercator-space measurement would overstate by ~2.7x, so this
    /// pins the east-west case that would catch such a regression.
    @Test func eastWestDistanceIsNotInflatedAtHighLatitude() {
        let a = CLLocationCoordinate2D(latitude: 68.35, longitude: 18.0)
        let b = CLLocationCoordinate2D(latitude: 68.35, longitude: 19.0)
        let km = DistanceMeasurement.meters(from: a, to: b) / 1000
        // 1 degree of longitude at 68.35°N is ~41.3 km.
        #expect(abs(km - 41.3) < 1.0)
    }

    @Test func startsEmpty() {
        let m = DistanceMeasurement()
        #expect(m.isEmpty)
        #expect(!m.canUndo)
        #expect(m.totalMeters == 0)
        #expect(m.anchor == nil)
    }

    @Test func singleStrokeMeasuresItsOwnLength() {
        let m = DistanceMeasurement()
        m.appendStroke(Self.north(abisko, steps: 1))
        #expect(abs(m.totalMeters - 1113) < 15)
        #expect(m.canUndo)
        #expect(!m.isEmpty)
    }

    /// Multi-stroke drawing joins strokes with a straight connector so the user
    /// can pan between strokes; the connector must be counted.
    @Test func secondStrokeIncludesConnectorFromPreviousEndpoint() {
        let m = DistanceMeasurement()
        m.appendStroke(Self.north(abisko, steps: 1))
        let firstTotal = m.totalMeters

        let secondStart = CLLocationCoordinate2D(latitude: abisko.latitude + 0.02,
                                                 longitude: abisko.longitude)
        m.appendStroke(Self.north(secondStart, steps: 1))

        // Stroke 1 (1113) + connector (1113) + stroke 2 (1113).
        #expect(abs(m.totalMeters - 3 * firstTotal) < 30)
        #expect(m.coordinates.count == 4)
    }

    @Test func undoRemovesOnlyTheLastStroke() {
        let m = DistanceMeasurement()
        m.appendStroke(Self.north(abisko, steps: 1))
        let afterFirst = m.totalMeters
        let secondStart = CLLocationCoordinate2D(latitude: abisko.latitude + 0.02,
                                                 longitude: abisko.longitude)
        m.appendStroke(Self.north(secondStart, steps: 1))

        m.undoLastStroke()

        #expect(abs(m.totalMeters - afterFirst) < 0.001)
        #expect(m.coordinates.count == 2)
        #expect(m.canUndo)

        m.undoLastStroke()
        #expect(m.isEmpty)
        #expect(!m.canUndo)
        #expect(m.totalMeters == 0)
    }

    @Test func undoOnEmptyMeasurementIsHarmless() {
        let m = DistanceMeasurement()
        m.undoLastStroke()
        #expect(m.isEmpty)
        #expect(m.totalMeters == 0)
    }

    @Test func degenerateStrokesAreRejected() {
        let m = DistanceMeasurement()
        let versionBefore = m.version

        m.appendStroke([])
        m.appendStroke([abisko])

        #expect(m.isEmpty)
        #expect(!m.canUndo)
        #expect(m.version == versionBefore)
    }

    @Test func clearResetsEverything() {
        let m = DistanceMeasurement()
        m.appendStroke(Self.north(abisko, steps: 2))
        m.previewMeters = 500

        m.clear()

        #expect(m.isEmpty)
        #expect(!m.canUndo)
        #expect(m.totalMeters == 0)
        #expect(m.previewMeters == nil)
    }

    @Test func previewIsAddedToCommittedDistanceThenDiscardedOnExit() {
        let m = DistanceMeasurement()
        m.appendStroke(Self.north(abisko, steps: 1))
        let committed = m.totalMeters

        m.previewMeters = 250
        #expect(abs(m.totalMeters - (committed + 250)) < 0.001)

        // Leaving measure mode must not bake the in-progress preview into the route.
        m.isMeasuring = true
        m.isMeasuring = false
        #expect(m.previewMeters == nil)
        #expect(abs(m.totalMeters - committed) < 0.001)
    }

    @Test func versionChangesOnlyOnRealMutations() {
        let m = DistanceMeasurement()
        let start = m.version

        m.clear() // already empty
        #expect(m.version == start)

        m.appendStroke(Self.north(abisko, steps: 1))
        #expect(m.version > start)

        let afterAppend = m.version
        m.undoLastStroke()
        #expect(m.version > afterAppend)
    }

    @Test func anchorTracksTheLastCoordinate() {
        let m = DistanceMeasurement()
        let stroke = Self.north(abisko, steps: 3)
        m.appendStroke(stroke)

        let anchor = try! #require(m.anchor)
        #expect(abs(anchor.latitude - stroke[stroke.count - 1].latitude) < 1e-9)
    }

    @Test(arguments: [
        (120.0, "m"),
        (999.0, "m"),
        (1500.0, "km"),
        (42_000.0, "km"),
    ])
    func formatsDistanceWithAppropriateUnit(meters: Double, expectedUnit: String) {
        let m = DistanceMeasurement()
        m.previewMeters = meters
        #expect(m.formattedDistance.hasSuffix(expectedUnit))
    }

    @Test func loadReplacesCurrentRouteAndPreservesUndo() {
        let m = DistanceMeasurement()
        m.appendStroke(Self.north(abisko, steps: 1))
        m.appendStroke(Self.north(CLLocationCoordinate2D(latitude: abisko.latitude + 0.02,
                                                          longitude: abisko.longitude), steps: 1))
        let saved = m.snapshot()
        let versionBeforeLoad = m.version

        let fresh = DistanceMeasurement()
        fresh.load(saved)

        #expect(fresh.coordinates.count == saved.coordinates.count)
        #expect(abs(fresh.totalMeters - saved.meters) < 0.001)
        #expect(fresh.canUndo)
        fresh.undoLastStroke()
        #expect(fresh.coordinates.count == 2)

        // Loading into a measurement that already had a route replaces it
        // and still bumps version so MapView redraws.
        m.load(saved)
        #expect(m.version > versionBeforeLoad)
        #expect(m.previewMeters == nil)
    }
}

struct LineSimplifierTests {
    @Test func shortInputsPassThroughUnchanged() {
        let two = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        #expect(LineSimplifier.simplify(two, tolerance: 2).count == 2)
        #expect(LineSimplifier.simplify([], tolerance: 2).isEmpty)
    }

    @Test func collinearPointsCollapseToEndpoints() {
        let straight = (0...10).map { CGPoint(x: Double($0) * 10, y: 0) }
        #expect(LineSimplifier.simplify(straight, tolerance: 2).count == 2)
    }

    @Test func significantCornersSurvive() {
        let corner = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 50, y: 1), // within tolerance of the 0,0 -> 100,0 chord
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
        ]
        let simplified = LineSimplifier.simplify(corner, tolerance: 2)
        #expect(simplified.count == 3)
        #expect(simplified.first == CGPoint(x: 0, y: 0))
        #expect(simplified.last == CGPoint(x: 100, y: 100))
    }

    @Test func endpointsAreAlwaysPreserved() {
        let noisy = (0...50).map { CGPoint(x: Double($0), y: Double($0 % 3)) }
        let simplified = LineSimplifier.simplify(noisy, tolerance: 5)
        #expect(simplified.first == noisy.first)
        #expect(simplified.last == noisy.last)
        #expect(simplified.count < noisy.count)
    }

    @Test func outputPreservesInputOrder() {
        let path = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 20, y: 40),
            CGPoint(x: 40, y: 0),
            CGPoint(x: 60, y: 40),
            CGPoint(x: 80, y: 0),
        ]
        let simplified = LineSimplifier.simplify(path, tolerance: 1)
        let xs = simplified.map(\.x)
        #expect(xs == xs.sorted())
    }

    /// Jitter suppression must not shorten a genuinely detailed trace so much
    /// that the measured distance drifts.
    @Test func simplificationKeepsTracedLengthClose() {
        let zigzag = (0...200).map {
            CGPoint(x: Double($0), y: sin(Double($0) / 4) * 8)
        }
        func length(_ pts: [CGPoint]) -> Double {
            zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
        let simplified = LineSimplifier.simplify(zigzag, tolerance: 2)
        #expect(simplified.count < zigzag.count)
        #expect(abs(length(simplified) - length(zigzag)) / length(zigzag) < 0.2)
    }
}

@MainActor
struct DistanceMarkerTests {
    private let abisko = CLLocationCoordinate2D(latitude: 68.35, longitude: 18.83)

    private static func north(_ start: CLLocationCoordinate2D, steps: Int) -> [CLLocationCoordinate2D] {
        (0...steps).map {
            CLLocationCoordinate2D(latitude: start.latitude + 0.01 * Double($0),
                                   longitude: start.longitude)
        }
    }

    /// Markers must sit at exact multiples of the spacing measured along the
    /// route, not at evenly spaced vertices.
    @Test func markersLandOnWholeKilometresAlongTheRoute() {
        // ~22 km due north from Abisko.
        let route = Self.north(abisko, steps: 20)
        let markers = DistanceMeasurement.distanceMarkers(along: route, spacing: 1_000)
        #expect(markers.count == Int(DistanceMeasurement.length(of: route) / 1_000))
        for (index, marker) in markers.enumerated() {
            #expect(marker.meters == Double(index + 1) * 1_000)
            let travelled = DistanceMeasurement.length(of: [route[0], marker.coordinate])
            #expect(abs(travelled - marker.meters) < 5)
        }
    }

    @Test func shortRouteHasNoMarkers() {
        let route = [abisko,
                     CLLocationCoordinate2D(latitude: abisko.latitude + 0.001, longitude: abisko.longitude)]
        #expect(DistanceMeasurement.distanceMarkers(along: route, spacing: 1_000).isEmpty)
    }

    /// Spacing widens with route length so a very long route can't produce
    /// hundreds of labels.
    @Test func markerSpacingWidensForLongRoutes() {
        #expect(DistanceMeasurement.markerSpacing(forRouteLength: 12_000) == 1_000)
        #expect(DistanceMeasurement.markerSpacing(forRouteLength: 200_000) == 5_000)
        #expect(DistanceMeasurement.markerSpacing(forRouteLength: 2_000_000) == 50_000)

        // Zoom decides too: the same 20 km route gets 1 km markers up close and
        // far coarser ones when zoomed out to a regional view.
        #expect(DistanceMeasurement.markerSpacing(forZoomLevel: 14, routeLength: 20_000) == 1_000)
        #expect(DistanceMeasurement.markerSpacing(forZoomLevel: 12, routeLength: 20_000) == 2_000)
        #expect(DistanceMeasurement.markerSpacing(forZoomLevel: 8, routeLength: 20_000) == 25_000)
        // The length cap still wins when it is the stricter of the two.
        #expect(DistanceMeasurement.markerSpacing(forZoomLevel: 14, routeLength: 2_000_000) == 50_000)

        let long = (0...400).map {
            CLLocationCoordinate2D(latitude: 60 + 0.01 * Double($0), longitude: 15)
        }
        #expect(DistanceMeasurement.distanceMarkers(along: long).count <= 60)
    }

    @Test func markerLabelIsWholeKilometres() {
        #expect(DistanceMeasurement.markerLabel(meters: 5_000).contains("5"))
        #expect(DistanceMeasurement.markerLabel(meters: 5_000).contains("km"))
    }
}
