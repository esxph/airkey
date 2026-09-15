import XCTest
@testable import airKey

final class KeyboardMovementTests: XCTestCase {
    func testHandDragUsesFixedAnchorAndCorrectScreenDirection() {
        var drag = KeyboardMovement()
        drag.begin(at: CGPoint(x: 1000, y: 40), origin: CGPoint(x: 100, y: 80))
        let first = drag.move(to: CGPoint(x: 950, y: 70), currentOrigin: CGPoint(x: 100, y: 80))!
        XCTAssertEqual(first, CGPoint(x: 50, y: 50))
        XCTAssertEqual(drag.move(to: CGPoint(x: 950, y: 70), currentOrigin: first), first,
            "Repeating a camera sample must not keep moving the window")
        XCTAssertEqual(drag.move(to: CGPoint(x: 970, y: 30), currentOrigin: first), CGPoint(x: 70, y: 90))
    }
    func testReacquiredHandRebasesInsteadOfJumping() {
        var drag = KeyboardMovement()
        drag.begin(at: CGPoint(x: 100, y: 50), origin: .zero)
        drag.pause()
        let origin = CGPoint(x: 80, y: 40)
        XCTAssertNil(drag.move(to: CGPoint(x: 500, y: 300), currentOrigin: origin))
        XCTAssertEqual(drag.move(to: CGPoint(x: 510, y: 320), currentOrigin: origin), CGPoint(x: 90, y: 20))
        XCTAssertNil(drag.move(to: CGPoint(x: CGFloat.nan, y: 0), currentOrigin: origin))
    }
    func testPanelStaysReachableOnSmallAndOffsetDisplays() {
        let display = CGRect(x: -1920, y: 80, width: 1920, height: 1080)
        let proposed = CGRect(x: -2400, y: 2000, width: 1100, height: 444)
        XCTAssertTrue(display.contains(KeyboardMovement.constrain(proposed, to: display)))
        let small = CGRect(x: 0, y: 40, width: 900, height: 400)
        let fitted = KeyboardMovement.constrain(proposed, to: small)
        XCTAssertEqual(fitted.maxX, small.maxX)
        XCTAssertEqual(fitted.maxY, small.maxY, "The top-right drag handle must remain reachable")
    }
}

@MainActor
final class HandWindowDragTests: XCTestCase {
    private let size = CGSize(width: 1100, height: 444)
    private func frame(_ point: CGPoint, at time: Double, event: HandEvent.Kind? = nil,
                       side: HandSide = .left, phase: HandPhase = .closed) -> HandFrame {
        let normalized = CGPoint(x: 1 - point.x / size.width, y: 1 - point.y / size.height)
        return HandFrame(timestamp: time,
            events: event.map { [HandEvent(side: side, kind: $0, pointer: normalized, timestamp: time)] } ?? [],
            cursors: [side: normalized], phases: [side: phase], tracked: [side],
            pinchScores: [side: phase == .closed ? 0.2 : 0.9], imageSize: size)
    }
    private func keyboard() -> TypingController {
        let keyboard = TypingController(); keyboard.useCompactKeyboard(); keyboard.setSceneSize(size)
        return keyboard
    }
    func testHandleGravityLeavesKeysAndSuggestionsAvailable() {
        let keyboard = keyboard(), layout = keyboard.layout
        let handle = layout.dragHandleFrame(in: size)!
        XCTAssertGreaterThanOrEqual(handle.width, 100)
        XCTAssertGreaterThanOrEqual(size.width - handle.maxX, 40, "Aiming must not require reaching the camera's extreme edge")
        XCTAssertTrue(layout.hitsDragHandle(CGPoint(x: handle.minX - 15, y: handle.midY), in: size, suggestionCount: 4))
        XCTAssertTrue(layout.hitsDragHandle(CGPoint(x: handle.minX - 40, y: handle.maxY + 16), in: size, suggestionCount: 4))
        for rect in layout.suggestionFrames(in: size, count: 4) + Array(layout.keyFrames(in: size).values) {
            XCTAssertFalse(rect.intersects(handle))
            XCTAssertFalse(layout.hitsDragHandle(CGPoint(x: rect.maxX - 1, y: rect.minY + 1), in: size, suggestionCount: 4))
        }
    }
    func testHeldPinchMovesWithoutTypingAndIgnoresTheOtherHand() {
        let keyboard = keyboard(); keyboard.swipeMode = true
        var events: [KeyboardDragEvent] = [], prepared = 0
        keyboard.windowDrag = { events.append($0) }
        keyboard.prepareExternalInput = { prepared += 1 }
        let handle = keyboard.layout.dragHandleFrame(in: size)!
        let start = CGPoint(x: handle.minX - 15, y: handle.midY)
        keyboard.process(frame(start, at: 1, event: .began))
        XCTAssertEqual(keyboard.pressed, ["move_keyboard"])
        let moved = CGPoint(x: 750, y: 200)
        keyboard.process(frame(moved, at: 1.1))
        if case .moved(let point) = events.last! { XCTAssertEqual(point.x, moved.x, accuracy: 0.001) }
        else { XCTFail("Expected live drag motion") }
        var peer = frame(moved, at: 1.2)
        let letter = keyboard.layout.keyFrames(in: size)["char_A"]!
        let other = frame(CGPoint(x: letter.midX, y: letter.midY), at: 1.2, event: .began, side: .right)
        peer.events = other.events; peer.cursors[.right] = other.cursors[.right]
        peer.phases[.right] = .closed; peer.tracked.insert(.right)
        keyboard.process(peer)
        XCTAssertEqual(keyboard.text, ""); XCTAssertEqual(prepared, 0)
        keyboard.process(frame(moved, at: 1.3, event: .ended, phase: .open))
        XCTAssertTrue(keyboard.pressed.isEmpty)
        if case .ended = events.last! {} else { XCTFail("Release must stop the window drag") }
        let count = events.count
        keyboard.process(frame(start, at: 1.4))
        XCTAssertEqual(events.count, count, "A closed hand without a fresh beginning cannot restart movement")
    }
    func testTrackingSuspensionPausesAndLossCancelsWindowMovement() {
        let keyboard = keyboard()
        var events: [KeyboardDragEvent] = []
        keyboard.windowDrag = { events.append($0) }
        let handle = keyboard.layout.dragHandleFrame(in: size)!
        let point = CGPoint(x: handle.midX, y: handle.midY)
        keyboard.process(frame(point, at: 1, event: .began))
        var gap = HandFrame(timestamp: 1.1, imageSize: size); gap.suspended = [.left]
        keyboard.process(gap)
        if case .paused = events.last! {} else { XCTFail("Uncertain tracking must freeze the window") }
        keyboard.process(HandFrame(timestamp: 1.4, imageSize: size))
        if case .ended = events.last! {} else { XCTFail("Lost tracking must release the handle") }
        XCTAssertTrue(keyboard.pressed.isEmpty)
    }
}
