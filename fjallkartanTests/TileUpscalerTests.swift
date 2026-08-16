import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import fjallkartan

struct TileUpscalerTests {
    private func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// A tile whose four quadrants are four flat colours, so a magnified child
    /// can be checked against the quadrant it came from. Built with `CGContext`
    /// rather than `UIGraphics...`, which is main-thread only and would take
    /// the whole process down when Swift Testing runs suites in parallel.
    ///
    /// Sized well above the deepest zoom under test: `upscaledTile` returns the
    /// ancestor untouched when it has fewer pixels than children to split into.
    private func quadrantTile(size: Int = 16) -> Data {
        let ctx = context(width: size, height: size)
        // CGContext's origin is bottom-left while the image's first row is its
        // top, so the bottom row of quadrants is filled first.
        let colors: [CGColor] = [
            UIColor.blue.cgColor, UIColor.yellow.cgColor,
            UIColor.red.cgColor, UIColor.green.cgColor,
        ]
        let half = CGFloat(size / 2)
        for (index, color) in colors.enumerated() {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: CGFloat(index % 2) * half, y: CGFloat(index / 2) * half,
                            width: half, height: half))
        }
        return UIImage(cgImage: ctx.makeImage()!).pngData()!
    }

    /// Every distinct RGB triple in a PNG.
    private func colours(_ data: Data) -> Set<[UInt8]> {
        let cg = UIImage(data: data)!.cgImage!
        let ctx = context(width: cg.width, height: cg.height)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let raw = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var seen = Set<[UInt8]>()
        for index in 0..<(cg.width * cg.height) {
            let offset = index * 4
            seen.insert([raw[offset], raw[offset + 1], raw[offset + 2]])
        }
        return seen
    }

    @Test func eachChildMagnifiesItsOwnQuadrant() throws {
        let ancestor = (z: 13, x: 10, y: 20, data: quadrantTile())
        let expected: [(x: Int, y: Int, rgb: [UInt8])] = [
            (20, 40, [255, 0, 0]),
            (21, 40, [0, 255, 0]),
            (20, 41, [0, 0, 255]),
            (21, 41, [255, 255, 0]),
        ]
        for child in expected {
            let data = try #require(TileUpscaler.upscaledTile(
                ancestor: ancestor, targetZ: 14, targetX: child.x, targetY: child.y,
                interpolation: .none, outputSize: 32))
            // A child of a flat quadrant is that one colour and nothing else.
            #expect(colours(data) == [child.rgb])
        }
    }

    /// The slope palette is a legend: a magnified tile that blended two bands
    /// into a new shade would be showing a steepness class that doesn't exist.
    @Test func nearestNeighbourIntroducesNoNewColours() throws {
        let data = try #require(TileUpscaler.upscaledTile(
            ancestor: (z: 13, x: 0, y: 0, data: quadrantTile()),
            targetZ: 15, targetX: 1, targetY: 1,
            interpolation: .none, outputSize: 64))
        #expect(colours(data) == [[255, 0, 0]])
    }

    @Test func zoomingSeveralLevelsStaysInsideTheAncestor() throws {
        // z13 tile (10, 20) spans z16 tiles 80...87 and 160...167, so (87, 167)
        // is its bottom-right corner.
        let data = try #require(TileUpscaler.upscaledTile(
            ancestor: (z: 13, x: 10, y: 20, data: quadrantTile()),
            targetZ: 16, targetX: 87, targetY: 167,
            interpolation: .none, outputSize: 32))
        #expect(colours(data) == [[255, 255, 0]])
    }

    @Test func aPathOutsideTheAncestorIsRejected() {
        // (22, 40) belongs to ancestor x=11, not x=10.
        #expect(TileUpscaler.upscaledTile(
            ancestor: (z: 13, x: 10, y: 20, data: quadrantTile()),
            targetZ: 14, targetX: 22, targetY: 40,
            interpolation: .none, outputSize: 32) == nil)
    }

    @Test func anAncestorAtTheRequestedZoomIsReturnedUnchanged() throws {
        let tile = quadrantTile()
        let data = try #require(TileUpscaler.upscaledTile(
            ancestor: (z: 13, x: 10, y: 20, data: tile),
            targetZ: 13, targetX: 10, targetY: 20, interpolation: .none))
        #expect(data == tile)
    }
}
