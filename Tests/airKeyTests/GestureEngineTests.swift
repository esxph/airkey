import XCTest
@testable import airKey

final class GestureEngineTests: XCTestCase {
    private func hand(_ pinch: CGFloat, side: HandSide = .left, confidence: Float = 0.95,
                      point: CGPoint = CGPoint(x: 0.3, y: 0.6)) -> HandObservation {
        HandObservation(side: side, pointer: point, indexTip: point, thumbTip: point, wrist: nil,
                        clawOpenScore: 0, pinchDistanceScore: pinch, confidence: confidence)
    }
    private func arm(_ engine: GestureEngine) {
        _ = engine.process(observations: [hand(0.9)], timestamp: 0)
        _ = engine.process(observations: [hand(0.9)], timestamp: 0.04)
    }

    func testHeldPinchEmitsOnceAndRequiresReleaseBeforeRepeat() {
        let engine = GestureEngine(); arm(engine)
        var events: [HandEvent] = []
        for i in 2...10 { events += engine.process(observations: [hand(0.2)], timestamp: Double(i) * 0.04).events }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .began)
        _ = engine.process(observations: [hand(0.9)], timestamp: 0.44)
        XCTAssertEqual(engine.process(observations: [hand(0.9)], timestamp: 0.48).events.first?.kind, .ended)
        _ = engine.process(observations: [hand(0.2)], timestamp: 0.52)
        XCTAssertEqual(engine.process(observations: [hand(0.2)], timestamp: 0.56).events.first?.kind, .began)
    }

    func testSingleNoisyCloseFrameDoesNotType() {
        let engine = GestureEngine(); arm(engine)
        XCTAssertTrue(engine.process(observations: [hand(0.1)], timestamp: 0.08).events.isEmpty)
        XCTAssertTrue(engine.process(observations: [hand(0.9)], timestamp: 0.12).events.isEmpty)
    }

    func testHeldPinchSurvivesBriefOcclusionButTimesOutWithoutRelease() {
        let engine = GestureEngine(); arm(engine)
        _ = engine.process(observations: [hand(0.2)], timestamp: 0.08)
        _ = engine.process(observations: [hand(0.2)], timestamp: 0.12)
        let gap = engine.process(observations: [], timestamp: 0.16)
        XCTAssertEqual(gap.suspended, [.left])
        XCTAssertTrue(gap.events.isEmpty)
        let resumed = engine.process(observations: [hand(0.2)], timestamp: 0.20)
        XCTAssertEqual(resumed.phases[.left], .closed)
        XCTAssertTrue(resumed.events.isEmpty)
        XCTAssertTrue(resumed.suspended.isEmpty)
        let lost = engine.process(observations: [], timestamp: 0.40)
        XCTAssertTrue(lost.suspended.isEmpty)
        XCTAssertEqual(lost.events.map(\.kind), [.cancelled])
    }

    func testStableSlowPinchCanCloseWithoutMotionDerivative() {
        let engine = GestureEngine(); arm(engine)
        _ = engine.process(observations: [hand(0.37)], timestamp: 0.08)
        XCTAssertEqual(engine.process(observations: [hand(0.37)], timestamp: 0.12).events.first?.kind, .began)
    }

    func testHandAppearingAlreadyClosedMustOpenBeforeTyping() {
        let engine = GestureEngine()
        for i in 0...5 {
            XCTAssertTrue(engine.process(observations: [hand(0.2)], timestamp: Double(i) * 0.04).events.isEmpty)
        }
        _ = engine.process(observations: [hand(0.9)], timestamp: 0.24)
        _ = engine.process(observations: [hand(0.9)], timestamp: 0.28)
        _ = engine.process(observations: [hand(0.2)], timestamp: 0.32)
        XCTAssertEqual(engine.process(observations: [hand(0.2)], timestamp: 0.36).events.first?.kind, .began)
    }

    func testTrackingTimeoutCancelsWithoutCommittingRelease() {
        let engine = GestureEngine(); arm(engine)
        _ = engine.process(observations: [hand(0.2)], timestamp: 0.08)
        _ = engine.process(observations: [hand(0.2)], timestamp: 0.12)
        let missing = engine.process(observations: [], timestamp: 0.4)
        XCTAssertEqual(missing.events.map(\.kind), [.cancelled])
        XCTAssertTrue(missing.tracked.isEmpty)
        XCTAssertTrue(engine.process(observations: [hand(0.2)], timestamp: 0.44).events.isEmpty)
        XCTAssertTrue(engine.process(observations: [hand(0.2)], timestamp: 0.48).events.isEmpty)
    }

    func testGapDetectedEvenWithoutIntermediateMissingFrame() {
        let engine = GestureEngine(); arm(engine)
        _ = engine.process(observations: [hand(0.2)], timestamp: 0.08)
        _ = engine.process(observations: [hand(0.2)], timestamp: 0.12)
        XCTAssertEqual(engine.process(observations: [hand(0.2)], timestamp: 1).events.map(\.kind), [.cancelled])
    }

    func testLowConfidenceCannotCompletePinch() {
        let engine = GestureEngine(); arm(engine)
        _ = engine.process(observations: [hand(0.2)], timestamp: 0.08)
        let frame = engine.process(observations: [hand(0.2, confidence: 0.2)], timestamp: 0.12)
        XCTAssertTrue(frame.events.isEmpty)
        XCTAssertTrue(frame.tracked.isEmpty)
    }

    func testTwoHandsProduceIndependentEdges() {
        let engine = GestureEngine()
        for t in [0.0, 0.04] { _ = engine.process(observations: [hand(0.9), hand(0.9, side: .right)], timestamp: t) }
        _ = engine.process(observations: [hand(0.2), hand(0.2, side: .right)], timestamp: 0.08)
        let frame = engine.process(observations: [hand(0.2), hand(0.2, side: .right)], timestamp: 0.12)
        XCTAssertEqual(Set(frame.events.map(\.side)), [.left, .right])
    }

    func testCloseDetectionAcrossFrameRates() {
        for fps in [15.0, 30.0, 60.0] {
            let engine = GestureEngine()
            var events: [HandEvent] = []
            for i in 0..<Int(fps) {
                let timestamp = Double(i) / fps
                let pinch: CGFloat = timestamp < 0.2 || timestamp > 0.6 ? 0.9 : 0.2
                events += engine.process(observations: [hand(pinch)], timestamp: timestamp).events
            }
            XCTAssertEqual(events.map(\.kind), [.began, .ended], "fps=\(fps)")
        }
    }

    func testNaturalClosingApproachCommitsAtTheCurrentMidpointWithoutExtraFrame() {
        let engine = GestureEngine(); arm(engine)
        _ = engine.process(observations: [hand(0.55, point: CGPoint(x: 0.32, y: 0.6))], timestamp: 0.08)
        let frame = engine.process(observations: [hand(0.2, point: CGPoint(x: 0.36, y: 0.6))], timestamp: 0.12)
        XCTAssertEqual(frame.events.first?.kind, .began)
        XCTAssertEqual(frame.events.first?.pointer, frame.cursors[.left])
        XCTAssertGreaterThan(frame.events.first?.pointer.x ?? 0, 0.34)
    }

    func testLightPinchSettingAcceptsLessClosureAndRequiresRearmingAfterChange() {
        let engine = GestureEngine(); arm(engine)
        engine.setCloseThreshold(0.5)
        XCTAssertTrue(engine.process(observations: [hand(0.45)], timestamp: 0.08).events.isEmpty)
        _ = engine.process(observations: [hand(0.9)], timestamp: 0.12)
        _ = engine.process(observations: [hand(0.9)], timestamp: 0.16)
        _ = engine.process(observations: [hand(0.45)], timestamp: 0.20)
        let frame = engine.process(observations: [hand(0.45)], timestamp: 0.24)
        XCTAssertEqual(frame.events.first?.kind, .began)
        XCTAssertEqual(frame.releaseThreshold, 0.74, accuracy: 0.001)
    }

    func testInitialCursorDoesNotInterpolateFromAnUnrelatedDefaultPosition() {
        let engine = GestureEngine()
        let point = CGPoint(x: 0.95, y: 0.9)
        XCTAssertEqual(engine.process(observations: [hand(0.9, point: point)], timestamp: 0).cursors[.left], point)
    }

    func testPinchUsesCurrentFingertipAimAndRejectsInvalidSamples() {
        let engine = GestureEngine(); arm(engine)
        _ = engine.process(observations: [hand(0.2, point: CGPoint(x: 0.4, y: 0.6))], timestamp: 0.08)
        let event = engine.process(observations: [hand(0.2, point: CGPoint(x: 0.45, y: 0.6))], timestamp: 0.12).events.first
        XCTAssertGreaterThan(event?.pointer.x ?? 0, 0.43)
        XCTAssertTrue(engine.process(observations: [hand(0.9)], timestamp: .nan).events.isEmpty)
        XCTAssertTrue(engine.process(observations: [hand(0.9)], timestamp: 0.1).events.isEmpty)
    }
}
