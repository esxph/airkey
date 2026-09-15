import AppKit
import XCTest
@testable import airKey

@MainActor
final class LiveHandMaskTests: XCTestCase {
    func testMaskKeepsHandPixelsAndExcludesRoomFaceRegionAndForearm() throws {
        let image = try XCTUnwrap(CameraGhostRenderer().render(HandMaskFixture.buffer(), poses: [HandMaskFixture.pose]))
        let pixels = NSBitmapImageRep(cgImage: image)
        func alpha(_ x: Int, _ y: Int) throws -> CGFloat { try XCTUnwrap(pixels.colorAt(x: x, y: y)).alphaComponent }
        XCTAssertGreaterThan(try alpha(240, 270), 0.9, "Palm detail stays visible")
        XCTAssertGreaterThan(try alpha(190, 175), 0.9, "Finger stays visible")
        XCTAssertLessThan(try alpha(211, 160), 0.03, "Room between fingers is transparent")
        XCTAssertEqual(try alpha(520, 150), 0, accuracy: 0.001, "A separate skin-colored object or face is excluded")
        XCTAssertEqual(try alpha(245, 410), 0, accuracy: 0.001, "Forearm is cut off at the wrist")
        XCTAssertEqual(try alpha(30, 30), 0, accuracy: 0.001)
        let color = try XCTUnwrap(pixels.colorAt(x: 240, y: 270)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.blueComponent, color.redComponent * 1.6)
        let crease = try XCTUnwrap(pixels.colorAt(x: 240, y: 272)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.blueComponent, crease.blueComponent + 0.02, "Keep camera texture rather than filling a flat shape")
    }

    func testAppearanceSamplesAdaptToDifferentHandColors() throws {
        for color: SIMD3<UInt8> in [SIMD3(75, 45, 31), SIMD3(145, 91, 61), SIMD3(237, 191, 156)] {
            let mask = try XCTUnwrap(LiveHandMask().makeMask(buffer: HandMaskFixture.buffer(skin: color), poses: [HandMaskFixture.pose]))
            let pixels = NSBitmapImageRep(cgImage: mask)
            let inside = try XCTUnwrap(pixels.colorAt(x: 120, y: 135)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(inside.redComponent, 0.9)
            let outside = try XCTUnwrap(pixels.colorAt(x: 260, y: 75)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(outside.redComponent, 0, accuracy: 0.001)
        }
    }

    func testMissingOrIncompleteHandEvidenceNeverFallsBackToCameraVideo() {
        let renderer = CameraGhostRenderer(), buffer = HandMaskFixture.buffer()
        XCTAssertNil(renderer.render(buffer, poses: []))
        XCTAssertNil(renderer.render(buffer, poses: [HandMaskPose(points: [.wrist: CGPoint(x: 0.5, y: 0.5)])]))
        XCTAssertNotNil(renderer.render(buffer, poses: [HandMaskFixture.pose]))
        XCTAssertNil(renderer.render(buffer, poses: []), "Do not reuse a stale mask on a later camera frame")
    }

    func testBothHandsAndFrameEdgesAreHandledWithoutReusingOldGeometry() throws {
        let shift: CGFloat = 290
        let pose = HandMaskPose(points: HandMaskFixture.pose.points.mapValues { CGPoint(x: $0.x + shift / 640, y: $0.y) })
        let buffer = HandMaskFixture.buffer(shift: Int(shift), includeOriginal: true)
        let mask = try XCTUnwrap(LiveHandMask().makeMask(buffer: buffer, poses: [HandMaskFixture.pose, pose]))
        let pixels = NSBitmapImageRep(cgImage: mask)
        XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x: 120, y: 135)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x: 265, y: 135)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x: 316, y: 91)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        let offscreen = HandMaskPose(points: HandMaskFixture.pose.points.mapValues { CGPoint(x: $0.x + 2, y: $0.y) })
        XCTAssertNil(LiveHandMask().makeMask(buffer: buffer, poses: [offscreen]))
    }
}
