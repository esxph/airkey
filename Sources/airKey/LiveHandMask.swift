import CoreGraphics
import CoreVideo
import Foundation

/// Landmark-guided, adaptive pixel segmentation. Inspired by Sánchez-Brizuela
/// et al., "Lightweight real-time hand segmentation leveraging MediaPipe landmark
/// detection" (2023), https://doi.org/10.1007/s10055-023-00858-0.
///
/// Samples CIELab chroma inside the current palm/finger cores, then grows only
/// matching connected pixels within a bounded hand region. No fixed skin-color
/// threshold, stored training images, extra network, or full-frame fallback.
struct LiveHandMask {
    private static let linearRGB: [Float] = (0...255).map {
        let value = Float($0) / 255
        return value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
    }

    func makeMask(buffer: CVPixelBuffer, poses: [HandMaskPose]) -> CGImage? {
        guard !poses.isEmpty, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let scale = min(1, 320 / Double(sourceWidth))
        let width = max(1, Int(Double(sourceWidth) * scale)), height = max(1, Int(Double(sourceHeight) * scale))
        let count = width * height
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
        var combined = [UInt8](repeating: 0, count: count)

        for pose in poses.prefix(2) {
            guard let region = Region(pose: pose, width: width, height: height) else { continue }
            var chroma = [SIMD2<Float>](repeating: .zero, count: count)
            var aSamples: [Float] = [], bSamples: [Float] = []
            for offset in region.offsets {
                let x = offset % width, y = offset / width
                let pixel = min(sourceHeight - 1, y * sourceHeight / height) * stride
                    + min(sourceWidth - 1, x * sourceWidth / width) * 4
                let value = Self.labChroma(r: bytes[pixel + 2], g: bytes[pixel + 1], b: bytes[pixel])
                chroma[offset] = value
                if region.core[offset] != 0 {
                    aSamples.append(value.x); bSamples.append(value.y)
                }
            }
            guard aSamples.count >= 12 else { continue }
            aSamples.sort(); bSamples.sort()
            func bounds(_ samples: [Float]) -> ClosedRange<Float> {
                let q1 = samples[samples.count / 4], q3 = samples[samples.count * 3 / 4]
                let margin = max(3, min(9, (q3 - q1) * 0.65))
                return (q1 - margin)...(q3 + margin)
            }
            let aRange = bounds(aSamples), bRange = bounds(bSamples)
            var eligible = [UInt8](repeating: 0, count: count)
            var visited = [UInt8](repeating: 0, count: count)
            var queue: [Int] = []
            queue.reserveCapacity(region.offsets.count)
            for offset in region.offsets {
                let value = chroma[offset]
                if aRange.contains(value.x), bRange.contains(value.y) {
                    eligible[offset] = 1
                    if region.core[offset] != 0 { visited[offset] = 1; queue.append(offset) }
                }
            }
            // Remove disconnected patches (e.g. a skin-colored wall between two
            // fingers). Only pixels connected to current hand evidence survive.
            var head = 0
            while head < queue.count {
                let offset = queue[head]; head += 1
                let x = offset % width, y = offset / width
                func visit(_ neighbor: Int) {
                    if eligible[neighbor] != 0, visited[neighbor] == 0 {
                        visited[neighbor] = 1; queue.append(neighbor)
                    }
                }
                if x > 0 { visit(offset - 1) }
                if x + 1 < width { visit(offset + 1) }
                if y > 0 { visit(offset - width) }
                if y + 1 < height { visit(offset + width) }
            }
            // Close one-mask-pixel cracks caused by creases and uneven lighting.
            // Work at half capture resolution; large finger gaps stay open.
            var dilated = [UInt8](repeating: 0, count: count)
            for offset in queue {
                let x = offset % width, y = offset / width
                for row in max(0, y - 1)...min(height - 1, y + 1) {
                    for column in max(0, x - 1)...min(width - 1, x + 1) { dilated[row * width + column] = 1 }
                }
            }
            for offset in region.offsets {
                if visited[offset] != 0 { combined[offset] = 255; continue }
                let x = offset % width, y = offset / width
                guard x > 0, x + 1 < width, y > 0, y + 1 < height else { continue }
                var filled = true
                for row in (y - 1)...(y + 1) { for column in (x - 1)...(x + 1) {
                    if dilated[row * width + column] == 0 { filled = false }
                } }
                if filled { combined[offset] = 255 }
            }
        }
        guard combined.contains(255), let provider = CGDataProvider(data: Data(combined) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func labChroma(r: UInt8, g: UInt8, b: UInt8) -> SIMD2<Float> {
        let red = linearRGB[Int(r)], green = linearRGB[Int(g)], blue = linearRGB[Int(b)]
        let x = (0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / 0.95047
        let y = 0.2126729 * red + 0.7151522 * green + 0.0721750 * blue
        let z = (0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / 1.08883
        func f(_ value: Float) -> Float { value > 0.008856 ? cbrtf(value) : 7.787 * value + 16 / 116 }
        let fy = f(y)
        return SIMD2(500 * (f(x) - fy), 200 * (fy - f(z)))
    }

    private struct Region {
        var core: [UInt8]
        var support: [UInt8]
        var offsets: [Int] = []
        let width: Int
        let height: Int

        init?(pose: HandMaskPose, width: Int, height: Int) {
            let points = pose.points.filter { $0.value.isFinite && (0...1).contains($0.value.x) && (0...1).contains($0.value.y) }
                .mapValues { CGPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height)) }
            guard let wrist = points[.wrist], let index = points[.indexMCP], let little = points[.littleMCP],
                  points.count >= 9 else { return nil }
            let palmWidth = index.distance(to: little)
            let knuckles = CGPoint(x: (index.x + little.x) / 2, y: (index.y + little.y) / 2)
            let palmLength = wrist.distance(to: knuckles)
            // Side-on hands have a narrow knuckle span; palm length gives a
            // bounded fallback so the mask doesn't collapse during a pinch.
            let span = max(palmWidth, palmLength * 0.65)
            guard span >= 5, span < CGFloat(width) * 0.65 else { return nil }
            self.width = width; self.height = height
            core = [UInt8](repeating: 0, count: width * height)
            support = core
            let palmPoints = [HandMaskPose.Joint.wrist, .thumbCMC, .indexMCP, .middleMCP, .ringMCP, .littleMCP].compactMap { points[$0] }
            let hull = Self.convexHull(palmPoints)
            guard hull.count >= 3 else { return nil }
            let center = CGPoint(x: hull.map(\.x).reduce(0, +) / CGFloat(hull.count),
                                 y: hull.map(\.y).reduce(0, +) / CGFloat(hull.count))
            fill(hull.map { center.interpolated(to: $0, fraction: 0.68) }, seed: true)
            fill(hull.map { center.interpolated(to: $0, fraction: 1.13) }, seed: false)
            for (finger, chain) in HandMaskPose.fingers.enumerated() {
                for segment in 0..<(chain.count - 1) {
                    guard let from = points[chain[segment]], let to = points[chain[segment + 1]] else { continue }
                    let radius = span * (finger == 0 ? 0.19 : 0.15) * (1 - CGFloat(segment) * 0.09)
                    capsule(from, to, radius: max(1, radius * 0.28), seed: true)
                    capsule(from, to, radius: max(2, radius * 1.65), seed: false)
                }
            }
            // Cut the forearm off at the wrist, even if its color matches.
            let axis = CGPoint(x: knuckles.x - wrist.x, y: knuckles.y - wrist.y)
            let axisLength = max(1, hypot(axis.x, axis.y))
            for offset in support.indices where support[offset] != 0 {
                let p = CGPoint(x: CGFloat(offset % width) + 0.5, y: CGFloat(offset / width) + 0.5)
                let distance = ((p.x - wrist.x) * axis.x + (p.y - wrist.y) * axis.y) / axisLength
                if distance >= -span * 0.07 { offsets.append(offset) }
                else { support[offset] = 0; core[offset] = 0 }
            }
        }

        mutating func capsule(_ from: CGPoint, _ to: CGPoint, radius: CGFloat, seed: Bool) {
            let rect = CGRect(x: min(from.x, to.x) - radius, y: min(from.y, to.y) - radius,
                              width: abs(to.x - from.x) + radius * 2, height: abs(to.y - from.y) + radius * 2)
            let dx = to.x - from.x, dy = to.y - from.y, squared = max(0.0001, dx * dx + dy * dy)
            raster(rect, seed: seed) { p in
                let t = max(0, min(1, ((p.x - from.x) * dx + (p.y - from.y) * dy) / squared))
                let x = p.x - from.x - t * dx, y = p.y - from.y - t * dy
                return x * x + y * y <= radius * radius
            }
        }

        mutating func fill(_ polygon: [CGPoint], seed: Bool) {
            let xs = polygon.map(\.x), ys = polygon.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
            raster(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), seed: seed) { p in
                for index in polygon.indices {
                    let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                    if Self.cross(a, b, p) < 0 { return false }
                }
                return true
            }
        }

        mutating func raster(_ rect: CGRect, seed: Bool, contains: (CGPoint) -> Bool) {
            let left = max(0, Int(floor(rect.minX))), right = min(width - 1, Int(ceil(rect.maxX)))
            let top = max(0, Int(floor(rect.minY))), bottom = min(height - 1, Int(ceil(rect.maxY)))
            guard left <= right, top <= bottom else { return }
            for y in top...bottom { for x in left...right where contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                let offset = y * width + x
                support[offset] = 1
                if seed { core[offset] = 1 }
            } }
        }

        static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
            let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
            func half(_ values: [CGPoint]) -> [CGPoint] {
                var result: [CGPoint] = []
                for p in values {
                    while result.count >= 2, cross(result[result.count - 2], result[result.count - 1], p) <= 0 { result.removeLast() }
                    result.append(p)
                }
                return result
            }
            return Array(half(sorted).dropLast()) + Array(half(sorted.reversed()).dropLast())
        }
    }
}
