import XCTest
@testable import airKey

final class TypingBenchmarkTests: XCTestCase {
    func testTimerStartsOnlyOnceAndIncludesCorrectionTime() throws {
        var test = TypingBenchmark(language: .english, swipe: false, protection: true, learning: true)
        XCTAssertNil(test.finish(text: "", at: 10))
        test.input(at: 10, hand: true)
        test.input(at: 30, hand: true)
        test.corrections += 1
        let result = try XCTUnwrap(test.finish(text: test.target, at: 70))
        XCTAssertEqual(result.seconds, 60)
        XCTAssertEqual(result.wordsPerMinute, Double(test.target.count) / 5, accuracy: 0.001)
        XCTAssertEqual(result.errors, 0)
        XCTAssertEqual(result.corrections, 1)
        XCTAssertEqual(result.handInputs, 2)
    }

    func testUnicodeEditsIncludeAccentsSpacesAndExtraCharacters() {
        XCTAssertEqual(TypingBenchmark.distance(Array("mañana"), Array("manana")), 1)
        XCTAssertEqual(TypingBenchmark.distance(Array("café"), Array("cafe\u{301}")), 0)
        XCTAssertEqual(TypingBenchmark.distance(Array("a b"), Array("ab")), 1)
        XCTAssertEqual(TypingBenchmark.distance(Array("abc"), Array("axbc!")), 2)
        XCTAssertEqual(TypingBenchmark.distance(Array("abc"), []), 3)
    }

    func testTrailingSuggestionSpaceIsIgnoredAndAssistedInputIsFlagged() throws {
        var test = TypingBenchmark(language: .spanish, swipe: true, protection: true, learning: false, pinchThreshold: 0.5)
        test.input(at: 1, hand: false)
        let result = try XCTUnwrap(test.finish(text: test.target + " \n", at: 2))
        XCTAssertEqual(result.errors, 0)
        XCTAssertTrue(result.summary.contains("Assisted"))
        XCTAssertEqual(result.pinchThreshold, 0.5)
        XCTAssertFalse(result.report.contains(test.target))
    }

    func testEmptyAndIncompleteAttemptsRetainErrors() throws {
        var test = TypingBenchmark(language: .english, swipe: false, protection: true, learning: false)
        test.input(at: 1, hand: true)
        let result = try XCTUnwrap(test.finish(text: "", at: 5))
        XCTAssertEqual(result.errorPercent, 100)
        XCTAssertEqual(result.wordsPerMinute, 0)
        XCTAssertNil(test.finish(text: "", at: 1))
        XCTAssertNil(test.finish(text: "", at: .nan))
    }

    func testLatencyPercentilesAndUnavailableTiming() {
        XCTAssertNil(TypingBenchmark.percentile([], fraction: 0.95))
        XCTAssertEqual(TypingBenchmark.percentile([20, 5, 10, .nan, -1], fraction: 0.5), 10)
        XCTAssertEqual(TypingBenchmark.percentile([20, 5, 10], fraction: 0.95), 20)
    }
}

@MainActor
final class TypingBenchmarkIntegrationTests: XCTestCase {
    func testFinishPreservesDraftAndUndoAndReportsActualDuration() throws {
        var now = 10.0
        let controller = TypingController(clock: { now })
        controller.editText("draft")
        controller.activate("char_A")
        controller.startBenchmark()
        XCTAssertEqual(controller.text, "")
        XCTAssertFalse(controller.canFinishBenchmark)
        now = 20
        controller.activate("char_W")
        now = 50
        controller.activate("delete")
        controller.activate("char_W")
        now = 80
        controller.finishBenchmark()
        XCTAssertNil(controller.benchmark)
        XCTAssertEqual(controller.text, "drafta")
        let result = try XCTUnwrap(controller.benchmarkResult)
        XCTAssertEqual(result.seconds, 60)
        XCTAssertEqual(result.corrections, 1)
        XCTAssertEqual(result.assistedInputs, 3)
        controller.undo()
        XCTAssertEqual(controller.text, "draft")
    }

    func testCancellationAndModeChangeRestoreDraftWithoutResult() {
        let controller = TypingController()
        controller.editText("original")
        controller.startBenchmark()
        controller.editText("practice")
        controller.language = .english
        XCTAssertNil(controller.benchmark)
        XCTAssertNil(controller.benchmarkResult)
        XCTAssertEqual(controller.text, "original")
        controller.startBenchmark()
        controller.cancelBenchmark()
        XCTAssertEqual(controller.text, "original")
    }

    func testPracticeDoesNotTrainWordsAndManualMissesAreSeparate() async {
        let controller = TypingController()
        controller.startBenchmark()
        controller.reportMissedPinch()
        XCTAssertEqual(controller.benchmark?.reportedMisses, 0)
        controller.editText("hol")
        await controller.waitForSuggestions()
        XCTAssertFalse(controller.suggestions.isEmpty)
        controller.activate("pred_0")
        await controller.waitForPendingInput()
        XCTAssertEqual(controller.profile.wordCount, 0)
        controller.reportMissedPinch()
        XCTAssertEqual(controller.benchmark?.reportedMisses, 1)
        XCTAssertEqual(controller.benchmark?.reportedAccidents, 0)
        XCTAssertFalse(controller.canLearnCurrentWord)
    }
}
