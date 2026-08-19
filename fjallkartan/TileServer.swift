import CoreGraphics
import Foundation

/// One tile source. Both the base map layers and the two slope layers are
/// modelled here so every one of them can be cached, downloaded offline and
/// looked up in `OfflineTileStore` through the same code path.
nonisolated enum TileServer: CaseIterable {
    case kartverket, lantmateriet, norwaySlope, swedenSlope, elevation

    /// Encoding used as the `server` column in `OfflineTileStore`.
    /// Persisted, so existing values must never be renumbered.
    var storeCode: Int {
        switch self {
        case .kartverket: return 0
        case .lantmateriet: return 1
        case .norwaySlope: return 2
        case .swedenSlope: return 3
        case .elevation: return 4
        }
    }

    init?(storeCode: Int) {
        guard let match = TileServer.allCases.first(where: { $0.storeCode == storeCode }) else { return nil }
        self = match
    }

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

    /// Slope pixels are class labels, so a magnified tile must not blend them.
    /// Elevation pixels are worse: the height is a 16-bit value split across R
    /// and G, so interpolating the high byte on its own invents 256 m steps.
    var upscaleInterpolation: CGInterpolationQuality {
        (isSlope || isData) ? .none : .medium
    }

    func url(z: Int, x: Int, y: Int) -> URL {
        RemoteSettings.shared.tileURL(server: self, z: z, x: x, y: y)
    }
}
