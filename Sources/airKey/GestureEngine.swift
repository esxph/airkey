import CoreGraphics
import Foundation

/// Pinches, the circle, and fingertip guides share the same midpoint.
/// Confined to the serial camera queue; each hand has an independent latch.
final class GestureEngine {
    struct Configuration {
        var closeThreshold: CGFloat = 0.40
        var openThreshold: CGFloat = 0.64
        var closeDuration: TimeInterval = 0.018
        var openDuration: TimeInterval = 0.018
        var trackingTimeout: TimeInterval = 0.18
        var minimumConfidence: Float = 0.25
        var maximumClosingDuration: TimeInterval = 0.45
    }

    private struct State {
        var phase: HandPhase = .open
        var armed = false
        var closeSince: TimeInterval?
        var openSince: TimeInterval?
        var closingStarted: TimeInterval?
        var lastSeen: TimeInterval?
        var previousPinch: CGFloat?
        var cursor: CGPoint?
        var pointer = FingertipPointer()
        var edgeEvidence = EdgeFingertipEvidence()

        mutating func interrupt(keepingArm: Bool = false) {
            closeSince = nil
            openSince = nil
            previousPinch = nil
            if !keepingArm {
                closingStarted = nil
                armed = false
            }
        }
    }

    private var states: [HandSide: State] = [:]
    private var previousTimestamp: TimeInterval?
    private(set) var configuration: Configuration
    init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    func setCloseThreshold(_ threshold: CGFloat) {
        configuration.closeThreshold = min(0.60, max(0.25, threshold))
        configuration.openThreshold = configuration.closeThreshold + 0.24
        reset()
    }

    func reset() { states.removeAll(); previousTimestamp = nil }

    func process(observations: [HandObservation], timestamp: TimeInterval) -> HandFrame {
        var frame = HandFrame(timestamp: timestamp)
        frame.releaseThreshold = configuration.openThreshold
        guard timestamp.isFinite, previousTimestamp.map({ timestamp > $0 }) ?? true else { return frame }
        previousTimestamp = timestamp
        var bySide: [HandSide: HandObservation] = [:]
        for observation in observations where observation.confidence >= configuration.minimumConfidence
            && observation.indexTip.isFinite && observation.thumbTip.isFinite && observation.pinchDistanceScore.isFinite {
            if observation.confidence > (bySide[observation.side]?.confidence ?? 0) { bySide[observation.side] = observation }
        }
        for side in HandSide.allCases {
            var state = states[side] ?? State()
            if let lastSeen = state.lastSeen, timestamp - lastSeen > configuration.trackingTimeout {
                if state.phase == .closed {
                    frame.events.append(HandEvent(side: side, kind: .cancelled, pointer: state.cursor ?? .zero, timestamp: timestamp))
                }
                state = State()
            }
            let candidate = bySide[side]
            let accepted = candidate.map { $0.pinchIsReliable && state.edgeEvidence.accepts($0, at: timestamp) } ?? false
            guard let observation = candidate, accepted else {
                // A single suspect relocation can be confirmed next frame. Keep
                // the existing open-hand intent so a real pinch need not reopen;
                // clipped, missing or low-confidence evidence still disarms.
                state.interrupt(keepingArm: candidate?.pinchIsReliable == true && state.edgeEvidence.awaitingConfirmation)
                if state.phase == .closed { frame.suspended.insert(side) }
                states[side] = state
                frame.phases[side] = state.phase
                // Keep brief display-only holds separate from valid input.
                continue
            }

            let dt = timestamp - (state.lastSeen ?? timestamp - 1 / 30)
            let cursor = state.pointer.update(index: observation.indexTip, thumb: observation.thumbTip, dt: dt)
            state.cursor = cursor
            state.lastSeen = timestamp
            let pinch = observation.pinchDistanceScore
            if state.armed, state.phase == .open, pinch < configuration.openThreshold, state.closingStarted == nil {
                state.closingStarted = timestamp
            }
            if state.phase == .open, let started = state.closingStarted,
               timestamp - started > configuration.maximumClosingDuration { state.armed = false }
            let approachedClose = state.previousPinch.map {
                $0 < configuration.openThreshold && $0 > pinch && pinch < configuration.closeThreshold * 0.7
            } ?? false

            if pinch <= configuration.closeThreshold {
                state.openSince = nil
                if state.closeSince == nil { state.closeSince = timestamp }
                if state.armed, state.phase == .open,
                   approachedClose || timestamp - (state.closeSince ?? timestamp) >= configuration.closeDuration {
                    state.phase = .closed
                    state.armed = false
                    frame.events.append(HandEvent(side: side, kind: .began, pointer: cursor, timestamp: timestamp))
                }
            } else if pinch >= configuration.openThreshold {
                state.closeSince = nil
                state.closingStarted = nil
                if state.openSince == nil { state.openSince = timestamp }
                if timestamp - (state.openSince ?? timestamp) >= configuration.openDuration {
                    if state.phase == .closed {
                        frame.events.append(HandEvent(side: side, kind: .ended, pointer: cursor, timestamp: timestamp))
                    }
                    state.phase = .open
                    state.armed = true
                }
            } else {
                state.closeSince = nil
                state.openSince = nil
            }
            state.previousPinch = pinch
            states[side] = state
            frame.tracked.insert(side)
            frame.aiming.insert(side)
            frame.cursors[side] = cursor
            frame.tapCursors[side] = cursor
            frame.phases[side] = state.phase
            frame.pinchScores[side] = pinch
            frame.visuals[side] = HandFeedbackVisual(side: side, indexTip: state.pointer.index!,
                thumbTip: state.pointer.thumb!, wrist: observation.wrist, confidence: observation.confidence)
        }
        return frame
    }
}
