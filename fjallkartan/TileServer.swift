import CoreGraphics
import Foundation

/// One tile source. Both the base map layers and the two slope layers are
/// modelled here so every one of them can be cached, downloaded offline and
/// looked up in `OfflineTileStore` through the same code path.
nonisolated enum TileServer: CaseIterable {
    case kartverket, lantmateriet, norwaySlope, swedenSlope

    /// Encoding used as the `server` column in `OfflineTileStore`.
    /// Persisted, so existing values must never be renumbered.
    var storeCode: Int {
        switch self {
        case .kartverket: return 0
        case .lantmateriet: return 1
        case .norwaySlope: return 2
        case .swedenSlope: return 3
        }
    }

    var isSlope: Bool {
        switch self {
        case .kartverket, .lantmateriet: return false
        case .norwaySlope, .swedenSlope: return true
        }
    }

    var sourceMaximumZ: Int {
        switch self {
        case .kartverket, .lantmateriet: return 18
        case .norwaySlope: return 16
        case .swedenSlope: return 13
        }
    }

    var offlineMaximumZ: Int {
        min(TilePyramid.maxZoom, sourceMaximumZ)
    }

    /// Slope pixels are class labels, so a magnified tile must not blend them.
    var upscaleInterpolation: CGInterpolationQuality {
        isSlope ? .none : .medium
    }

    func url(z: Int, x: Int, y: Int) -> URL {
        RemoteSettings.shared.tileURL(server: self, z: z, x: x, y: y)
    }
}
