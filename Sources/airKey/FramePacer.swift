import Foundation

/// Bounds expensive Vision work independently of the camera's native frame rate.
struct FramePacer {
    private var nextFrame: TimeInterval?
    private var lastHand: TimeInterval?
    mutating func shouldProcess(at time: TimeInterval) -> Bool {
        let idle = lastHand.map { time - $0 > 2 } ?? false
        let interval = idle ? 0.1 : 1.0 / 30
        // Keep cadence rather than restarting the interval at each arrival. Small
        // camera jitter otherwise turns a nominal 30 fps stream into 15–20 fps.
        if let nextFrame, time < nextFrame - 0.008 { return false }
        nextFrame = max((nextFrame ?? time) + interval, time + interval * 0.5)
        if lastHand == nil { lastHand = time }
        return true
    }
    mutating func observedHands(_ found: Bool, at time: TimeInterval) {
        if found {
            lastHand = time
            if let nextFrame, nextFrame - time > 1.0 / 30 { self.nextFrame = time + 1.0 / 30 }
        }
    }
}
