import CoreLocation
import MapKit

struct PlaceResult: Identifiable {
    let id: String
    let name: String
    let placeType: String
    let municipality: String
    let coordinate: CLLocationCoordinate2D
}

final class PlaceSearchService {
    // Region covering Norway and Sweden.
    private static let searchRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 64.0, longitude: 16.0),
        span: MKCoordinateSpan(latitudeDelta: 22.0, longitudeDelta: 22.0)
    )

    func search(query: String) async throws -> [PlaceResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.region = Self.searchRegion
        request.resultTypes = [.address, .pointOfInterest]

        let response = try await MKLocalSearch(request: request).start()
        return Array(response.mapItems.prefix(10).map(PlaceResult.init))
    }
}

private extension PlaceResult {
    init(_ item: MKMapItem) {
        let p = item.placemark
        let name = item.name ?? p.locality ?? p.name ?? ""
        let municipality = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? ""
        let placeType: String
        if let category = item.pointOfInterestCategory {
            placeType = category.displayName
        } else if p.thoroughfare != nil {
            placeType = "Address"
        } else if p.locality != nil {
            placeType = "Place"
        } else {
            placeType = ""
        }
        self.init(
            id: "\(p.coordinate.latitude),\(p.coordinate.longitude),\(name)",
            name: name,
            placeType: placeType,
            municipality: municipality == name ? "" : municipality,
            coordinate: p.coordinate
        )
    }
}

private extension MKPointOfInterestCategory {
    var displayName: String {
        switch self {
        case .airport:               return "Airport"
        case .nationalPark:          return "National Park"
        case .park:                  return "Park"
        case .marina:                return "Marina"
        case .campground:            return "Campground"
        case .hotel:                 return "Hotel"
        case .restaurant:            return "Restaurant"
        case .cafe:                  return "Café"
        case .gasStation:            return "Gas Station"
        case .hospital:              return "Hospital"
        case .pharmacy:              return "Pharmacy"
        case .museum:                return "Museum"
        case .stadium:               return "Stadium"
        case .school:                return "School"
        case .university:            return "University"
        case .store:                 return "Store"
        case .fitnessCenter:         return "Fitness"
        case .laundry:               return "Laundry"
        case .postOffice:            return "Post Office"
        case .police:                return "Police"
        case .fireStation:           return "Fire Station"
        case .publicTransport:       return "Transit"
        case .parking:               return "Parking"
        case .atm:                   return "ATM"
        case .bank:                  return "Bank"
        default:                     return "Point of Interest"
        }
    }
}
