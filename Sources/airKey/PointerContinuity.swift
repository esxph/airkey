import Foundation

/// Preserve the last drawn position briefly, without pretending it is a tracked
/// hand. This does not smooth, predict, or delay fresh movement or gesture edges.
struct PointerContinuity {
    private var last: [HandSide: (frame: HandFrame, seen: TimeInterval)] = [:]
    mutating func apply(to input: HandFrame) -> HandFrame {
        var frame = input
        for side in HandSide.allCases {
            if frame.aiming.contains(side) || frame.tracked.contains(side) {
                var snapshot = input
                snapshot.cameraImage = nil // retain geometry, never old video
                last[side] = (snapshot, input.timestamp)
            } else if let saved = last[side], input.imageSize == saved.frame.imageSize,
                      input.timestamp - saved.seen <= 0.30 {
                frame.heldPointers.insert(side)
                frame.cursors[side] = saved.frame.cursors[side]
                frame.tapCursors[side] = saved.frame.tapCursors[side]
                frame.visuals[side] = saved.frame.visuals[side]
            } else { last[side] = nil }
        }
        return frame
    }
}
