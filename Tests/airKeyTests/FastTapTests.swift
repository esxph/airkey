import XCTest
@testable import airKey

final class FastTapTests: XCTestCase {
    private func observation(_ pinch: CGFloat, x: CGFloat = 0.3, wristX: CGFloat = 0.3) -> HandObservation {
        let point = CGPoint(x: x, y: 0.6)
        return HandObservation(side: .left, pointer: point, indexTip: point, thumbTip: point,
            wrist: CGPoint(x: wristX, y: 0.4), clawOpenScore: 0, pinchDistanceScore: pinch, confidence: 0.95)
    }
    private func arm(_ engine: GestureEngine) {
        _ = engine.process(observations: [observation(0.9)], timestamp: 0)
        _ = engine.process(observations: [observation(0.9)], timestamp: 0.04)
    }

    func testFingertipTravelMovesTheCursorAndPressTogether() throws {
        let engine = GestureEngine(); arm(engine)
        let closing = engine.process(observations: [observation(0.55, x: 0.35, wristX: 0.32)], timestamp: 0.08)
        XCTAssertEqual(closing.tapCursors[.left], closing.cursors[.left])
        let pressed = engine.process(observations: [observation(0.2, x: 0.40, wristX: 0.34)], timestamp: 0.12)
        XCTAssertGreaterThan(try XCTUnwrap(pressed.events.first).pointer.x, 0.38)
        XCTAssertEqual(pressed.events.first?.pointer, pressed.tapCursors[.left])
        let held = engine.process(observations: [observation(0.2, x: 0.45, wristX: 0.36)], timestamp: 0.16)
        XCTAssertEqual(held.tapCursors[.left], held.cursors[.left])
        XCTAssertGreaterThan(try XCTUnwrap(held.cursors[.left]).x, 0.4, "Swipe motion must remain continuous")
    }

    func testSlowRelaxationDoesNotBecomeLatePressAndOpeningRecovers() {
        let engine = GestureEngine(); arm(engine)
        for tick in 1...7 {
            XCTAssertTrue(engine.process(observations: [observation(0.6)], timestamp: 0.04 + Double(tick) * 0.08).events.isEmpty)
        }
        XCTAssertTrue(engine.process(observations: [observation(0.2)], timestamp: 0.65).events.isEmpty)
        XCTAssertTrue(engine.process(observations: [observation(0.2)], timestamp: 0.69).events.isEmpty)
        _ = engine.process(observations: [observation(0.9)], timestamp: 0.73)
        _ = engine.process(observations: [observation(0.9)], timestamp: 0.77)
        _ = engine.process(observations: [observation(0.2)], timestamp: 0.81)
        XCTAssertEqual(engine.process(observations: [observation(0.2)], timestamp: 0.85).events.first?.kind, .began)
    }

    func testWristPositionCannotMovePressAwayFromFingertipMidpoint() {
        let engine = GestureEngine(); arm(engine)
        _ = engine.process(observations: [observation(0.55)], timestamp: 0.08)
        let frame = engine.process(observations: [observation(0.2, wristX: 0.5)], timestamp: 0.12)
        XCTAssertEqual(frame.events.first?.pointer, CGPoint(x: 0.3, y: 0.6))
        XCTAssertTrue(engine.process(observations: [observation(0.2, wristX: 0.5)], timestamp: 0.16).events.isEmpty)
    }

    func testInterruptedClosureMustReopenEvenInsideTrackingTimeout() {
        let engine = GestureEngine(); arm(engine)
        _ = engine.process(observations: [observation(0.55)], timestamp: 0.08)
        _ = engine.process(observations: [], timestamp: 0.10)
        XCTAssertTrue(engine.process(observations: [observation(0.2)], timestamp: 0.12).events.isEmpty)
        XCTAssertTrue(engine.process(observations: [observation(0.2)], timestamp: 0.16).events.isEmpty)
    }

    func testApproachOnlyResolvesBorderAndNeverStealsNextKeyCenter() {
        let layout = KeyboardLayout(), size = CGSize(width: 1100, height: 760)
        let left = layout.keyFrames(in: size)["char_L"]!, right = layout.keyFrames(in: size)["char_Ñ"]!
        var resolver = TapTargetResolver()
        for time in [1.0, 1.04] {
            resolver.observe(side: .right, point: CGPoint(x: left.midX, y: left.midY), time: time, layout: layout, size: size)
        }
        let border = CGPoint(x: right.minX + 0.5, y: right.midY)
        XCTAssertEqual(resolver.resolve(side: .right, point: border, time: 1.08, layout: layout, size: size), "char_L")
        XCTAssertEqual(resolver.resolve(side: .right, point: CGPoint(x: right.midX, y: right.midY), time: 1.08, layout: layout, size: size), "char_Ñ")
        XCTAssertEqual(resolver.resolve(side: .left, point: border, time: 1.08, layout: layout, size: size), "char_Ñ")
        XCTAssertEqual(resolver.resolve(side: .right, point: border, time: 1.5, layout: layout, size: size), "char_Ñ")
        resolver.reset()
        XCTAssertEqual(resolver.resolve(side: .right, point: border, time: 1.08, layout: layout, size: size), "char_Ñ")
    }
}

@MainActor
final class SpaceCorrectionTests: XCTestCase {
    func testRapidTwoHandSentenceWithSymmetricPinchesDoesNotNeedExtraDwell() {
        let controller = TypingController(), engine = GestureEngine()
        let size = controller.sceneSize, frames = controller.layout.keyFrames(in: controller.sceneSize)
        var positions: [HandSide: CGPoint] = [.left: CGPoint(x: 0.8, y: 0.25), .right: CGPoint(x: 0.2, y: 0.25)]
        var time = 0.0
        let phrase = "hola como estas hoy jaja"
        for letter in phrase {
            let key = letter == " " ? "space" : "char_\(String(letter).uppercased())"
            let rect = frames[key]!
            let side: HandSide = rect.midX < size.width / 2 ? .left : .right
            positions[side] = CameraProjection(imageSize: size, viewSize: size).unproject(CGPoint(x: rect.midX, y: rect.midY))
            // Whole-hand travel aims the midpoint; fingers close around it.
            for pinch: CGFloat in [0.9, 0.9, 0.55, 0.2] {
                let observations = HandSide.allCases.map { hand -> HandObservation in
                    let base = positions[hand]!, score: CGFloat = hand == side ? pinch : 0.9
                    let gap: CGFloat = score < 0.4 ? 0.002 : 0.04
                    return HandObservation(side: hand, pointer: base,
                        indexTip: CGPoint(x: base.x + gap, y: base.y), thumbTip: CGPoint(x: base.x - gap, y: base.y),
                        wrist: CGPoint(x: base.x, y: base.y - 0.1), clawOpenScore: 0, pinchDistanceScore: score, confidence: 0.95)
                }
                var frame = engine.process(observations: observations, timestamp: time)
                frame.imageSize = size
                for observation in observations {
                    frame.visuals[observation.side] = HandFeedbackVisual(side: observation.side, indexTip: observation.indexTip,
                        thumbTip: observation.thumbTip, wrist: observation.wrist, confidence: 0.95)
                }
                controller.process(frame)
                time += 0.025
            }
        }
        XCTAssertEqual(controller.text, phrase)
    }

    func testRecordedTypoIsOfferedAfterSpaceAndUndoRestoresOriginal() async {
        let controller = TypingController()
        controller.editText("hoña ")
        await controller.waitForSuggestions()
        XCTAssertEqual(controller.suggestionLabel(at: 0), "Fix: hola")
        XCTAssertEqual(controller.text, "hoña ", "Correction must not be silent")
        controller.activate("pred_0")
        await controller.waitForPendingInput()
        XCTAssertEqual(controller.text, "hola ")
        controller.undo()
        XCTAssertEqual(controller.text, "hoña ")
    }

    func testLaughterAndExistingWordsArePreserved() async {
        let engine = LanguageEngine()
        for word in ["jaja", "jajaja", "como", "estas", "hoy"] {
            let correction = await engine.correctionAfterSpace(for: word, language: .spanish, personal: LearnedLanguage())
            XCTAssertNil(correction, word)
        }
        let english = await engine.correctionAfterSpace(for: "hello", language: .english, personal: LearnedLanguage())
        XCTAssertNil(english)
    }

    func testContinuingToTypeInvalidatesCorrectionAndKeepsSentence() async {
        let controller = TypingController()
        controller.editText("hoña ")
        await controller.waitForSuggestions()
        controller.activate("char_C")
        await controller.waitForSuggestions()
        XCTAssertFalse(controller.suggestionLabel(at: 0).hasPrefix("Fix:"))
        XCTAssertEqual(controller.text, "hoña c")
        controller.editText("hola como estas hoy jaja ")
        await controller.waitForSuggestions()
        XCTAssertFalse(controller.suggestionLabel(at: 0).hasPrefix("Fix:"))
        XCTAssertEqual(controller.text, "hola como estas hoy jaja ")
    }
}
