import AppKit
import SwiftUI
import XCTest
@testable import airKey

final class PostedCaretTests: XCTestCase {
    func testFastPostedLettersAcceptDelayedAndIntermediateCaretReports() {
        var caret = PostedCaret(); caret.reset(to: TextSelection(location: 10))
        caret.posted(TextSelection(location: 11), at: 1)
        caret.posted(TextSelection(location: 12), at: 1.02)
        XCTAssertTrue(caret.accepts(TextSelection(location: 10), at: 1.03))
        XCTAssertTrue(caret.accepts(TextSelection(location: 11), at: 1.04))
        XCTAssertTrue(caret.accepts(TextSelection(location: 12), at: 1.05))
        XCTAssertFalse(caret.accepts(TextSelection(location: 10), at: 1.06), "Acknowledged input must not hide a later caret move")
    }
    func testUnrelatedSelectionAndExpiredDeliveryCannotReuseComposition() {
        var caret = PostedCaret(); caret.reset(to: TextSelection(location: 10))
        caret.posted(TextSelection(location: 11), at: 1)
        XCTAssertFalse(caret.accepts(TextSelection(location: 4), at: 1.01))
        XCTAssertFalse(caret.accepts(TextSelection(location: 10, length: 3), at: 1.02))
        XCTAssertFalse(caret.accepts(TextSelection(location: 10), at: 1.21))
    }
    func testSelectionReplacementAndUnicodePositionsAreTrackedInUTF16() {
        var caret = PostedCaret(); caret.reset(to: TextSelection(location: 4, length: 7))
        caret.posted(TextSelection(location: 6), at: 1) // emoji replaces selected text
        XCTAssertTrue(caret.accepts(TextSelection(location: 4, length: 7), at: 1.01))
        XCTAssertTrue(caret.accepts(TextSelection(location: 6), at: 1.02))
        caret.reset(to: TextSelection(location: 2)) // different destination/caret
        XCTAssertFalse(caret.accepts(TextSelection(location: 6), at: 1.03))
    }
}

final class KeyboardVisibilityTests: XCTestCase {
    func testIdleFadeTuckAndExplicitRestore() {
        var state = KeyboardVisibility(); state.show(at: 0)
        state.update(at: 7.9, fullScreen: false, editing: false, busy: false)
        XCTAssertEqual(state.state, .visible)
        state.update(at: 8, fullScreen: false, editing: false, busy: false)
        XCTAssertEqual(state.state, .faded)
        state.activity(at: 10)
        XCTAssertEqual(state.state, .visible)
        state.update(at: 55, fullScreen: false, editing: false, busy: false)
        XCTAssertEqual(state.state, .tucked)
        state.activity(at: 56)
        XCTAssertEqual(state.state, .tucked, "Tracking or incidental activity must not silently restart a tucked camera")
        state.show(at: 60)
        XCTAssertEqual(state.state, .visible)
    }
    func testFullScreenHonorsExplicitRestoreAndEditableFocus() {
        var state = KeyboardVisibility(); state.show(at: 0)
        state.update(at: 5, fullScreen: true, editing: false, busy: false)
        XCTAssertEqual(state.state, .visible)
        state.update(at: 16, fullScreen: true, editing: true, busy: false)
        XCTAssertEqual(state.state, .faded)
        state.activity(at: 17)
        state.update(at: 18, fullScreen: true, editing: false, busy: false)
        XCTAssertEqual(state.state, .visible)
        state.update(at: 20, fullScreen: true, editing: false, busy: false)
        XCTAssertEqual(state.state, .tucked)
    }
    func testHeldInputAndPracticePreventHidingAndPreferencesCanDisableIt() {
        var state = KeyboardVisibility(); state.show(at: 0)
        state.update(at: 60, fullScreen: true, editing: false, busy: true)
        XCTAssertEqual(state.state, .visible)
        state.fadeEnabled = false; state.tuckEnabled = false; state.fullScreenEnabled = false
        state.update(at: 200, fullScreen: true, editing: false, busy: false)
        XCTAssertEqual(state.state, .visible)
        state.hide(); state.update(at: 300, fullScreen: false, editing: true, busy: true)
        XCTAssertEqual(state.state, .hidden)
    }
    func testSmallPointerNoiseDoesNotResetIdleButMovementRestoresIt() {
        var state = KeyboardVisibility(); state.show(at: 0)
        var frame = HandFrame(timestamp: 1, cursors: [.right: CGPoint(x: 0.5, y: 0.5)], tracked: [.right])
        state.observe(frame, size: CGSize(width: 1100, height: 444), hasPress: false)
        frame.timestamp = 5; frame.cursors[.right] = CGPoint(x: 0.501, y: 0.5)
        state.observe(frame, size: CGSize(width: 1100, height: 444), hasPress: false)
        state.update(at: 9, fullScreen: false, editing: false, busy: false)
        XCTAssertEqual(state.state, .faded)
        frame.timestamp = 10; frame.cursors[.right] = CGPoint(x: 0.53, y: 0.5); frame.phases[.right] = .open
        state.observe(frame, size: CGSize(width: 1100, height: 444), hasPress: false)
        XCTAssertEqual(state.state, .visible)
    }
    func testInvisibleKeyboardRequiresDeliberateOpenHandMovementToWake() {
        var state = KeyboardVisibility(); state.show(at: 0)
        state.update(at: 8, fullScreen: false, editing: false, busy: false)
        var frame = HandFrame(timestamp: 9, cursors: [.right: CGPoint(x: 0.5, y: 0.5)],
            phases: [.right: .closed], tracked: [.right])
        state.observe(frame, size: CGSize(width: 1100, height: 444), hasPress: true)
        frame.timestamp = 10; frame.cursors[.right] = CGPoint(x: 0.6, y: 0.5)
        state.observe(frame, size: CGSize(width: 1100, height: 444), hasPress: true)
        XCTAssertEqual(state.state, .faded, "Invisible keys and closed-hand motion must not reactivate typing")
        frame.timestamp = 11; frame.phases[.right] = .open
        state.observe(frame, size: CGSize(width: 1100, height: 444), hasPress: false)
        XCTAssertEqual(state.state, .faded)
        frame.timestamp = 12; frame.cursors[.right] = CGPoint(x: 0.64, y: 0.5)
        state.observe(frame, size: CGSize(width: 1100, height: 444), hasPress: false)
        XCTAssertEqual(state.state, .visible)
    }
    func testOnlyDisplayCoveringWindowsTriggerFullScreen() {
        let screen = CGRect(x: 1440, y: -100, width: 1920, height: 1080)
        XCTAssertTrue(FullScreenMonitor.covers(screen, screen: screen))
        XCTAssertFalse(FullScreenMonitor.covers(screen.insetBy(dx: 0, dy: 24), screen: screen))
        XCTAssertFalse(FullScreenMonitor.covers(CGRect(x: 0, y: 0, width: 1920, height: 1080), screen: screen))
    }
}

@MainActor
final class CompactKeyboardTests: XCTestCase {
    func testCompactLayoutMatchesVisibleKeyAndSuggestionTargetsWithoutShrinkingKeys() {
        let keyboard = TypingController(); keyboard.useCompactKeyboard()
        let size = CGSize(width: 1100, height: 444)
        keyboard.setSceneSize(size)
        let layout = keyboard.layout
        XCTAssertGreaterThanOrEqual(layout.keyFrames(in: size)["char_A"]!.height, 70)
        let suggestions = layout.suggestionFrames(in: size, count: 4)
        XCTAssertEqual(suggestions[0].minY, 16)
        XCTAssertLessThan(suggestions[0].maxY, layout.panelFrame(in: size).minY)
        for key in layout.keys {
            let rect = layout.keyFrames(in: size)[key.id]!
            XCTAssertEqual(layout.hitKey(at: CGPoint(x: rect.midX, y: rect.midY), in: size), key.id)
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect))
        }
    }
    func testFloatingKeyboardCannotTakeTextFocus() {
        let panel = KeyboardPanel(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 444),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }
    func testRenderCompactPanelWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["AIRKEY_PREVIEW_DIR"] else { return }
        let camera = CameraManager(), keyboard = TypingController(), output = SystemTypingDriver()
        keyboard.useCompactKeyboard()
        let size = CGSize(width: 1100, height: 444)
        keyboard.setSceneSize(size); await keyboard.waitForSuggestions()
        let hosting = NSHostingView(rootView: ContentView(camera: camera, keyboard: keyboard, output: output)
            .frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        hosting.appearance = NSAppearance(named: .darkAqua)
        let bounds = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; hosting.frame = bounds; hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.cacheDisplay(in: bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("airkey-compact.png"))
    }
}
