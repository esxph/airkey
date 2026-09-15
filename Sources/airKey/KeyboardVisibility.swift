import CoreGraphics
import Foundation

/// Timed presentation only; this never modifies pointer coordinates or gestures.
struct KeyboardVisibility {
    enum State: Equatable { case visible, faded, tucked, hidden }
    var fadeEnabled = true
    var tuckEnabled = true
    var fullScreenEnabled = true
    private(set) var state: State = .hidden
    private(set) var lastActivity: TimeInterval = 0
    private var fullScreenGraceUntil: TimeInterval = 0
    private var anchors: [HandSide: CGPoint] = [:]

    mutating func show(at time: TimeInterval) {
        state = .visible; lastActivity = time; fullScreenGraceUntil = time + 15
        anchors.removeAll()
    }
    mutating func hide() { state = .hidden; anchors.removeAll() }
    mutating func tuck() { state = .tucked; anchors.removeAll() }
    mutating func activity(at time: TimeInterval) {
        guard state == .visible || state == .faded else { return }
        state = .visible; lastActivity = max(lastActivity, time)
    }
    mutating func observe(_ frame: HandFrame, size: CGSize, hasPress: Bool) {
        let projection = CameraProjection(imageSize: frame.imageSize, viewSize: size)
        if state == .visible, hasPress, !frame.tracked.isEmpty { activity(at: frame.timestamp) }
        for side in HandSide.allCases {
            guard frame.tracked.contains(side), let raw = frame.cursors[side] else { anchors[side] = nil; continue }
            let point = projection.project(raw)
            let waking = state == .faded
            if waking, frame.phases[side] != .open || !CGRect(origin: .zero, size: size).contains(point) {
                anchors[side] = point
                continue
            }
            if let anchor = anchors[side], point.distance(to: anchor) >= (waking ? 24 : 6) {
                activity(at: frame.timestamp); anchors[side] = point
            } else if anchors[side] == nil {
                anchors[side] = point
                if !waking { activity(at: frame.timestamp) }
            }
        }
    }
    mutating func update(at time: TimeInterval, fullScreen: Bool, editing: Bool, busy: Bool) {
        guard state == .visible || state == .faded else { return }
        if busy { activity(at: time); return }
        let idle = max(0, time - lastActivity)
        if fullScreenEnabled, fullScreen, !editing, time >= fullScreenGraceUntil, idle >= 2 {
            tuck()
        } else if tuckEnabled, idle >= 45 { tuck() }
        else { state = fadeEnabled && idle >= 8 ? .faded : .visible }
    }
}
