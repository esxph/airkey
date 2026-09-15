import XCTest
@testable import airKey

final class HandIdentityTrackerTests: XCTestCase {
    private func candidate(_ side: HandSide?, x: CGFloat) -> HandCandidate {
        let point = CGPoint(x: x, y: 0.5)
        let observation = HandObservation(side: side ?? .left, pointer: point, indexTip: point,
            thumbTip: point, wrist: point, clawOpenScore: 0, pinchDistanceScore: 0.2,
            confidence: 0.9, aimReference: point)
        return HandCandidate(observation: observation, reportedSide: side)
    }

    func testUnknownAndFlippedLabelPreserveARecognizedHand() {
        var tracker = HandIdentityTracker()
        XCTAssertEqual(tracker.assign([candidate(.right, x: 0.3)], at: 0).first?.side, .right)
        XCTAssertEqual(tracker.assign([candidate(nil, x: 0.32)], at: 0.04).first?.side, .right)
        XCTAssertEqual(tracker.assign([candidate(.left, x: 0.34)], at: 0.08).first?.side, .right)
    }

    func testTwoHandsKeepIdentityDespiteOrderAndLabelChanges() {
        var tracker = HandIdentityTracker()
        _ = tracker.assign([candidate(.left, x: 0.2), candidate(.right, x: 0.8)], at: 0)
        let hands = tracker.assign([candidate(.left, x: 0.78), candidate(.right, x: 0.22)], at: 0.04)
        XCTAssertEqual(hands.map(\.side), [.right, .left])
        XCTAssertEqual(Set(hands.map(\.side)).count, 2)
    }

    func testUnknownHandCannotInheritAnExpiredOrDistantIdentity() {
        var tracker = HandIdentityTracker()
        XCTAssertTrue(tracker.assign([candidate(nil, x: 0.3)], at: 0).isEmpty)
        _ = tracker.assign([candidate(.right, x: 0.3)], at: 0.04)
        XCTAssertTrue(tracker.assign([candidate(nil, x: 0.8)], at: 0.08).isEmpty)
        XCTAssertTrue(tracker.assign([candidate(nil, x: 0.3)], at: 0.6).isEmpty)
    }

    func testUnknownLabelDuringHoldDoesNotCancelOrCreateSecondPinch() {
        var tracker = HandIdentityTracker()
        let engine = GestureEngine()
        var events: [HandEvent] = []
        for tick in 0..<40 {
            var value = candidate(tick < 5 ? .right : nil, x: 0.3)
            // Establish open tracking before the held pinch.
            let old = value.observation
            value.observation = HandObservation(side: old.side, pointer: old.pointer, indexTip: old.indexTip,
                thumbTip: old.thumbTip, wrist: old.wrist, clawOpenScore: 0,
                pinchDistanceScore: tick < 3 ? 0.9 : 0.2, confidence: 0.9, aimReference: old.aimReference)
            let time = Double(tick) / 30
            events += engine.process(observations: tracker.assign([value], at: time), timestamp: time).events
        }
        XCTAssertEqual(events.map(\.kind), [.began])
        XCTAssertEqual(events.map(\.side), [.right])
    }
}

@MainActor
final class PointerContinuityTests: XCTestCase {
    private func tracked(at time: Double, point: CGPoint = CGPoint(x: 0.4, y: 0.5)) -> HandFrame {
        var frame = HandFrame(timestamp: time)
        frame.cursors[.right] = point
        frame.tapCursors[.right] = point
        frame.aiming = [.right]
        frame.tracked = [.right]
        frame.phases[.right] = .open
        frame.pinchScores[.right] = 0.9
        return frame
    }

    func testBriefLossKeepsPointerWithoutMarkingHandTrackedAndExpires() {
        var continuity = PointerContinuity()
        let start = continuity.apply(to: tracked(at: 1))
        let gap = continuity.apply(to: HandFrame(timestamp: 1.04))
        XCTAssertEqual(gap.cursors, start.cursors)
        XCTAssertEqual(gap.visibleHands, [.right])
        XCTAssertTrue(gap.tracked.isEmpty)
        XCTAssertTrue(gap.aiming.isEmpty)
        XCTAssertTrue(gap.events.isEmpty)
        XCTAssertTrue(continuity.apply(to: HandFrame(timestamp: 1.31)).visibleHands.isEmpty)
    }

    func testFreshMotionIsDisplayedImmediatelyWithNoInterpolation() {
        var continuity = PointerContinuity()
        _ = continuity.apply(to: tracked(at: 1))
        _ = continuity.apply(to: HandFrame(timestamp: 1.04))
        let moved = tracked(at: 1.08, point: CGPoint(x: 0.6, y: 0.5))
        XCTAssertEqual(continuity.apply(to: moved).cursors, moved.cursors)
    }

    func testKeyboardHoverSurvivesMissingFrameWithoutTyping() {
        var continuity = PointerContinuity()
        let keyboard = TypingController()
        let size = keyboard.sceneSize
        let rect = keyboard.layout.keyFrames(in: size)["char_H"]!
        var initial = tracked(at: 1, point: CGPoint(x: 1 - rect.midX / size.width, y: 1 - rect.midY / size.height))
        initial.imageSize = size
        keyboard.process(continuity.apply(to: initial))
        let hover = keyboard.hovered
        XCTAssertFalse(hover.isEmpty)
        keyboard.process(continuity.apply(to: HandFrame(timestamp: 1.04, imageSize: size)))
        XCTAssertEqual(keyboard.hovered, hover)
        XCTAssertEqual(keyboard.text, "")
        keyboard.process(continuity.apply(to: HandFrame(timestamp: 1.31, imageSize: size)))
        XCTAssertTrue(keyboard.hovered.isEmpty)
        XCTAssertTrue(keyboard.pressed.isEmpty)
    }

    func testHeldPointerCannotRepeatDelete() {
        let keyboard = TypingController()
        var continuity = PointerContinuity()
        let size = keyboard.sceneSize
        let rect = keyboard.layout.keyFrames(in: size)["delete"]!
        let point = CGPoint(x: 1 - rect.midX / size.width, y: 1 - rect.midY / size.height)
        var frame = tracked(at: 1, point: point)
        frame.imageSize = size
        frame.phases[.right] = .closed
        frame.events = [HandEvent(side: .right, kind: .began, pointer: point, timestamp: 1)]
        keyboard.editText("abcdef")
        keyboard.process(continuity.apply(to: frame))
        for time in [1.04, 1.1, 1.2, 1.4, 1.6] {
            keyboard.process(continuity.apply(to: HandFrame(timestamp: time, imageSize: size)))
        }
        XCTAssertEqual(keyboard.text, "abcde")
        XCTAssertTrue(keyboard.pressed.isEmpty)
    }
}
