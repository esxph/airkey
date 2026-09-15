import XCTest
@testable import airKey

final class EdgeFingertipTests: XCTestCase {
    private func hand(index: CGPoint = CGPoint(x: 0.05, y: 0.6),
                      thumb: CGPoint = CGPoint(x: 0.12, y: 0.45), pinch: CGFloat = 0.9,
                      shift: CGFloat = 0) -> HandObservation {
        HandObservation(side: .right, pointer: .zero,
            indexTip: CGPoint(x: index.x + shift, y: index.y),
            thumbTip: CGPoint(x: thumb.x + shift, y: thumb.y),
            wrist: CGPoint(x: 0.16 + shift, y: 0.3), clawOpenScore: 0,
            pinchDistanceScore: pinch, confidence: 0.95)
    }

    func testIsolatedBorderJumpNeitherMovesCursorNorTypes() throws {
        let engine = GestureEngine()
        var continuity = PointerContinuity()
        _ = engine.process(observations: [hand()], timestamp: 0)
        let normal = continuity.apply(to: engine.process(observations: [hand()], timestamp: 0.04))
        let bad = hand(thumb: CGPoint(x: 0.051, y: 0.59), pinch: 0.1)
        let held = continuity.apply(to: engine.process(observations: [bad], timestamp: 0.08))
        XCTAssertTrue(held.events.isEmpty)
        XCTAssertTrue(held.tracked.isEmpty)
        XCTAssertEqual(held.cursors, normal.cursors)
        XCTAssertEqual(held.heldPointers, [.right])
        let recovered = engine.process(observations: [hand()], timestamp: 0.12)
        XCTAssertEqual(recovered.cursors[.right], normal.cursors[.right])
        XCTAssertTrue(recovered.events.isEmpty)
    }

    func testCoherentFastHandTravelAndOrdinaryPinchAreAcceptedImmediately() {
        var guarder = EdgeFingertipEvidence()
        XCTAssertTrue(guarder.accepts(hand(shift: 0.14), at: 0))
        XCTAssertTrue(guarder.accepts(hand(), at: 0.033))
        XCTAssertTrue(guarder.accepts(hand(thumb: CGPoint(x: 0.10, y: 0.48)), at: 0.066))
    }

    func testConfirmedLargeFingerMovementResumesOnNextFrame() {
        var guarder = EdgeFingertipEvidence()
        _ = guarder.accepts(hand(), at: 0)
        let moved = hand(thumb: CGPoint(x: 0.065, y: 0.58), pinch: 0.2)
        XCTAssertFalse(guarder.accepts(moved, at: 0.033))
        XCTAssertTrue(guarder.accepts(moved, at: 0.066))
        XCTAssertTrue(guarder.accepts(moved, at: 0.099))
    }

    func testConfirmedEdgePinchCanTypeWithoutHavingToReopen() {
        let engine = GestureEngine()
        for time in [0.0, 0.04] { _ = engine.process(observations: [hand()], timestamp: time) }
        let closed = hand(thumb: CGPoint(x: 0.065, y: 0.58), pinch: 0.2)
        var events: [HandEvent] = []
        for time in [0.08, 0.12, 0.16, 0.20] {
            events += engine.process(observations: [closed], timestamp: time).events
        }
        XCTAssertEqual(events.map(\.kind), [.began])
        XCTAssertEqual(events.first?.timestamp, 0.16)
    }

    func testBorderJumpProtectionAppliesToAllFourEdges() {
        let transforms: [(CGPoint) -> CGPoint] = [
            { $0 }, { CGPoint(x: 1 - $0.x, y: $0.y) },
            { CGPoint(x: $0.y, y: $0.x) }, { CGPoint(x: $0.y, y: 1 - $0.x) }
        ]
        for transform in transforms {
            func transformed(_ value: HandObservation) -> HandObservation {
                HandObservation(side: value.side, pointer: .zero,
                    indexTip: transform(value.indexTip), thumbTip: transform(value.thumbTip),
                    wrist: value.wrist.map(transform), clawOpenScore: 0,
                    pinchDistanceScore: value.pinchDistanceScore, confidence: value.confidence)
            }
            var guarder = EdgeFingertipEvidence()
            XCTAssertTrue(guarder.accepts(transformed(hand()), at: 0))
            XCTAssertFalse(guarder.accepts(transformed(hand(thumb: CGPoint(x: 0.051, y: 0.59))), at: 0.033))
        }
    }

    func testClippedJointDuringHoldPausesThenCancelsWithoutRelease() {
        let engine = GestureEngine()
        let closed = hand(pinch: 0.2)
        for time in [0.0, 0.04] { _ = engine.process(observations: [hand()], timestamp: time) }
        _ = engine.process(observations: [closed], timestamp: 0.08)
        XCTAssertEqual(engine.process(observations: [closed], timestamp: 0.12).events.map(\.kind), [.began])
        let clipped = hand(index: CGPoint(x: 0, y: 0.6), pinch: 0.9)
        let paused = engine.process(observations: [clipped], timestamp: 0.16)
        XCTAssertEqual(paused.suspended, [.right])
        XCTAssertTrue(paused.events.isEmpty)
        let expired = engine.process(observations: [clipped], timestamp: 0.32)
        XCTAssertEqual(expired.events.map(\.kind), [.cancelled])
        XCTAssertTrue(engine.process(observations: [closed], timestamp: 0.36).events.isEmpty)
    }

    func testCenterFingerMotionIsNotSubjectToBorderConfirmation() {
        var guarder = EdgeFingertipEvidence()
        _ = guarder.accepts(hand(shift: 0.3), at: 0)
        XCTAssertTrue(guarder.accepts(hand(thumb: CGPoint(x: 0.051, y: 0.59), shift: 0.3), at: 0.033))
    }
}
