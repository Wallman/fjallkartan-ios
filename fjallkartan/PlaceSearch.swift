import CoreLocation
import Foundation

struct PlaceResult: Identifiable {
    let id: Int
    let name: String
    let placeType: String
    let municipality: String
    let coordinate: CLLocationCoordinate2D
}

final class PlaceSearchService {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    func search(query: String) async throws -> [PlaceResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://ws.geonorge.no/stedsnavn/v1/navn")!
        components.queryItems = [
            URLQueryItem(name: "sok", value: trimmed + "*"),
            URLQueryItem(name: "fuzzy", value: "true"),
            URLQueryItem(name: "treffPerSide", value: "10"),
            URLQueryItem(name: "side", value: "1"),
            // ETRS89 geographic coords (≈ WGS84), so nord ≈ latitude, øst ≈ longitude.
            URLQueryItem(name: "utkoordsys", value: "4258"),
        ]

        let (data, _) = try await session.data(from: components.url!)
        let response = try JSONDecoder().decode(StedsnamnResponse.self, from: data)
        return response.navn.map(PlaceResult.init)
    }
}

// MARK: - Response models

private struct StedsnamnResponse: Decodable {
    let navn: [StedsnamnNavn]
}

private struct StedsnamnNavn: Decodable {
    let stedsnummer: Int
    let skrivemåte: String
    let navneobjekttype: String
    let kommuner: [StedsnamnKommune]
    let representasjonspunkt: StedsnamnRepresentasjonspunkt
}

private struct StedsnamnKommune: Decodable {
    let kommunenavn: String
}

private struct StedsnamnRepresentasjonspunkt: Decodable {
    let nord: Double
    let øst: Double
}

private extension PlaceResult {
    init(_ navn: StedsnamnNavn) {
        self.init(
            id: navn.stedsnummer,
            name: navn.skrivemåte,
            placeType: navn.navneobjekttype,
            municipality: navn.kommuner.first?.kommunenavn ?? "",
            coordinate: CLLocationCoordinate2D(
                latitude: navn.representasjonspunkt.nord,
                longitude: navn.representasjonspunkt.øst
            )
        )
    }
}
