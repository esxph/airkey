import CoreGraphics
import Foundation

struct HandIntentEvidence: Sendable {
    let side: HandSide
    let idleDuration: TimeInterval
    let otherActivityAge: TimeInterval
    var canTeach: Bool { idleDuration >= 0.2 && otherActivityAge <= 1.2 }
}

/// Short-lived motion history; no camera samples are persisted.
struct HandIntentGuard {
    private struct Motion {
        var anchor: CGPoint
        var usesWrist: Bool
        var seen: TimeInterval
        var moved: TimeInterval
        var typed: TimeInterval = -.infinity
        var updated: TimeInterval
    }
    private var hands: [HandSide: Motion] = [:]

    mutating func update(_ frame: HandFrame, projection: CameraProjection, cell: CGSize) {
        for side in HandSide.allCases {
            guard frame.tracked.contains(side), let cursor = frame.cursors[side], cursor.isFinite else {
                hands[side] = nil
                continue
            }
            let wrist = frame.visuals[side]?.wrist.flatMap { $0.isFinite ? $0 : nil }
            let point = projection.project(wrist ?? cursor)
            let normalized = CGPoint(x: point.x / max(1, cell.width), y: point.y / max(1, cell.height))
            let now = frame.timestamp
            guard var motion = hands[side], now - motion.updated <= 0.2,
                  motion.usesWrist == (wrist != nil) else {
                hands[side] = Motion(anchor: normalized, usesWrist: wrist != nil, seen: now, moved: now, updated: now)
                continue
            }
            // A wrist can move during a stroke. A fingertip midpoint is only reliable
            // while fully open: closure itself must not count as deliberate aiming.
            if wrist != nil || (frame.phases[side] == .open && (frame.pinchScores[side] ?? 0) >= frame.releaseThreshold) {
                if normalized.distance(to: motion.anchor) >= 0.22 {
                    motion.anchor = normalized
                    motion.moved = now
                }
            }
            motion.updated = now
            hands[side] = motion
        }
    }

    func evidence(for side: HandSide, at now: TimeInterval, candidates: Set<HandSide>) -> HandIntentEvidence? {
        let other: HandSide = side == .left ? .right : .left
        guard let own = hands[side], let peer = hands[other] else { return nil }
        var activity = peer.typed
        // Evaluate simultaneous beginnings from the same snapshot, independent of event order.
        if candidates.contains(other), peer.moved > peer.seen, now - peer.moved < 0.35 { activity = now }
        return HandIntentEvidence(side: side, idleDuration: now - max(own.seen, own.moved, own.typed),
                                  otherActivityAge: now - activity)
    }

    func shouldIgnore(_ evidence: HandIntentEvidence?, corrections: Int) -> Bool {
        guard let evidence else { return false }
        let strength = Double(min(6, max(0, corrections))) / 6
        return evidence.idleDuration >= 0.65 - 0.3 * strength
            && evidence.otherActivityAge <= 0.85 + 0.35 * strength
    }

    mutating func accepted(_ side: HandSide, at time: TimeInterval) { hands[side]?.typed = time }
    mutating func reset() { hands.removeAll() }
}
