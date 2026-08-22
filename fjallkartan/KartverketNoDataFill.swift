import UIKit


/// Kartverket's no-data fill is transparent at low zoom but an opaque cream
/// (255,255,230) from ~z15. Converts it to transparent.
enum KartverketNoDataFill {
    
    static func rewritten(_ data: Data?) -> Data? {
        guard let data, let cg = UIImage(data: data)?.cgImage else { return data }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return data }
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: h * bytesPerRow)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return data
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rewroteAnyPixel = false
        var i = 0
        while i < buf.count {
            if buf[i] > 250, buf[i + 1] > 250, buf[i + 2] >= 222, buf[i + 2] <= 240 {
                buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; buf[i + 3] = 0
                rewroteAnyPixel = true
            }
            i += 4
        }
        guard rewroteAnyPixel else { return data }
        guard let out = ctx.makeImage() else { return data }
        return UIImage(cgImage: out).pngData() ?? data
    }
}
