import XCTest
@testable import airKey

@MainActor
final class TypingControllerTests: XCTestCase {
    private let size = CGSize(width: 1100, height: 760)
    private func center(_ key: String, controller: TypingController) -> CGPoint {
        let frame = controller.layout.keyFrames(in: size)[key]!
        return CGPoint(x: frame.midX, y: frame.midY)
    }
    private func frame(at point: CGPoint, time: Double, side: HandSide = .left,
                       event: HandEvent.Kind? = nil, phase: HandPhase = .closed) -> HandFrame {
        let normalized = CGPoint(x: 1 - point.x / size.width, y: 1 - point.y / size.height)
        return HandFrame(timestamp: time,
                         events: event.map { [HandEvent(side: side, kind: $0, pointer: normalized, timestamp: time)] } ?? [],
                         cursors: [side: normalized], phases: [side: phase], tracked: [side],
                         pinchScores: [side: phase == .closed ? 0.2 : 0.9], imageSize: size)
    }
    private func swipe(_ word: String, on controller: TypingController, start: Double = 1) {
        let centers = controller.layout.letterCenters(in: size)
        let path = SwipeDecoder.resample(WordEntry.keyboardForm(word).compactMap { centers[$0] }, count: 45)
        controller.process(frame(at: path[0], time: start, event: .began))
        for (index, point) in path.dropFirst().enumerated() {
            controller.process(frame(at: point, time: start + Double(index + 1) * 0.025))
        }
        controller.process(frame(at: path.last!, time: start + 1.2, event: .ended, phase: .open))
    }

    func testRapidIntentionalRepeatedLettersAreNotGloballyDeduplicated() {
        let controller = TypingController()
        let point = center("char_L", controller: controller)
        controller.process(frame(at: point, time: 1, event: .began))
        controller.process(frame(at: point, time: 1.03, event: .ended, phase: .open))
        controller.process(frame(at: point, time: 1.06, event: .began))
        XCTAssertEqual(controller.text, "ll")
    }

    func testSimultaneousHandsCanTypeSameKey() {
        let controller = TypingController()
        let point = center("char_L", controller: controller)
        var value = frame(at: point, time: 1, event: .began)
        value.tracked.insert(.right)
        value.cursors[.right] = value.cursors[.left]
        value.phases[.right] = .closed
        value.events.append(HandEvent(side: .right, kind: .began, pointer: value.cursors[.right]!, timestamp: 1))
        controller.process(value)
        XCTAssertEqual(controller.text, "ll")
    }

    func testPinchingNearSpaceUsesGravityAndTypesOneSpace() {
        let controller = TypingController()
        let rect = controller.layout.keyFrames(in: size)["space"]!
        let point = CGPoint(x: rect.midX, y: rect.maxY + 25)
        controller.process(frame(at: point, time: 1, event: .began))
        controller.process(frame(at: point, time: 1.1, event: .ended, phase: .open))
        XCTAssertEqual(controller.text, " ")
    }

    func testHeldDeleteHasInitialDelayAndStopsImmediatelyWhenTrackingDisappears() {
        let controller = TypingController(); controller.editText("abcdefgh")
        let point = center("delete", controller: controller)
        controller.process(frame(at: point, time: 1, event: .began))
        XCTAssertEqual(controller.text, "abcdefg")
        controller.process(frame(at: point, time: 1.3))
        XCTAssertEqual(controller.text, "abcdefg")
        controller.process(frame(at: point, time: 1.46))
        XCTAssertEqual(controller.text, "abcdef")
        controller.process(HandFrame(timestamp: 1.5, imageSize: size))
        controller.process(frame(at: point, time: 2))
        XCTAssertEqual(controller.text, "abcdef")
        XCTAssertTrue(controller.pressed.isEmpty)
    }

    func testDeleteRepeatsInSwipeModeWithoutAnExtraReleaseDeletion() {
        let controller = TypingController(); controller.swipeMode = true; controller.editText("abc")
        let point = center("delete", controller: controller)
        controller.process(frame(at: point, time: 1, event: .began))
        controller.process(frame(at: point, time: 1.1, event: .ended, phase: .open))
        XCTAssertEqual(controller.text, "ab")
    }

    func testHeldDeletePausesAcrossBriefOcclusionAndResumesWithoutCatchUp() {
        let controller = TypingController(); controller.editText("abcdefgh")
        let point = center("delete", controller: controller)
        controller.process(frame(at: point, time: 1, event: .began))
        var gap = HandFrame(timestamp: 1.46, imageSize: size)
        gap.suspended = [.left]
        controller.process(gap)
        XCTAssertEqual(controller.text, "abcdefg")
        XCTAssertEqual(controller.pressed, ["delete"])
        controller.process(frame(at: point, time: 1.50))
        XCTAssertEqual(controller.text, "abcdefg")
        controller.process(frame(at: point, time: 1.60))
        XCTAssertEqual(controller.text, "abcdef")
        controller.process(frame(at: point, time: 1.64, event: .ended, phase: .open))
        controller.process(frame(at: point, time: 1.9, phase: .open))
        XCTAssertEqual(controller.text, "abcdef")
        XCTAssertTrue(controller.pressed.isEmpty)
    }

    func testDeleteHoldCanReturnAfterDriftingOffKey() {
        let controller = TypingController(); controller.editText("abcdefgh")
        let point = center("delete", controller: controller)
        controller.process(frame(at: point, time: 1, event: .began))
        controller.process(frame(at: center("char_A", controller: controller), time: 1.5))
        XCTAssertEqual(controller.text, "abcdefg")
        controller.process(frame(at: point, time: 1.55))
        XCTAssertEqual(controller.text, "abcdefg")
        controller.process(frame(at: point, time: 1.65))
        XCTAssertEqual(controller.text, "abcdef")
    }

    func testShortSwipeHoldResumesAfterOcclusionWithoutExtraLetter() async {
        let controller = TypingController(); controller.swipeMode = true
        let point = center("char_A", controller: controller)
        controller.process(frame(at: point, time: 1, event: .began))
        var gap = HandFrame(timestamp: 1.04, imageSize: size)
        gap.suspended = [.left]
        controller.process(gap)
        controller.process(frame(at: point, time: 1.08))
        controller.process(frame(at: point, time: 1.12, event: .ended, phase: .open))
        await controller.waitForPendingInput()
        XCTAssertEqual(controller.text, "a")
    }

    func testOccludedSwipeCancelsIfItReturnsOpenOrFarAway() async {
        for returnsOpen in [true, false] {
            let controller = TypingController(); controller.swipeMode = true
            let point = center("char_A", controller: controller)
            controller.process(frame(at: point, time: 1, event: .began))
            var gap = HandFrame(timestamp: 1.04, imageSize: size)
            gap.suspended = [.left]
            controller.process(gap)
            controller.process(frame(at: returnsOpen ? point : center("char_P", controller: controller),
                                     time: 1.08, phase: returnsOpen ? .open : .closed))
            controller.process(frame(at: point, time: 1.12, event: .ended, phase: .open))
            await controller.waitForPendingInput()
            XCTAssertEqual(controller.text, "")
            XCTAssertTrue(controller.pressed.isEmpty)
        }
    }

    func testSwipeCapturesMovementAndCommitsWordWithAlternatives() async {
        let controller = TypingController(); controller.language = .english; controller.swipeMode = true
        swipe("hello", on: controller)
        await controller.waitForPendingInput()
        XCTAssertEqual(controller.text, "hello ")
        XCTAssertTrue(controller.suggestions.contains("hello"))
        if controller.suggestions.count > 1 {
            let alternative = controller.suggestions[1]
            controller.activate("pred_1")
            await controller.waitForPendingInput()
            XCTAssertEqual(controller.text, alternative + " ")
        }
    }

    func testFastSuccessiveSwipesAndTapPreserveReleaseOrder() async {
        let controller = TypingController(); controller.language = .english; controller.swipeMode = true
        swipe("hello", on: controller)
        swipe("world", on: controller, start: 3)
        controller.activate("char_!")
        await controller.waitForPendingInput()
        XCTAssertEqual(controller.text, "hello world !")
    }

    func testTrackingLossCancelsSwipeRatherThanCommittingPartialWord() async {
        let controller = TypingController(); controller.swipeMode = true
        let point = center("char_H", controller: controller)
        controller.process(frame(at: point, time: 1, event: .began))
        controller.process(frame(at: center("char_O", controller: controller), time: 1.1))
        controller.process(HandFrame(timestamp: 1.15, imageSize: size))
        controller.process(frame(at: point, time: 1.3, event: .ended, phase: .open))
        await controller.waitForPendingInput()
        XCTAssertEqual(controller.text, "")
        XCTAssertTrue(controller.traces.isEmpty)
    }

    func testModeChangeDuringPinchCancelsAndDoesNotCommitOnRelease() async {
        let controller = TypingController(); controller.swipeMode = true
        let point = center("char_H", controller: controller)
        controller.process(frame(at: point, time: 1, event: .began))
        controller.swipeMode = false
        controller.process(frame(at: point, time: 1.1, event: .ended, phase: .open))
        await controller.waitForPendingInput()
        XCTAssertEqual(controller.text, "")
    }

    func testShortPinchInSwipeModeTypesOneLetter() async {
        let controller = TypingController(); controller.swipeMode = true
        let point = center("char_A", controller: controller)
        controller.process(frame(at: point, time: 1, event: .began))
        controller.process(frame(at: point, time: 1.1, event: .ended, phase: .open))
        await controller.waitForPendingInput()
        XCTAssertEqual(controller.text, "a")
    }

    func testCrossingControlKeyWhileSwipingDoesNotDeleteText() async {
        let controller = TypingController(); controller.swipeMode = true; controller.editText("saved ")
        controller.process(frame(at: center("char_H", controller: controller), time: 1, event: .began))
        controller.process(frame(at: center("delete", controller: controller), time: 1.3))
        controller.process(frame(at: center("delete", controller: controller), time: 2))
        XCTAssertEqual(controller.text, "saved ")
        controller.cancelInput()
    }

    func testEditingTextInvalidatesPendingSwipeResults() async {
        let controller = TypingController(); controller.language = .english; controller.swipeMode = true
        swipe("hello", on: controller)
        controller.editText("manual edit")
        await controller.waitForPendingInput()
        await controller.waitForSuggestions()
        XCTAssertEqual(controller.text, "manual edit")
    }

    func testSuggestionAfterSpaceAddsNewWordAndUndoRestoresPriorText() async {
        let controller = TypingController(); controller.language = .english; controller.editText("thank ")
        await controller.waitForSuggestions()
        XCTAssertEqual(controller.suggestions.first, "you")
        controller.activate("pred_0")
        await controller.waitForPendingInput()
        XCTAssertEqual(controller.text, "thank you ")
        controller.undo()
        XCTAssertEqual(controller.text, "thank ")
    }

    func testSymbolLayerActuallyTypesDigitsAndReturnsToLetters() {
        let controller = TypingController()
        controller.activate("symbols")
        XCTAssertTrue(controller.layout.symbols)
        XCTAssertTrue(controller.layout.keys.contains(where: { $0.id == "char_1" }))
        controller.activate("char_1")
        controller.activate("symbols")
        controller.activate("char_A")
        XCTAssertEqual(controller.text, "1a")
        XCTAssertFalse(controller.layout.symbols)
    }
}
