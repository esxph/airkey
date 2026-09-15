import CoreGraphics
import Foundation

/// Only resolves narrow border ambiguity. Landing in a new key's interior always wins.
struct TapTargetResolver {
    private struct Sample { let key: String; let time: TimeInterval }
    private var history: [HandSide: [Sample]] = [:]

    mutating func observe(side: HandSide, point: CGPoint, time: TimeInterval, layout: KeyboardLayout, size: CGSize) {
        var samples = (history[side] ?? []).filter { time - $0.time <= 0.16 }
        if let key = layout.hitKey(at: point, in: size) { samples.append(Sample(key: key, time: time)) }
        else { samples.removeAll() }
        history[side] = Array(samples.suffix(16))
    }

    func resolve(side: HandSide, point: CGPoint, time: TimeInterval, layout: KeyboardLayout, size: CGSize) -> String? {
        let direct = layout.hitKey(at: point, in: size)
        let frames = layout.keyFrames(in: size)
        if let direct, let rect = frames[direct], rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.16).contains(point) {
            return direct
        }
        let samples = (history[side] ?? []).filter { time - $0.time <= 0.16 }
        guard let last = samples.last, let rect = frames[last.key],
              // Include the layout's 10-point gap before the neighboring border.
              rect.insetBy(dx: -min(20, 10 + rect.width * 0.16), dy: -min(20, 10 + rect.height * 0.16)).contains(point) else { return direct }
        // Two contiguous samples establish an approach, without requiring a dwell
        // before ordinary presses. Never attract from a different, earlier key.
        let run = samples.reversed().prefix { $0.key == last.key }
        guard let first = run.last, last.time - first.time >= 0.025 else { return direct }
        return last.key
    }

    mutating func reset(_ side: HandSide? = nil) {
        if let side { history[side] = nil } else { history.removeAll() }
    }
}
