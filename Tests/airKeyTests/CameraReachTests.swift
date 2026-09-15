import XCTest
@testable import airKey

final class CameraReachTests: XCTestCase {
    func testViewportLeavesTrackingMarginWithWideTallAndSquareCameras() {
        for image in [CGSize(width: 640, height: 480), CGSize(width: 1920, height: 1080), CGSize(width: 480, height: 640)] {
            for size in [CGSize(width: 1100, height: 444), CGSize(width: 980, height: 740), CGSize(width: 600, height: 900)] {
                let projection = CameraProjection(imageSize: image, viewSize: size)
                for point in [CGPoint.zero, CGPoint(x: size.width, y: size.height), CGPoint(x: size.width / 2, y: size.height / 2)] {
                    let camera = projection.unproject(point)
                    XCTAssertGreaterThanOrEqual(camera.x, 0.12 - 0.000001)
                    XCTAssertLessThanOrEqual(camera.x, 0.88 + 0.000001)
                    XCTAssertGreaterThanOrEqual(camera.y, 0.12 - 0.000001)
                    XCTAssertLessThanOrEqual(camera.y, 0.88 + 0.000001)
                    XCTAssertEqual(projection.project(camera).x, point.x, accuracy: 0.000001)
                    XCTAssertEqual(projection.project(camera).y, point.y, accuracy: 0.000001)
                }
            }
        }
    }

    func testOpenFingertipsFitInsideCameraAtEveryKeySuggestionAndMoveHandle() {
        let size = CGSize(width: 1100, height: 444)
        let layout = KeyboardLayout(fullSizeKeys: true, compact: true)
        let projection = CameraProjection(imageSize: CGSize(width: 640, height: 480), viewSize: size)
        let targets = Array(layout.keyFrames(in: size).values) + layout.suggestionFrames(in: size, count: 4)
            + [layout.dragHandleFrame(in: size)!]
        for rect in targets {
            let center = projection.unproject(CGPoint(x: rect.midX, y: rect.midY))
            for offset in [CGPoint(x: -0.06, y: 0), CGPoint(x: 0.06, y: 0), CGPoint(x: 0, y: -0.06), CGPoint(x: 0, y: 0.06)] {
                let tip = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
                XCTAssertGreaterThan(tip.x, 0.08)
                XCTAssertLessThan(tip.x, 0.92)
                XCTAssertGreaterThan(tip.y, 0.08)
                XCTAssertLessThan(tip.y, 0.92)
            }
        }
    }

    func testProjectionKeepsMidpointAndVideoAlignedEvenBeyondKeyboardEdges() {
        let projection = CameraProjection(imageSize: CGSize(width: 640, height: 480), viewSize: CGSize(width: 1100, height: 444))
        for x: CGFloat in [0.02, 0.12, 0.5, 0.88, 0.98] {
            let index = CGPoint(x: x - 0.01, y: 0.61), thumb = CGPoint(x: x + 0.01, y: 0.49)
            let center = projection.project(CGPoint(x: x, y: 0.55))
            let a = projection.project(index), b = projection.project(thumb)
            XCTAssertEqual(center.x, (a.x + b.x) / 2, accuracy: 0.000001)
            XCTAssertEqual(center.y, (a.y + b.y) / 2, accuracy: 0.000001)
            // The mirrored camera image is drawn into this same rectangle.
            XCTAssertEqual(center.x, projection.imageRect.minX + (1 - x) * projection.imageRect.width, accuracy: 0.000001)
        }
        XCTAssertGreaterThan(projection.project(CGPoint(x: 0.02, y: 0.5)).x, 1100, "No edge clamp may stick a cursor onto Delete or Move")
        XCTAssertLessThan(projection.project(CGPoint(x: 0.98, y: 0.5)).x, 0)
    }

    func testSmallMovementsHaveConstantGainAcrossTheUsableCameraRegion() {
        let projection = CameraProjection(imageSize: CGSize(width: 640, height: 480), viewSize: CGSize(width: 1100, height: 444))
        let expected: CGFloat = 1100 / 0.76 * 0.002
        for x: CGFloat in [0.06, 0.12, 0.3, 0.5, 0.7, 0.88, 0.94] {
            let start = projection.project(CGPoint(x: x, y: 0.5))
            let end = projection.project(CGPoint(x: x + 0.002, y: 0.5))
            XCTAssertEqual(start.x - end.x, expected, accuracy: 0.000001)
        }
    }
}

@MainActor
final class EdgeKeyReachTests: XCTestCase {
    func testOuterKeysAndMoveCanPinchWithRealCameraGeometryWithoutBorderSuspension() {
        for key in ["char_Q", "char_P", "char_Ñ", "delete", "space", "done", "move_keyboard"] {
            let keyboard = TypingController(); keyboard.useCompactKeyboard()
            let size = CGSize(width: 1100, height: 444)
            keyboard.setSceneSize(size)
            let rect = key == "move_keyboard" ? keyboard.layout.dragHandleFrame(in: size)! : keyboard.layout.keyFrames(in: size)[key]!
            let center = CameraProjection(imageSize: CGSize(width: 640, height: 480), viewSize: size)
                .unproject(CGPoint(x: rect.midX, y: rect.midY))
            let engine = GestureEngine()
            var beginnings = 0
            for (tick, score) in [CGFloat(0.9), 0.9, 0.55, 0.2].enumerated() {
                let gap = score * 0.06
                let hand = HandObservation(side: .left, pointer: center,
                    indexTip: CGPoint(x: center.x - gap, y: center.y), thumbTip: CGPoint(x: center.x + gap, y: center.y),
                    wrist: CGPoint(x: center.x, y: center.y - 0.1), clawOpenScore: 0,
                    pinchDistanceScore: score, confidence: 0.95)
                let frame = engine.process(observations: [hand], timestamp: 1 + Double(tick) / 30)
                XCTAssertEqual(frame.tracked, [.left], "\(key) should not require clipped fingertips")
                XCTAssertTrue(frame.suspended.isEmpty)
                beginnings += frame.events.filter { $0.kind == .began }.count
                keyboard.process(frame)
            }
            XCTAssertEqual(beginnings, 1)
            XCTAssertEqual(keyboard.hovered[.left], key)
            XCTAssertTrue(keyboard.pressed.contains(key))
        }
    }
}
