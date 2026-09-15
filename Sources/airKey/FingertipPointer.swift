import CoreGraphics
import Foundation

/// Whole-hand movement and finger movement share one coordinate system. Filter
/// the two guide endpoints together, then place the circle at their midpoint.
struct FingertipPointer {
    private(set) var index: CGPoint?
    private(set) var thumb: CGPoint?
    private var previousIndex: CGPoint?
    private var previousThumb: CGPoint?

    mutating func update(index rawIndex: CGPoint, thumb rawThumb: CGPoint, dt: TimeInterval) -> CGPoint {
        let dt = max(0.001, dt)
        let travel = max(rawIndex.distance(to: previousIndex ?? rawIndex), rawThumb.distance(to: previousThumb ?? rawThumb))
        let cutoff = 10 + min(50, 30 * travel / dt)
        let alpha = 1 / (1 + 1 / (2 * CGFloat.pi * cutoff * dt))
        index = index?.interpolated(to: rawIndex, fraction: alpha) ?? rawIndex
        thumb = thumb?.interpolated(to: rawThumb, fraction: alpha) ?? rawThumb
        previousIndex = rawIndex
        previousThumb = rawThumb
        return CGPoint(x: (index!.x + thumb!.x) / 2, y: (index!.y + thumb!.y) / 2)
    }
}
