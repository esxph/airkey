import AppKit
import SwiftUI
import XCTest
@testable import airKey

@MainActor
final class HandGuideVisualTests: XCTestCase {
    private func hand(shift: CGFloat = 0) -> HandObservation {
        let index = CGPoint(x: 0.4 + shift, y: 0.6), thumb = CGPoint(x: 0.5 + shift, y: 0.4)
        return HandObservation(side: .right, pointer: CGPoint(x: 0.45 + shift, y: 0.5),
            indexTip: index, thumbTip: thumb, wrist: nil, clawOpenScore: 0,
            pinchDistanceScore: 0.9, confidence: 0.95)
    }

    func testGuideCenterRemainsBetweenFilteredFingertipsDuringMovement() throws {
        let engine = GestureEngine()
        for tick in 0..<8 {
            let frame = engine.process(observations: [hand(shift: CGFloat(tick) * 0.003)], timestamp: Double(tick) / 30)
            let visual = try XCTUnwrap(frame.visuals[.right])
            let cursor = try XCTUnwrap(frame.cursors[.right])
            XCTAssertEqual(cursor.x, (visual.indexTip.x + visual.thumbTip.x) / 2, accuracy: 0.000001)
            XCTAssertEqual(cursor.y, (visual.indexTip.y + visual.thumbTip.y) / 2, accuracy: 0.000001)
        }
    }

    func testShortTrackingGapRetainsWholeCursorGuide() throws {
        let engine = GestureEngine()
        var continuity = PointerContinuity()
        let fresh = continuity.apply(to: engine.process(observations: [hand()], timestamp: 1))
        let held = continuity.apply(to: HandFrame(timestamp: 1.04))
        XCTAssertEqual(held.visuals[.right]?.indexTip, fresh.visuals[.right]?.indexTip)
        XCTAssertEqual(held.visuals[.right]?.thumbTip, fresh.visuals[.right]?.thumbTip)
        XCTAssertTrue(held.tracked.isEmpty)
        XCTAssertTrue(held.events.isEmpty)
    }
}
