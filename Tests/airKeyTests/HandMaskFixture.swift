import CoreGraphics
import CoreVideo
import Foundation
@testable import airKey

/// Synthetic pixel/landmark fixture for segmentation checks, never an app asset.
struct HandMaskFixture {
    static let width = 640, height = 480
    static let points: [HandMaskPose.Joint: CGPoint] = [
        .wrist: CGPoint(x: 245, y: 365),
        .thumbCMC: CGPoint(x: 213, y: 300), .thumbMP: CGPoint(x: 175, y: 286), .thumbIP: CGPoint(x: 155, y: 264), .thumbTip: CGPoint(x: 134, y: 240),
        .indexMCP: CGPoint(x: 202, y: 238), .indexPIP: CGPoint(x: 190, y: 183), .indexDIP: CGPoint(x: 186, y: 146), .indexTip: CGPoint(x: 184, y: 114),
        .middleMCP: CGPoint(x: 237, y: 230), .middlePIP: CGPoint(x: 238, y: 162), .middleDIP: CGPoint(x: 240, y: 121), .middleTip: CGPoint(x: 242, y: 94),
        .ringMCP: CGPoint(x: 273, y: 244), .ringPIP: CGPoint(x: 280, y: 188), .ringDIP: CGPoint(x: 286, y: 152), .ringTip: CGPoint(x: 290, y: 131),
        .littleMCP: CGPoint(x: 303, y: 268), .littlePIP: CGPoint(x: 327, y: 229), .littleDIP: CGPoint(x: 338, y: 201), .littleTip: CGPoint(x: 343, y: 182)
    ]
    static var pose: HandMaskPose {
        HandMaskPose(points: points.mapValues { CGPoint(x: $0.x / CGFloat(width), y: 1 - $0.y / CGFloat(height)) })
    }
    static func buffer(skin: SIMD3<UInt8> = SIMD3(176, 119, 85), shift: Int = 0, includeOriginal: Bool = false) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let result = buffer!
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let bytes = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(result)
        let palm = [HandMaskPose.Joint.wrist, .thumbCMC, .indexMCP, .middleMCP, .ringMCP, .littleMCP].map { points[$0]! }
        let segments = HandMaskPose.fingers.flatMap { chain in
            (0..<(chain.count - 1)).map { (points[chain[$0]]!, points[chain[$0 + 1]]!) }
        }
        func insidePalm(_ p: CGPoint) -> Bool {
            var inside = false
            for i in palm.indices {
                let a = palm[i], b = palm[(i + 1) % palm.count]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
            return inside
        }
        func insideFinger(_ p: CGPoint) -> Bool {
            segments.contains { a, b in
                let dx = b.x - a.x, dy = b.y - a.y
                let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
                return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy) <= 10
            }
        }
        for y in 0..<height { for x in 0..<width {
            let p = CGPoint(x: x - shift, y: y)
            let original = CGPoint(x: x, y: y)
            let isHand = insidePalm(p) || insideFinger(p) || (includeOriginal && (insidePalm(original) || insideFinger(original)))
            let similarObject = x > 475 && x < 580 && y > 80 && y < 240
            let forearm = x > 225 + shift && x < 270 + shift && y >= 360
            var color: SIMD3<UInt8> = isHand || similarObject || forearm ? skin : SIMD3(36, 72, 100)
            if isHand {
                let shade: Float = y % 17 < 2 ? 0.65 : 0.88 + 0.12 * Float(x % 60) / 60
                color = SIMD3(UInt8(Float(color.x) * shade), UInt8(Float(color.y) * shade), UInt8(Float(color.z) * shade))
            }
            let offset = y * stride + x * 4
            bytes[offset] = color.z; bytes[offset + 1] = color.y; bytes[offset + 2] = color.x; bytes[offset + 3] = 255
        } }
        return result
    }
}
