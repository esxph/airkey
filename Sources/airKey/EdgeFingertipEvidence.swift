import CoreGraphics
import Foundation

/// At the image border a partially clipped finger can become a confident but
/// misplaced joint. Confirm a large, isolated fingertip relocation with a second
/// sample before it can move the cursor or change the pinch state. Coherent
/// whole-hand travel is accepted immediately, including fast travel to edge keys.
struct EdgeFingertipEvidence {
    private struct Sample {
        let index: CGPoint
        let thumb: CGPoint
        let reference: CGPoint?
        let time: TimeInterval
        init(_ hand: HandObservation, at time: TimeInterval) {
            index = hand.indexTip
            thumb = hand.thumbTip
            reference = hand.wrist ?? hand.aimReference
            self.time = time
        }
        var nearEdge: Bool { [index, thumb].contains { min($0.x, 1 - $0.x, $0.y, 1 - $0.y) < 0.08 } }
    }
    private var accepted: Sample?
    private var pending: Sample?
    var awaitingConfirmation: Bool { pending != nil }

    mutating func accepts(_ hand: HandObservation, at time: TimeInterval) -> Bool {
        let sample = Sample(hand, at: time)
        // Vision may return a joint stuck exactly on the crop boundary. Holding
        // briefly is safer than interpreting that clipped geometry as a pinch.
        guard [sample.index, sample.thumb].allSatisfy({ point in
            point.isFinite && point.x > 0.002 && point.x < 0.998 && point.y > 0.002 && point.y < 0.998
        }) else { pending = nil; return false }
        guard let previous = accepted, time - previous.time <= 0.18 else {
            accepted = sample; pending = nil; return true
        }
        let indexMove = delta(previous.index, sample.index)
        let thumbMove = delta(previous.thumb, sample.thumb)
        let travel = max(length(indexMove), length(thumbMove))
        let disagreement = indexMove.distance(to: thumbMove)
        let palmTravel = sample.reference.flatMap { current in
            previous.reference.map { current.distance(to: $0) }
        } ?? 0
        let suspicious = (sample.nearEdge || previous.nearEdge)
            && travel > 0.085 && disagreement > 0.07 && palmTravel < travel * 0.35
        if suspicious {
            let confirmed = pending.map {
                time - $0.time <= 0.10 && sample.index.distance(to: $0.index) < 0.035
                    && sample.thumb.distance(to: $0.thumb) < 0.035
            } ?? false
            if !confirmed { pending = sample; return false }
        }
        accepted = sample
        pending = nil
        return true
    }

    private func delta(_ from: CGPoint, _ to: CGPoint) -> CGPoint { CGPoint(x: to.x - from.x, y: to.y - from.y) }
    private func length(_ point: CGPoint) -> CGFloat { hypot(point.x, point.y) }
}
