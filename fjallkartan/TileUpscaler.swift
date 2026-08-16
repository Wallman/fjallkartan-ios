import CoreGraphics
import UIKit

/// Builds a deep-zoom tile by magnifying the ancestor tile that contains it.
nonisolated enum TileUpscaler {
    static func upscaledTile(ancestor: (z: Int, x: Int, y: Int, data: Data),
                             targetZ: Int,
                             targetX: Int,
                             targetY: Int,
                             interpolation: CGInterpolationQuality = .medium,
                             outputSize: Int = 256) -> Data? {
        let levels = targetZ - ancestor.z
        guard levels > 0, let cg = UIImage(data: ancestor.data)?.cgImage else { return ancestor.data }

        let n = 1 << levels
        let w = cg.width, h = cg.height
        guard w >= n, h >= n else { return ancestor.data }
        let cropW = w / n
        let cropH = h / n
        let subX = targetX - ancestor.x * n
        let subY = targetY - ancestor.y * n
        guard subX >= 0, subY >= 0, subX < n, subY < n else { return nil }
        let cropRect = CGRect(x: subX * cropW, y: subY * cropH, width: cropW, height: cropH)
        guard let cropped = cg.cropping(to: cropRect) else { return nil }

        guard let ctx = CGContext(data: nil, width: outputSize, height: outputSize,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = interpolation
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out).pngData()
    }
}
