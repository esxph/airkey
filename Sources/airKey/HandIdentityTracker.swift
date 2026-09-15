import CoreGraphics
import Foundation

struct HandCandidate {
    var observation: HandObservation
    let reportedSide: HandSide?
    var position: CGPoint { observation.wrist ?? observation.aimReference ?? observation.pointer }
}

/// Keep an already identified hand when Vision briefly changes or loses its
/// chirality label. With two hands, choose a one-to-one spatial assignment.
struct HandIdentityTracker {
    private struct Track { let position: CGPoint; let seen: TimeInterval }
    private var tracks: [HandSide: Track] = [:]

    mutating func assign(_ input: [HandCandidate], at time: TimeInterval) -> [HandObservation] {
        tracks = tracks.filter { time - $0.value.seen <= 0.45 }
        let candidates = Array(input.filter { $0.position.isFinite }.prefix(2))
        var best: [HandSide?] = []
        var bestCost = Double.infinity
        func search(_ index: Int, used: Set<HandSide>, assignment: [HandSide?], cost: Double) {
            guard index < candidates.count else {
                if cost < bestCost { bestCost = cost; best = assignment }
                return
            }
            let candidate = candidates[index]
            search(index + 1, used: used, assignment: assignment + [nil], cost: cost + 1)
            for side in HandSide.allCases where !used.contains(side) {
                let matchCost: Double
                if let track = tracks[side], candidate.position.distance(to: track.position) <= 0.12 + min(0.15, time - track.seen) {
                    matchCost = candidate.position.distance(to: track.position) + (candidate.reportedSide == side ? 0 : 0.015)
                } else if candidate.reportedSide == side {
                    matchCost = 0.4
                } else { continue }
                search(index + 1, used: used.union([side]), assignment: assignment + [side], cost: cost + matchCost)
            }
        }
        search(0, used: [], assignment: [], cost: 0)
        return zip(candidates, best).compactMap { candidate, side in
            guard let side else { return nil }
            tracks[side] = Track(position: candidate.position, seen: time)
            var observation = candidate.observation
            observation.side = side
            return observation
        }
    }
}
