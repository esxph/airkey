import XCTest
@testable import airKey

final class FingertipPointerTests: XCTestCase {
    private func hand(_ pinch: CGFloat, center: CGPoint, gap: CGFloat = 0.05,
                      palm: CGPoint = CGPoint(x: 0.2, y: 0.2), reliable: Bool = true) -> HandObservation {
        HandObservation(side: .left, pointer: center,
            indexTip: CGPoint(x: center.x + gap, y: center.y + gap),
            thumbTip: CGPoint(x: center.x - gap, y: center.y - gap),
            wrist: palm, clawOpenScore: 0, pinchDistanceScore: pinch, confidence: 0.95,
            aimReference: palm, pinchIsReliable: reliable)
    }

    private func assertCentered(_ frame: HandFrame, file: StaticString = #filePath, line: UInt = #line) throws {
        let visual = try XCTUnwrap(frame.visuals[.left], file: file, line: line)
        let midpoint = CGPoint(x: (visual.indexTip.x + visual.thumbTip.x) / 2,
                               y: (visual.indexTip.y + visual.thumbTip.y) / 2)
        XCTAssertEqual(frame.cursors[.left], midpoint, file: file, line: line)
        XCTAssertEqual(frame.tapCursors[.left], midpoint, file: file, line: line)
        for event in frame.events where event.kind == .began {
            XCTAssertEqual(event.pointer, midpoint, file: file, line: line)
        }
    }

    func testWholeHandMotionAndFingerClosureShareTheGuideMidpoint() throws {
        let engine = GestureEngine()
        for tick in 0..<24 {
            let x = 0.3 + Double(tick) * 0.012
            let closing = tick >= 5
            let frame = engine.process(observations: [hand(closing ? 0.2 : 0.9,
                center: CGPoint(x: x, y: 0.6), gap: closing ? 0.003 : 0.05,
                palm: CGPoint(x: x - 0.1, y: 0.3))], timestamp: Double(tick) / 30)
            try assertCentered(frame)
            XCTAssertGreaterThan(frame.cursors[.left]!.x, x - 0.01)
        }
    }

    func testSymmetricPinchWithStationaryPalmKeepsCircleAtContactCenter() throws {
        let engine = GestureEngine()
        let center = CGPoint(x: 0.4, y: 0.6)
        var events: [HandEvent] = []
        for (tick, gap) in [0.08, 0.08, 0.03, 0.003, 0.003, 0.003].enumerated() {
            let frame = engine.process(observations: [hand(tick < 2 ? 0.9 : tick == 2 ? 0.55 : 0.2,
                center: center, gap: gap)], timestamp: Double(tick) * 0.04)
            try assertCentered(frame)
            XCTAssertEqual(frame.cursors[.left]!.x, center.x, accuracy: 0.000001)
            XCTAssertEqual(frame.cursors[.left]!.y, center.y, accuracy: 0.000001)
            events += frame.events
        }
        XCTAssertEqual(events.map(\.kind), [.began])
    }

    func testDifferentInitialPalmLocationsCannotIntroduceAnOffset() {
        let center = CGPoint(x: 0.4, y: 0.6)
        for palm in [CGPoint.zero, CGPoint(x: 0.9, y: 0.9)] {
            let frame = GestureEngine().process(observations: [hand(0.9, center: center, palm: palm)], timestamp: 0)
            XCTAssertEqual(frame.cursors[.left]?.x ?? 0, center.x, accuracy: 0.000001)
            XCTAssertEqual(frame.cursors[.left]?.y ?? 0, center.y, accuracy: 0.000001)
        }
    }

    func testReacquisitionUsesCurrentFingertipCenterAndRequiresOpening() throws {
        let engine = GestureEngine()
        _ = engine.process(observations: [hand(0.9, center: CGPoint(x: 0.3, y: 0.6))], timestamp: 0)
        _ = engine.process(observations: [], timestamp: 0.3)
        let returned = engine.process(observations: [hand(0.2, center: CGPoint(x: 0.7, y: 0.6))], timestamp: 0.34)
        try assertCentered(returned)
        XCTAssertEqual(returned.cursors[.left]?.x ?? 0, 0.7, accuracy: 0.000001)
        XCTAssertTrue(returned.events.isEmpty)
    }

    func testUncertainFingersPauseInsteadOfSwitchingToAnOffsetPalmCursor() {
        let engine = GestureEngine()
        let center = CGPoint(x: 0.4, y: 0.6)
        for time in [0.0, 0.04] { _ = engine.process(observations: [hand(0.9, center: center)], timestamp: time) }
        for time in [0.08, 0.12] { _ = engine.process(observations: [hand(0.2, center: center)], timestamp: time) }
        let brief = engine.process(observations: [hand(0.2, center: center, reliable: false)], timestamp: 0.16)
        XCTAssertEqual(brief.suspended, [.left])
        XCTAssertTrue(brief.aiming.isEmpty)
        XCTAssertTrue(brief.tracked.isEmpty)
        let lost = engine.process(observations: [hand(0.2, center: center, reliable: false)], timestamp: 0.32)
        XCTAssertEqual(lost.events.map(\.kind), [.cancelled])
        XCTAssertTrue(engine.process(observations: [hand(0.2, center: center)], timestamp: 0.36).events.isEmpty)
    }
}
