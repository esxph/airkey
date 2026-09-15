import XCTest
@testable import airKey

final class HandIntentTests: XCTestCase {
    private let size = CGSize(width: 1100, height: 760)
    private func sample(_ time: Double, left: CGFloat = 0.3, right: CGFloat = 0.7,
                        closed: Bool = false, wrist: Bool = true) -> HandFrame {
        var frame = HandFrame(timestamp: time, cursors: [.left: CGPoint(x: left, y: 0.4), .right: CGPoint(x: right, y: 0.4)],
                              phases: [.left: closed ? .closed : .open, .right: .open], tracked: [.left, .right],
                              pinchScores: [.left: closed ? 0.2 : 0.9, .right: 0.9], imageSize: size)
        if wrist {
            for side in HandSide.allCases {
                let point = frame.cursors[side]!
                frame.visuals[side] = HandFeedbackVisual(side: side, indexTip: point, thumbTip: point, wrist: point, confidence: 1)
            }
        }
        return frame
    }
    private func update(_ guarder: inout HandIntentGuard, _ frame: HandFrame) {
        guarder.update(frame, projection: CameraProjection(imageSize: size, viewSize: size), cell: CGSize(width: 70, height: 65))
    }
    private func warm(_ guarder: inout HandIntentGuard) {
        for tick in 0...10 { update(&guarder, sample(Double(tick) * 0.1)) }
    }

    func testIdlePeerBlockedButActiveStationaryHandCanRepeat() {
        var guarder = HandIntentGuard(); warm(&guarder)
        guarder.accepted(.right, at: 0.9)
        XCTAssertTrue(guarder.shouldIgnore(guarder.evidence(for: .left, at: 1, candidates: [.left]), corrections: 0))
        XCTAssertFalse(guarder.shouldIgnore(guarder.evidence(for: .right, at: 1, candidates: [.right]), corrections: 0))
    }

    func testDeliberateMovementAndPauseAllowHandover() {
        var guarder = HandIntentGuard(); warm(&guarder)
        guarder.accepted(.right, at: 0.9)
        update(&guarder, sample(1.1, left: 0.35))
        XCTAssertFalse(guarder.shouldIgnore(guarder.evidence(for: .left, at: 1.1, candidates: [.left]), corrections: 6))
        XCTAssertFalse(guarder.shouldIgnore(guarder.evidence(for: .left, at: 2.2, candidates: [.left]), corrections: 0))
    }

    func testFingerClosureWithoutWristDoesNotCountAsAiming() {
        var guarder = HandIntentGuard()
        for tick in 0...10 { update(&guarder, sample(Double(tick) * 0.1, wrist: false)) }
        guarder.accepted(.right, at: 1)
        update(&guarder, sample(1.1, left: 0.36, closed: true, wrist: false))
        XCTAssertTrue(guarder.shouldIgnore(guarder.evidence(for: .left, at: 1.1, candidates: [.left]), corrections: 0))
    }

    func testSmallJitterDoesNotWakeRestingHand() {
        var guarder = HandIntentGuard(); warm(&guarder)
        guarder.accepted(.right, at: 1)
        update(&guarder, sample(1.1, left: 0.303))
        XCTAssertTrue(guarder.shouldIgnore(guarder.evidence(for: .left, at: 1.1, candidates: [.left]), corrections: 0))
    }

    func testTrackingGapAndResetDiscardIdleEvidence() {
        var guarder = HandIntentGuard(); warm(&guarder)
        guarder.accepted(.right, at: 1)
        update(&guarder, sample(1.5))
        XCTAssertFalse(guarder.shouldIgnore(guarder.evidence(for: .left, at: 1.5, candidates: [.left]), corrections: 6))
        guarder.reset()
        XCTAssertNil(guarder.evidence(for: .left, at: 1.5, candidates: [.left]))
    }

    func testSimultaneousMovingHandSuppliesActivityWithoutEventOrder() {
        var guarder = HandIntentGuard(); warm(&guarder)
        update(&guarder, sample(1.1, right: 0.65))
        XCTAssertTrue(guarder.shouldIgnore(guarder.evidence(for: .left, at: 1.1, candidates: [.right, .left]), corrections: 0))
        XCTAssertFalse(guarder.shouldIgnore(guarder.evidence(for: .right, at: 1.1, candidates: [.left, .right]), corrections: 0))
    }

    func testExplicitCorrectionsStrengthenOnlyBoundedIdleContext() {
        let guarder = HandIntentGuard()
        let evidence = HandIntentEvidence(side: .left, idleDuration: 0.5, otherActivityAge: 1)
        XCTAssertFalse(guarder.shouldIgnore(evidence, corrections: 0))
        XCTAssertTrue(guarder.shouldIgnore(evidence, corrections: 6))
        XCTAssertFalse(guarder.shouldIgnore(HandIntentEvidence(side: .left, idleDuration: 0.1, otherActivityAge: 0), corrections: 100))
    }

    func testLegacyProfileKeepsExistingLearning() throws {
        let data = Data(#"{"version":1,"enabled":true,"aim":{},"languages":{"es":{"words":{"hola":2},"nextWords":{},"swipes":[]}}}"#.utf8)
        let profile = try JSONDecoder().decode(PersonalProfile.self, from: data)
        XCTAssertEqual(profile.languages["es"]?.words["hola"], 2)
        XCTAssertNil(profile.accidentalPinches)
    }
}

@MainActor
final class HandIntentIntegrationTests: XCTestCase {
    private func feed(_ controller: TypingController, time: Double, event: HandSide? = nil) {
        let size = controller.sceneSize
        let rect = controller.layout.keyFrames(in: size)["char_L"]!
        let point = CGPoint(x: 1 - rect.midX / size.width, y: 1 - rect.midY / size.height)
        controller.process(HandFrame(timestamp: time,
            events: event.map { [HandEvent(side: $0, kind: .began, pointer: point, timestamp: time)] } ?? [],
            cursors: [.left: point, .right: point],
            phases: [.left: event == .left ? .closed : .open, .right: event == .right ? .closed : .open],
            tracked: [.left, .right], pinchScores: [.left: event == .left ? 0.2 : 0.9, .right: event == .right ? 0.2 : 0.9], imageSize: size))
    }

    func testRejectedOffHandNeverTypesOrStartsSwipe() {
        for swipe in [false, true] {
            let controller = TypingController(); controller.swipeMode = swipe
            for tick in 0...8 { feed(controller, time: Double(tick) * 0.1) }
            feed(controller, time: 0.85, event: .right)
            feed(controller, time: 0.9, event: .left)
            XCTAssertNil(controller.traces[.left])
            XCTAssertEqual(controller.text, swipe ? "" : "l")
            XCTAssertTrue(controller.message.contains("Ignored"))
        }
    }

    func testExplicitCorrectionPersistsButOrdinaryUndoDoesNotTrain() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("profile.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = TypingController(profileURL: url)
        for tick in 0...4 { feed(controller, time: Double(tick) * 0.1) }
        feed(controller, time: 0.45, event: .right)
        feed(controller, time: 0.5, event: .left)
        XCTAssertEqual(controller.text, "ll")
        XCTAssertTrue(controller.canCorrectAccidentalPinch)
        controller.correctAccidentalPinch()
        XCTAssertEqual(controller.text, "l")
        XCTAssertEqual(controller.profile.accidentalPinches?["Left"], 1)
        await controller.waitForProfileSave()
        XCTAssertEqual(PersonalProfileStore(url: url).load().accidentalPinches?["Left"], 1)
        controller.undo()
        XCTAssertEqual(controller.profile.accidentalPinches?["Left"], 1)
        controller.resetLearning()
        XCTAssertNil(controller.profile.accidentalPinches)
        XCTAssertFalse(controller.canCorrectAccidentalPinch)
    }

    func testMouseEditsNeverTeachRestingHandAndPauseStopsLearning() {
        let controller = TypingController(); controller.setLearningEnabled(false)
        for tick in 0...4 { feed(controller, time: Double(tick) * 0.1) }
        feed(controller, time: 0.45, event: .right)
        feed(controller, time: 0.5, event: .left)
        controller.correctAccidentalPinch()
        XCTAssertEqual(controller.text, "l")
        XCTAssertNil(controller.profile.accidentalPinches)
        controller.activate("char_A")
        XCTAssertFalse(controller.canCorrectAccidentalPinch)
    }

    func testProtectionCanBeDisabled() {
        let controller = TypingController(); controller.restingHandProtection = false
        for tick in 0...8 { feed(controller, time: Double(tick) * 0.1) }
        feed(controller, time: 0.85, event: .right)
        feed(controller, time: 0.9, event: .left)
        XCTAssertEqual(controller.text, "ll")
    }
}
