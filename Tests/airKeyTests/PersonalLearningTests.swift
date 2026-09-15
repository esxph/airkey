import XCTest
@testable import airKey

final class PersonalLearningTests: XCTestCase {
    func testCalibrationKeepsUsefulRoundDespiteOneShakyPinch() {
        var calibration = AimCalibration(), previousFit = AimModel()
        let cell = CGSize(width: 1, height: 1)
        for index in 0..<12 {
            let sample = CGPoint(x: index == 4 ? -1.04 : 0.30, y: 0.05)
            XCTAssertTrue(calibration.record(point: sample, target: .zero, cell: cell))
            previousFit.observe(point: sample, target: .zero, cell: cell)
        }
        // Reproduce the former rejection, then verify that the useful cluster survives.
        XCTAssertFalse(previousFit.isReady)
        XCTAssertTrue(calibration.fit.isReady)
        XCTAssertEqual(calibration.fit.consistentTargets.count, 11)
        XCTAssertFalse(calibration.fit.consistentTargets.contains(4))
        XCTAssertEqual(calibration.fit.model.x.mean, 0.30, accuracy: 0.001)
    }

    func testRefinementRevisitsUncertainTargetAndRetainsOtherSamples() {
        var calibration = AimCalibration()
        let cell = CGSize(width: 1, height: 1)
        for index in 0..<12 {
            calibration.record(point: CGPoint(x: index < 8 ? 0.25 : -0.95, y: 0), target: .zero, cell: cell)
        }
        XCTAssertFalse(calibration.fit.isReady)
        XCTAssertEqual(calibration.fit.consistentTargets.count, 8)
        let original = calibration.samples
        calibration.refine()
        XCTAssertTrue(calibration.isRefining)
        XCTAssertEqual(Set(calibration.pendingTargets), Set(8..<12))
        let retry = calibration.index
        calibration.record(point: CGPoint(x: 0.25, y: 0), target: .zero, cell: cell)
        XCTAssertEqual(calibration.samples.count, 12)
        for index in 0..<12 where index != retry { XCTAssertEqual(calibration.samples[index], original[index]) }
        XCTAssertTrue(calibration.fit.isReady)
        XCTAssertEqual(calibration.fit.consistentTargets.count, 9)
    }

    func testCalibrationDoesNotFitAnInconsistentSplitOrAdvanceForInvalidPoints() {
        var calibration = AimCalibration()
        let cell = CGSize(width: 1, height: 1)
        XCTAssertFalse(calibration.record(point: CGPoint(x: 5, y: 0), target: .zero, cell: cell))
        XCTAssertEqual(calibration.index, 0)
        XCTAssertTrue(calibration.samples.isEmpty)
        for index in 0..<12 {
            calibration.record(point: CGPoint(x: index.isMultiple(of: 2) ? -0.9 : 0.9, y: 0), target: .zero, cell: cell)
        }
        XCTAssertFalse(calibration.fit.isReady)
        calibration.refine()
        XCTAssertEqual(calibration.pendingTargets.count, 4)
        XCTAssertEqual(calibration.samples.count, 12)
    }

    func testAimTrainingReducesHeldOutSystematicErrorAndScalesWithWindow() {
        var model = AimModel()
        let cell = CGSize(width: 70, height: 65)
        let target = CGPoint(x: 300, y: 400)
        for i in 0..<12 {
            let noise = sin(Double(i)) * 1.5
            model.observe(point: CGPoint(x: target.x + 20 + noise, y: target.y - 10 + noise), target: target, cell: cell)
        }
        XCTAssertTrue(model.isReady)
        let testPoint = CGPoint(x: target.x + 21, y: target.y - 11)
        XCTAssertLessThan(model.corrected(testPoint, cell: cell).distance(to: target), testPoint.distance(to: target) * 0.4)
        let scaledTarget = CGPoint(x: 600, y: 800), scaledPoint = CGPoint(x: 642, y: 778)
        XCTAssertLessThan(model.corrected(scaledPoint, cell: CGSize(width: 140, height: 130)).distance(to: scaledTarget),
                          scaledPoint.distance(to: scaledTarget) * 0.4)
    }

    func testUntrainedNoisyAndOutlierAimDataDoNotShiftKeys() {
        var model = AimModel()
        let target = CGPoint(x: 300, y: 400), cell = CGSize(width: 70, height: 65)
        XCTAssertFalse(model.observe(point: CGPoint(x: 900, y: 400), target: target, cell: cell))
        XCTAssertEqual(model.sampleCount, 0)
        for i in 0..<12 {
            model.observe(point: CGPoint(x: target.x + (i % 2 == 0 ? -65 : 65), y: target.y), target: target, cell: cell)
        }
        XCTAssertFalse(model.isReady)
        XCTAssertEqual(model.corrected(target, cell: cell), target)
        XCTAssertFalse(model.observe(point: CGPoint(x: CGFloat.nan, y: 0), target: target, cell: cell))
    }

    func testAimIsSeparateForEachHandAndCanBePaused() {
        var model = AimModel(), profile = PersonalProfile()
        let point = CGPoint(x: 30, y: 10), cell = CGSize(width: 80, height: 80)
        for _ in 0..<12 { model.observe(point: point, target: .zero, cell: cell) }
        profile.aim[HandSide.left.rawValue] = model
        XCTAssertLessThan(profile.corrected(point, side: .left, cell: cell).x, point.x)
        XCTAssertEqual(profile.corrected(point, side: .right, cell: cell), point)
        profile.enabled = false
        XCTAssertEqual(profile.corrected(point, side: .left, cell: cell), point)
    }

    func testExplicitLearningAddsUnknownVocabularyAndContextInCorrectLanguage() async {
        let engine = LanguageEngine()
        var personal = LearnedLanguage()
        personal.learn(word: "airkey", previous: "use")
        let words = await engine.suggestions(for: "airk", language: .english, personal: personal)
        XCTAssertEqual(words.first, "airkey")
        let next = await engine.suggestions(for: "use ", language: .english, personal: personal)
        XCTAssertEqual(next.first, "airkey")
        var profile = PersonalProfile()
        profile.languages["en"] = personal
        XCTAssertTrue(profile.language(.spanish).words.isEmpty)
        XCTAssertEqual(profile.language(.english).words["airkey"], 1)
    }

    func testTeachingNewVocabularyInvalidatesSwipeTemplates() async {
        let engine = LanguageEngine(), layout = KeyboardLayout(), size = CGSize(width: 1100, height: 800)
        let centers = layout.letterCenters(in: size), width = layout.keyFrames(in: size)["char_Q"]!.width
        let path = SwipeDecoder.resample("airkey".compactMap { centers[$0] }, count: 45)
        let before = await engine.decode(path: path, language: .english, centers: centers, keyWidth: width, text: "")
        XCTAssertFalse(before.map(\.word).contains("airkey"))
        var personal = LearnedLanguage()
        personal.learn(word: "airkey", previous: nil)
        let after = await engine.decode(path: path, language: .english, centers: centers, keyWidth: width, text: "", personal: personal)
        XCTAssertTrue(after.prefix(3).map(\.word).contains("airkey"))
        let paused = await engine.decode(path: path, language: .english, centers: centers, keyWidth: width, text: "")
        XCTAssertFalse(paused.map(\.word).contains("airkey"))
    }

    func testUnrelatedFavoriteDoesNotOverrideEstablishedNextWordContext() async {
        let engine = LanguageEngine()
        var personal = LearnedLanguage()
        personal.learn(word: "teclado", previous: nil)
        let result = await engine.suggestions(for: "muchas ", language: .spanish, personal: personal)
        XCTAssertEqual(result.first, "gracias")
    }

    func testConfirmedSwipeExampleResolvesAnAmbiguousRepeatedLetterPath() {
        let centers: [Character: CGPoint] = ["t": CGPoint(x: 50, y: 50), "o": CGPoint(x: 300, y: 50)]
        let decoder = SwipeDecoder(entries: [WordEntry(word: "to", frequency: 1000), WordEntry(word: "too", frequency: 1000)],
                                   centers: centers, keyWidth: 65)
        let path = SwipeDecoder.resample([centers["t"]!, centers["o"]!], count: 32)
        let panel = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(decoder.decode(path).first?.word, "to")
        var personal = LearnedLanguage()
        personal.learn(word: "to", previous: nil)
        personal.learn(word: "too", previous: nil, path: path, panel: panel)
        let result = decoder.decode(path, personal: personal, panel: panel)
        XCTAssertEqual(result.first?.word, "too")
        XCTAssertEqual(personal.swipes.count, 1)
        XCTAssertEqual(personal.swipes[0].points.count, 32)
    }

    func testLearningNeverOverridesClearlyDifferentSwipeGeometry() {
        let centers: [Character: CGPoint] = ["c": CGPoint(x: 10, y: 20), "a": CGPoint(x: 80, y: 80),
            "t": CGPoint(x: 150, y: 20), "d": CGPoint(x: 500, y: 20), "o": CGPoint(x: 650, y: 80), "g": CGPoint(x: 800, y: 20)]
        let decoder = SwipeDecoder(entries: [WordEntry(word: "cat", frequency: 1000), WordEntry(word: "dog", frequency: 1000)],
                                   centers: centers, keyWidth: 65)
        var personal = LearnedLanguage()
        for _ in 0..<100 { personal.learn(word: "dog", previous: nil) }
        let path = SwipeDecoder.resample("cat".compactMap { centers[$0] }, count: 32)
        XCTAssertEqual(decoder.decode(path, personal: personal).first?.word, "cat")
    }

    func testLearningReceiptReversesOnlyItsOwnWordContextAndSwipe() {
        var personal = LearnedLanguage()
        personal.learn(word: "hello", previous: "say")
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0)]
        let receipt = personal.learn(word: "hello", previous: "say", path: path,
                                     panel: CGRect(x: 0, y: 0, width: 100, height: 100))!
        personal.learn(word: "world", previous: "hello")
        personal.unlearn(receipt)
        XCTAssertEqual(personal.words["hello"], 1)
        XCTAssertEqual(personal.words["world"], 1)
        XCTAssertEqual(personal.nextWords["say"]?["hello"], 1)
        XCTAssertTrue(personal.swipes.isEmpty)
    }

    func testLearnedWordValidationAndContextBoundaries() {
        XCTAssertNil(LearnedLanguage.validWord("password123"))
        XCTAssertNil(LearnedLanguage.validWord("two words"))
        XCTAssertNil(LearnedLanguage.validWord("https://example.com"))
        XCTAssertEqual(LearnedLanguage.validWord("MAÑANA"), "mañana")
        XCTAssertEqual(LearnedLanguage.validWord("don’t"), "don't")
        XCTAssertEqual(TextEditing.accepting("don't", in: "I don’t", caps: false), "I don't ")
        XCTAssertEqual(LearnedLanguage.previousWord(in: "hello wor", completingPartial: true), "hello")
        XCTAssertNil(LearnedLanguage.previousWord(in: "hello. ", completingPartial: false))
        XCTAssertNil(LearnedLanguage.previousWord(in: "hello\n", completingPartial: false))
    }

    func testProfileRoundTripOrderedResetAndPrivateFilePermissions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("profile.json")
        let store = PersonalProfileStore(url: url)
        XCTAssertEqual(store.load().wordCount, 0)
        var profile = PersonalProfile()
        profile.languages["en", default: LearnedLanguage()].learn(word: "airkey", previous: "use")
        store.save(profile)
        await store.flush()
        XCTAssertEqual(store.load().languages["en"]?.words["airkey"], 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        store.save(profile)
        store.save(PersonalProfile())
        await store.flush()
        XCTAssertEqual(store.load().wordCount, 0)
        try Data("corrupt".utf8).write(to: url)
        XCTAssertEqual(store.load().wordCount, 0)
    }
}

@MainActor
final class PersonalLearningIntegrationTests: XCTestCase {
    private let size = CGSize(width: 1100, height: 760)
    private func pinch(_ controller: TypingController, point: CGPoint, time: Double, side: HandSide = .left) {
        let normalized = CGPoint(x: 1 - point.x / size.width, y: 1 - point.y / size.height)
        controller.process(HandFrame(timestamp: time,
            events: [HandEvent(side: side, kind: .began, pointer: normalized, timestamp: time)],
            cursors: [side: normalized], phases: [side: .closed], tracked: [side], pinchScores: [side: 0.2], imageSize: size))
    }

    func testGuidedAimTrainingOnlyUsesLabeledPinchesAndDoesNotType() {
        let controller = TypingController(); controller.editText("keep this")
        controller.startAimTraining()
        controller.activate("char_F") // mouse clicks are not camera training samples
        XCTAssertEqual(controller.calibration?.index, 0)
        for (index, key) in AimCalibration.targets.enumerated() {
            let rect = controller.layout.keyFrames(in: size)[key]!
            pinch(controller, point: CGPoint(x: rect.midX + 18, y: rect.midY - 8), time: Double(index + 1))
        }
        XCTAssertNil(controller.calibration)
        XCTAssertEqual(controller.text, "keep this")
        XCTAssertTrue(controller.profile.aim["Left"]?.isReady == true)
        XCTAssertNil(controller.profile.aim["Right"])
        let raw = CGPoint(x: 300, y: 400)
        XCTAssertLessThan(controller.correctedAim(raw, side: .left).x, raw.x)

        // Saved calibration must not displace the visible fingertip midpoint or
        // redirect a press across the left border of H into its neighbor.
        controller.editText("")
        let rect = controller.layout.keyFrames(in: size)["char_H"]!
        let contact = CGPoint(x: rect.minX + 1, y: rect.midY)
        let normalized = CGPoint(x: 1 - contact.x / size.width, y: 1 - contact.y / size.height)
        let engine = GestureEngine()
        for (index, score) in [CGFloat(0.9), 0.9, 0.55, 0.2].enumerated() {
            let gap: CGFloat = score < 0.4 ? 0.002 : 0.04
            let hand = HandObservation(side: .left, pointer: normalized,
                indexTip: CGPoint(x: normalized.x + gap, y: normalized.y),
                thumbTip: CGPoint(x: normalized.x - gap, y: normalized.y),
                wrist: .zero, clawOpenScore: 0, pinchDistanceScore: score, confidence: 0.9, aimReference: .zero)
            var frame = engine.process(observations: [hand], timestamp: 20 + Double(index) * 0.04)
            frame.imageSize = size
            controller.process(frame)
            XCTAssertEqual(controller.displayedCursor(for: .left)!.x, contact.x, accuracy: 0.000001)
            XCTAssertEqual(controller.displayedCursor(for: .left)!.y, contact.y, accuracy: 0.000001)
        }
        XCTAssertEqual(controller.text, "h")
    }

    func testCancelledOrMixedHandPracticeDoesNotCorruptExistingModel() {
        let controller = TypingController(); controller.startAimTraining()
        let rect = controller.layout.keyFrames(in: size)["char_F"]!
        pinch(controller, point: CGPoint(x: rect.midX, y: rect.midY), time: 1)
        let next = controller.layout.keyFrames(in: size)["char_J"]!
        pinch(controller, point: CGPoint(x: next.midX, y: next.midY), time: 2, side: .right)
        XCTAssertEqual(controller.calibration?.index, 1)
        controller.cancelAimTraining()
        XCTAssertTrue(controller.profile.aim.isEmpty)
        XCTAssertEqual(controller.text, "")
    }

    func testNoisyTrainingContinuesFromSavedSamplesInsteadOfDiscardingTheRound() {
        let controller = TypingController(); controller.editText("keep this text")
        controller.startAimTraining()
        let cell = controller.layout.keyFrames(in: size)["char_Q"]!.size
        for (index, key) in AimCalibration.targets.enumerated() {
            let rect = controller.layout.keyFrames(in: size)[key]!
            let offset: CGFloat = index < 8 ? 0.25 : -0.95
            pinch(controller, point: CGPoint(x: rect.midX + offset * cell.width, y: rect.midY), time: Double(index + 1))
        }
        XCTAssertNotNil(controller.calibration)
        XCTAssertTrue(controller.calibration?.isRefining == true)
        XCTAssertTrue(controller.profile.aim.isEmpty)
        XCTAssertEqual(controller.calibration?.samples.count, 12)
        XCTAssertTrue(controller.learningSummary.contains("8/12 consistent"))
        let key = controller.calibration!.key
        let rect = controller.layout.keyFrames(in: size)[key]!
        pinch(controller, point: CGPoint(x: rect.midX + 0.25 * cell.width, y: rect.midY), time: 13)
        XCTAssertNil(controller.calibration)
        XCTAssertEqual(controller.profile.aim["Left"]?.sampleCount, 9)
        XCTAssertEqual(controller.text, "keep this text")
    }

    func testCancellingRefinementKeepsPreviousHandTraining() {
        let controller = TypingController()
        func round(start: Int, noisy: Bool) {
            controller.startAimTraining()
            let cell = controller.layout.keyFrames(in: size)["char_Q"]!.size
            for (index, key) in AimCalibration.targets.enumerated() {
                let rect = controller.layout.keyFrames(in: size)[key]!
                let dx: CGFloat = noisy ? (index.isMultiple(of: 2) ? -0.9 : 0.9) : 0.2
                pinch(controller, point: CGPoint(x: rect.midX + dx * cell.width, y: rect.midY), time: Double(start + index))
            }
        }
        round(start: 1, noisy: false)
        let previousMean = controller.profile.aim["Left"]?.x.mean
        XCTAssertNotNil(previousMean)
        round(start: 20, noisy: true)
        XCTAssertTrue(controller.calibration?.isRefining == true)
        controller.cancelAimTraining()
        XCTAssertEqual(controller.profile.aim["Left"]?.x.mean, previousMean)
    }

    func testAcceptedSuggestionLearnsAndUndoReversesLearning() async {
        let controller = TypingController(); controller.language = .english; controller.editText("thank ")
        await controller.waitForSuggestions()
        controller.activate("pred_0")
        await controller.waitForPendingInput()
        XCTAssertEqual(controller.text, "thank you ")
        XCTAssertEqual(controller.profile.languages["en"]?.words["you"], 1)
        XCTAssertEqual(controller.profile.languages["en"]?.nextWords["thank"]?["you"], 1)
        controller.undo()
        XCTAssertNil(controller.profile.languages["en"]?.words["you"])
        XCTAssertEqual(controller.text, "thank ")
    }

    func testManualVocabularyPersistsAndPausedLearningDoesNotUseIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.json")
        let controller = TypingController(profileURL: url); controller.language = .english
        controller.editText("use airkey"); controller.learnCurrentWord()
        await controller.waitForProfileSave()
        let reopened = TypingController(profileURL: url); reopened.language = .english
        XCTAssertEqual(reopened.profile.wordCount, 1)
        reopened.editText("airk"); await reopened.waitForSuggestions()
        XCTAssertEqual(reopened.suggestions.first, "airkey")
        reopened.setLearningEnabled(false)
        XCTAssertTrue(reopened.profile.language(.english).words.isEmpty)
        reopened.editText("differentword"); reopened.learnCurrentWord()
        XCTAssertEqual(reopened.profile.wordCount, 1)
        reopened.resetLearning(); await reopened.waitForProfileSave()
        XCTAssertEqual(TypingController(profileURL: url).profile.wordCount, 0)
    }

    func testTypingWithoutExplicitAcceptanceDoesNotTrainOnItsOwnGuesses() {
        let controller = TypingController()
        controller.activate("char_H"); controller.activate("char_I"); controller.activate("space")
        XCTAssertEqual(controller.profile.wordCount, 0)
        controller.editText("secret typed text")
        XCTAssertEqual(controller.profile.wordCount, 0)
    }
}
