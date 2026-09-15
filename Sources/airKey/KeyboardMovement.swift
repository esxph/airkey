import CoreGraphics

enum KeyboardDragEvent {
    case began(CGPoint)
    case moved(CGPoint)
    case paused
    case ended
}

/// Hand coordinates stay camera-relative when the window moves. Every update
/// is measured from a fixed anchor, never added to the already-moved window.
struct KeyboardMovement {
    private var anchor: CGPoint?
    private var origin: CGPoint?

    mutating func begin(at point: CGPoint, origin: CGPoint) {
        self.anchor = point; self.origin = origin
    }
    mutating func pause() { anchor = nil; origin = nil }

    mutating func move(to point: CGPoint, currentOrigin: CGPoint) -> CGPoint? {
        guard point.isFinite else { return nil }
        guard let anchor, let origin else {
            begin(at: point, origin: currentOrigin)
            return nil // reacquisition rebases without jumping
        }
        return CGPoint(x: origin.x + point.x - anchor.x, y: origin.y - (point.y - anchor.y))
    }

    static func constrain(_ frame: CGRect, to area: CGRect) -> CGRect {
        var frame = frame
        // Keep the top-right handle reachable even on a display smaller than the panel.
        frame.origin.x = min(max(frame.minX, area.minX + min(0, area.width - frame.width)), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY + min(0, area.height - frame.height)), area.maxY - frame.height)
        return frame
    }
}
