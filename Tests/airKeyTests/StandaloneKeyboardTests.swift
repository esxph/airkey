import XCTest
import Combine
@testable import airKey

final class FramePacerTests: XCTestCase {
    func testCameraArrivalJitterDoesNotHalveTheFrameRate() {
        var pacer = FramePacer()
        var frames = 0
        for tick in 0..<90 {
            let time = Double(tick) / 30 + (tick.isMultiple(of: 2) ? 0.003 : -0.003)
            if pacer.shouldProcess(at: time) { frames += 1; pacer.observedHands(true, at: time) }
        }
        XCTAssertEqual(frames, 90)
    }
    func testActiveCaptureIsCappedAndIdleWorkDropsThenRecovers() {
        var pacer = FramePacer()
        var active = 0
        for tick in 0..<120 {
            let time = Double(tick) / 120
            if pacer.shouldProcess(at: time) { active += 1; pacer.observedHands(true, at: time) }
        }
        XCTAssertEqual(active, 30)
        for tick in 120..<480 { _ = pacer.shouldProcess(at: Double(tick) / 120) }
        var idle = 0
        for tick in 480..<600 {
            if pacer.shouldProcess(at: Double(tick) / 120) { idle += 1 }
        }
        XCTAssertEqual(idle, 10)
        pacer.observedHands(true, at: 5)
        XCTAssertTrue(pacer.shouldProcess(at: 5.01))
        XCTAssertFalse(pacer.shouldProcess(at: 5.02))
        XCTAssertTrue(pacer.shouldProcess(at: 5.05))
    }
}

final class TextDeltaTests: XCTestCase {
    func testFloatingKeyboardKeepsFullHeightKeys() {
        var layout = KeyboardLayout(); layout.fullSizeKeys = true
        let size = CGSize(width: 1100, height: 600)
        XCTAssertGreaterThanOrEqual(layout.keyFrames(in: size)["char_A"]!.height, 70)
        XCTAssertGreaterThanOrEqual(layout.suggestionFrames(in: size, count: 4)[0].minY, 155)
    }
    func testAppendReplacementAndUnicodeDeletion() {
        let append = TextDelta(from: "hola", to: "hola ")
        XCTAssertEqual(append.deleteCount, 0)
        XCTAssertEqual(append.inserted, " ")
        let fix = TextDelta(from: "hoña ", to: "hola ")
        XCTAssertEqual(fix.deleteCount, 3)
        XCTAssertEqual(fix.inserted, "la ")
        let emoji = TextDelta(from: "hi 👋", to: "hi ")
        XCTAssertEqual(emoji.deleteCount, 1)
        XCTAssertEqual(emoji.deletedUTF16Count, 2)
        XCTAssertEqual(emoji.inserted, "")
        XCTAssertEqual(TextDelta(from: "mañana", to: "mañana").deleteCount, 0)
    }
}

@MainActor
final class StandaloneKeyboardTests: XCTestCase {
    func testRejectedOutputDoesNotChangeCompositionOrUndo() {
        let keyboard = TypingController()
        keyboard.outputTextChange = { _, _ in false }
        keyboard.activate("char_H")
        XCTAssertEqual(keyboard.text, "")
        XCTAssertFalse(keyboard.canUndo)
        keyboard.outputTextChange = { _, _ in true }
        keyboard.activate("char_H")
        keyboard.outputTextChange = { _, _ in false }
        keyboard.undo()
        XCTAssertEqual(keyboard.text, "h")
        XCTAssertTrue(keyboard.canUndo)
    }

    func testPracticeAndRestorationNeverTypeIntoDestination() {
        let keyboard = TypingController()
        var changes = 0
        keyboard.outputTextChange = { _, _ in changes += 1; return true }
        keyboard.activate("char_H")
        keyboard.startBenchmark()
        keyboard.activate("char_A")
        keyboard.undo()
        keyboard.cancelBenchmark()
        XCTAssertEqual(keyboard.text, "h")
        XCTAssertEqual(changes, 1)
    }

    func testDeleteOutsideAirKeyCompositionStillActsAsKeyboardKey() {
        let keyboard = TypingController()
        var deletes = 0
        keyboard.deleteExternalCharacter = { deletes += 1 }
        keyboard.activate("delete")
        XCTAssertEqual(deletes, 1)
        keyboard.startBenchmark()
        keyboard.activate("delete")
        XCTAssertEqual(deletes, 1)
    }

    func testDestinationChangeClearsOldUndoAndSuggestions() async {
        let keyboard = TypingController()
        keyboard.activate("char_H")
        keyboard.resetExternalComposition()
        keyboard.undo()
        XCTAssertEqual(keyboard.text, "")
        XCTAssertFalse(keyboard.canUndo)
        keyboard.activate("char_A")
        XCTAssertEqual(keyboard.text, "a")
    }

    func testIdleFramesDoNotInvalidateWholeKeyboardView() {
        let keyboard = TypingController()
        var invalidations = 0
        let subscription = keyboard.objectWillChange.sink { invalidations += 1 }
        for tick in 1...30 { keyboard.process(HandFrame(timestamp: Double(tick) / 30)) }
        XCTAssertEqual(invalidations, 0)
        withExtendedLifetime(subscription) {}
    }
}
