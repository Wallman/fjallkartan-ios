import CoreLocation
import Foundation
import Testing

@testable import fjallkartan

@MainActor
struct SavedRoutesModelTests {
    private func makeModel() throws -> SavedRoutesModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedRoutesModelTests-\(UUID().uuidString)", isDirectory: true)
        return SavedRoutesModel(store: try SavedRouteStore(directory: url))
    }

    private func makeRoute(name: String? = nil) -> SavedRoute {
        SavedRoute(meters: 1000,
                   coordinates: [.init(CLLocationCoordinate2D(latitude: 68.35, longitude: 18.83))],
                   strokeSizes: [1],
                   name: name)
    }

    @Test func firstDefaultNameIsRouteOne() throws {
        let model = try makeModel()
        #expect(model.nextDefaultName() == SavedRoutesModel.defaultName(1))
    }

    @Test func defaultNameCountsUpWithSavedRoutes() throws {
        let model = try makeModel()
        model.save(makeRoute(name: SavedRoutesModel.defaultName(1)))
        #expect(model.nextDefaultName() == SavedRoutesModel.defaultName(2))
    }

    @Test func defaultNameSkipsNamesAlreadyTaken() throws {
        let model = try makeModel()
        model.save(makeRoute(name: SavedRoutesModel.defaultName(1)))
        model.save(makeRoute(name: SavedRoutesModel.defaultName(3)))
        model.save(makeRoute(name: "Sarek"))
        #expect(model.nextDefaultName() == SavedRoutesModel.defaultName(2))
    }

    @Test func renameUpdatesTheStoredRoute() throws {
        let model = try makeModel()
        let route = makeRoute()
        model.save(route)

        model.rename(route, to: "Kebnekaise")

        #expect(model.routes.count == 1)
        #expect(model.routes.first?.displayName == "Kebnekaise")
    }
}
