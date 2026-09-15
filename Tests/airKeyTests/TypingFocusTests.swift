import AppKit
import XCTest
@testable import airKey

@MainActor
private final class FocusFixture {
    private let nodes: [String: AXUIElement] = Dictionary(uniqueKeysWithValues:
        ["system", "chrome", "chromeField", "editor", "editorField", "otherField", "webChild", "airkey"]
            .enumerated().map { ($0.element, AXUIElementCreateApplication(pid_t(40_000 + $0.offset))) })
    private let owners: [String: pid_t] = ["chrome": 11, "chromeField": 11, "webChild": 11,
        "editor": 22, "editorField": 22, "otherField": 22, "airkey": 99]
    var attributes: [String: [String: CFTypeRef]] = [:]
    var beforeRead: ((String, String) -> Void)?
    var sent: [(SystemTypingDriver.Output, pid_t)] = []

    init() {
        for field in ["chromeField", "editorField", "otherField"] {
            var range = CFRange(location: 0, length: 0)
            attributes[field] = [kAXRoleAttribute: kAXTextAreaRole as NSString,
                kAXSelectedTextRangeAttribute: AXValueCreate(.cfRange, &range)!]
        }
        attributes["webChild"] = [kAXRoleAttribute: kAXStaticTextRole as NSString]
        setFocus(app: "chrome", field: "chromeField")
        // Background apps can retain their own last focused field. It must not
        // become the destination unless the system-wide focus agrees.
        attributes["chrome"] = [kAXFocusedUIElementAttribute: nodes["chromeField"]!]
    }

    func setFocus(app: String, field: String) {
        attributes["system"] = [kAXFocusedApplicationAttribute: nodes[app]!, kAXFocusedUIElementAttribute: nodes[field]!]
    }

    func setParent(_ parent: String, of child: String) {
        attributes[child, default: [:]]["AXEditableAncestor"] = nodes[parent]!
    }

    func driver(trusted: Bool = true) -> SystemTypingDriver {
        let access = TypingFocusAccess(systemWide: nodes["system"]!, ownPID: 99, attribute: { [self] element, name in
            let id = nodes.first { CFEqual($0.value, element) }!.key
            beforeRead?(id, name)
            return attributes[id]?[name]
        }, pid: { [self] element in
            owners[nodes.first { CFEqual($0.value, element) }!.key]
        }, appName: { $0 == 11 ? "Chrome" : "TextEdit" })
        return SystemTypingDriver(focusAccess: access, permissionCheck: { trusted }, eventWriter: { [self] event, pid in
            sent.append((event, pid)); return true
        })
    }

    func keyboard(for driver: SystemTypingDriver) -> TypingController {
        let keyboard = TypingController()
        keyboard.prepareExternalInput = { [weak keyboard] in if let keyboard { driver.prepare(keyboard) } }
        keyboard.outputTextChange = { driver.emit(from: $0, to: $1) }
        keyboard.deleteExternalCharacter = { driver.deleteCharacter() }
        return keyboard
    }
}

@MainActor
final class TypingFocusTests: XCTestCase {
    func testSwitchFromChromeToEditorUsesKeyboardFocusAndClearsOldComposition() {
        let fixture = FocusFixture(), driver = fixture.driver()
        let keyboard = fixture.keyboard(for: driver)
        keyboard.activate("char_H")
        fixture.setFocus(app: "editor", field: "editorField")
        keyboard.activate("char_A")
        XCTAssertEqual(fixture.sent.map(\.1), [11, 22])
        XCTAssertEqual(fixture.sent.map(\.0), [.text("h"), .text("a")])
        XCTAssertEqual(keyboard.text, "a", "A new field must not inherit the old app's word or replacement range")
        XCTAssertEqual(driver.status, "Typing into TextEdit")
    }

    func testInconsistentGlobalApplicationAndFieldCannotTypeIntoEitherApp() {
        let fixture = FocusFixture(), driver = fixture.driver()
        let keyboard = fixture.keyboard(for: driver)
        fixture.setFocus(app: "chrome", field: "editorField")
        keyboard.activate("char_H")
        XCTAssertTrue(fixture.sent.isEmpty)
        XCTAssertEqual(keyboard.text, "")
        XCTAssertFalse(driver.hasEditableFocus)
        XCTAssertEqual(driver.status, TypingFocusFailure.changed.message)
    }

    func testAppOrFieldSwitchDuringAccessibilityReadCancelsThatInput() {
        for field in ["chromeField", "otherField"] {
            let fixture = FocusFixture(), driver = fixture.driver()
            let keyboard = fixture.keyboard(for: driver)
            if field == "otherField" { fixture.setFocus(app: "editor", field: "editorField") }
            fixture.beforeRead = { node, attribute in
                if attribute == kAXSelectedTextRangeAttribute, node == "chromeField" || node == "editorField" {
                    fixture.setFocus(app: "editor", field: field == "chromeField" ? "editorField" : "otherField")
                }
            }
            keyboard.activate("char_H")
            XCTAssertTrue(fixture.sent.isEmpty)
            XCTAssertEqual(keyboard.text, "")
        }
    }

    func testFocusChangeAfterGestureStartsCannotDeliverItsWordOrDeleteToOldApp() {
        let fixture = FocusFixture(), driver = fixture.driver()
        let keyboard = fixture.keyboard(for: driver)
        driver.prepare(keyboard)
        fixture.setFocus(app: "editor", field: "editorField")
        XCTAssertFalse(driver.emit(from: "", to: "hola "))
        driver.deleteCharacter()
        XCTAssertTrue(fixture.sent.isEmpty)
        keyboard.activate("char_A")
        XCTAssertEqual(fixture.sent.map(\.1), [22])
        XCTAssertEqual(fixture.sent.map(\.0), [.text("a")])
    }

    func testSwitchingFieldsInSameAppRejectsPendingReplacement() {
        let fixture = FocusFixture(), driver = fixture.driver()
        let keyboard = fixture.keyboard(for: driver)
        fixture.setFocus(app: "editor", field: "editorField")
        keyboard.activate("char_H")
        fixture.setFocus(app: "editor", field: "otherField")
        XCTAssertFalse(driver.emit(from: "h", to: "hola "))
        XCTAssertEqual(fixture.sent.count, 1)
        keyboard.activate("char_A")
        XCTAssertEqual(keyboard.text, "a")
        XCTAssertEqual(fixture.sent.map(\.0), [.text("h"), .text("a")])
    }

    func testUnreadableFocusDoesNotReuseChromeOrLeaveReadyStatus() {
        let fixture = FocusFixture(), driver = fixture.driver()
        let keyboard = fixture.keyboard(for: driver)
        keyboard.activate("char_H")
        fixture.attributes["system"] = [:]
        keyboard.activate("char_A")
        XCTAssertEqual(fixture.sent.count, 1)
        XCTAssertEqual(keyboard.text, "")
        XCTAssertFalse(driver.hasEditableFocus)
        XCTAssertEqual(driver.status, TypingFocusFailure.unavailable.message)
    }

    func testPermissionSecureFieldAndOwnAppNeverReceiveKeys() {
        for reason in ["permission", "secure", "ownApp"] {
            let fixture = FocusFixture(), driver = fixture.driver(trusted: reason != "permission")
            let keyboard = fixture.keyboard(for: driver)
            if reason == "secure" { fixture.attributes["chromeField"]?[kAXSubroleAttribute] = kAXSecureTextFieldSubrole as NSString }
            if reason == "ownApp" { fixture.setFocus(app: "airkey", field: "airkey") }
            keyboard.activate("char_H")
            XCTAssertTrue(fixture.sent.isEmpty)
            XCTAssertFalse(driver.hasEditableFocus)
        }
    }

    func testEditableWebAncestorMustBelongToTheFocusedApp() {
        let fixture = FocusFixture(), driver = fixture.driver()
        let keyboard = fixture.keyboard(for: driver)
        fixture.setParent("chromeField", of: "webChild")
        fixture.setFocus(app: "chrome", field: "webChild")
        keyboard.activate("char_H")
        XCTAssertEqual(fixture.sent.map(\.1), [11])
        fixture.setParent("editorField", of: "webChild")
        keyboard.activate("char_A")
        XCTAssertEqual(fixture.sent.count, 1)
        XCTAssertEqual(driver.status, TypingFocusFailure.changed.message)
    }
}
