import CoreLocation
import Foundation
import Testing

@testable import fjallkartan

struct FeaturedRoutesTests {
    private var catalogue: [FeaturedRoute] { FeaturedRoutes.all }

    @Test func catalogueDecodes() {
        #expect(!catalogue.isEmpty)
    }

    @Test func identifiersAreUnique() {
        let ids = Set(catalogue.map(\.id))
        #expect(ids.count == catalogue.count)

        let routeIds = Set(catalogue.map(\.route.id))
        #expect(routeIds.count == catalogue.count)
    }

    @Test func everyRouteHasGeometryAndName() {
        for entry in catalogue {
            #expect(entry.route.coordinates.count >= 2, "\(entry.id) has no geometry")
            #expect(!entry.name.isEmpty)
            #expect(!entry.subtitle.isEmpty)
            #expect(entry.route.displayName == entry.name)
        }
    }

    /// The stored length has to agree with the geometry, or the row would
    /// advertise a distance the drawn route doesn't have.
    @Test func storedDistanceMatchesGeometry() {
        for entry in catalogue {
            let measured = DistanceMeasurement.length(
                of: entry.route.coordinates.map(\.coordinate)
            )
            let drift = abs(measured - entry.route.meters) / entry.route.meters
            #expect(drift < 0.01, "\(entry.id): stored \(entry.route.meters) m, measured \(measured) m")
        }
    }

    /// A single stroke covering every vertex, so undo after loading behaves
    /// the same as it would for a hand-drawn route.
    @Test func strokeSizesCoverAllCoordinates() {
        for entry in catalogue {
            #expect(entry.route.strokeSizes.reduce(0, +) == entry.route.coordinates.count,
                    "\(entry.id) stroke sizes don't cover its coordinates")
        }
    }

    @Test func elevationsRespectTheProfileSampleCap() {
        for entry in catalogue {
            #expect(entry.route.elevations.count <= ElevationProfile.maxSamples,
                    "\(entry.id) carries more samples than the profile would use")
            #expect(entry.route.hasElevation, "\(entry.id) has no elevation data")
            #expect(entry.route.ascent > 0)
        }
    }

    /// Loading a featured route must go through exactly the same path as a
    /// saved one, since that is how the sheet presents it.
    @MainActor
    @Test func loadsIntoAMeasurementAsUnmodified() throws {
        let entry = try #require(catalogue.first)
        let measurement = DistanceMeasurement()
        measurement.load(entry.route)

        #expect(measurement.coordinates.count == entry.route.coordinates.count)
        #expect(!measurement.hasUnsavedChanges)
        #expect(measurement.canUndo)
    }
}
