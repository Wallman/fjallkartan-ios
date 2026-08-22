import Foundation

/// One tile source. Both the base map layers and the two slope layers are
/// modelled here so every one of them can be located, sized for the offline
/// download estimate, and sampled the same way.
nonisolated enum TileServer: CaseIterable {
    case kartverket, lantmateriet, norwaySlope, swedenSlope, elevation

    /// Unlocalized, for logs and the tile metrics screen.
    var debugName: String {
        switch self {
        case .kartverket: return "Kartverket"
        case .lantmateriet: return "Lantmäteriet"
        case .norwaySlope: return "Slope NO"
        case .swedenSlope: return "Slope SE"
        case .elevation: return "Elevation"
        }
    }

    var isSlope: Bool {
        switch self {
        case .kartverket, .lantmateriet, .elevation: return false
        case .norwaySlope, .swedenSlope: return true
        }
    }

    /// Elevation tiles carry a packed height per pixel rather than a picture,
    /// so they are sampled by `ElevationService` and never added to the map.
    var isData: Bool {
        switch self {
        case .kartverket, .lantmateriet, .norwaySlope, .swedenSlope: return false
        case .elevation: return true
        }
    }

    var sourceMaximumZ: Int {
        switch self {
        case .kartverket: return 18
        case .lantmateriet: return 16
        case .norwaySlope: return 16
        case .swedenSlope: return 13
        case .elevation: return 12
        }
    }

    var offlineMaximumZ: Int {
        min(TilePyramid.maxZoom, sourceMaximumZ)
    }

    /// Lowest zoom worth downloading for offline use. Elevation is only ever
    /// sampled at `sourceMaximumZ`, never drawn, so the coarser levels the
    /// picture layers need would be pure waste — and are not published.
    var offlineMinimumZ: Int {
        isData ? sourceMaximumZ : TilePyramid.minZoom
    }

    /// Whether this layer is downloaded for offline use at `zoom`.
    func covers(zoom: Int) -> Bool {
        zoom >= offlineMinimumZ && zoom <= offlineMaximumZ
    }

    func url(z: Int, x: Int, y: Int) -> URL {
        RemoteSettings.shared.tileURL(server: self, z: z, x: x, y: y)
    }
}
