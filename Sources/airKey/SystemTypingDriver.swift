import AppKit
@preconcurrency import ApplicationServices
import Combine

struct TextDelta: Equatable {
    let deleteCount: Int
    let deletedUTF16Count: Int
    let inserted: String

    init(from old: String, to new: String) {
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let removed = String(old.dropFirst(prefix))
        deleteCount = removed.count
        deletedUTF16Count = removed.utf16.count
        inserted = String(new.dropFirst(prefix))
    }
}

/// Only writes to the currently focused, non-secure editable field. It never
/// captures physical keystrokes or reads the destination document's text.
@MainActor
final class SystemTypingDriver: ObservableObject {
    @Published private(set) var status = "Click a text field in another app"
    @Published private(set) var needsPermission = !AXIsProcessTrusted()
    private(set) var hasEditableFocus = false
    private struct Destination {
        let pid: pid_t
        let element: AXUIElement
        var selection: TextSelection?
    }
    private var destination: Destination?
    private var caret = PostedCaret()
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func reset() { destination = nil; caret.reset(to: nil) }
    func refreshStatus() { _ = focusedDestination() }
    @discardableResult func refreshPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        if needsPermission == trusted { needsPermission = !trusted }
        if !trusted {
            hasEditableFocus = false
            if status != "Enable Accessibility to type into apps" { status = "Enable Accessibility to type into apps" }
        }
        return trusted
    }

    /// Called before an input begins. Pending words cannot follow focus to another app.
    func prepare(_ keyboard: TypingController) {
        let next = focusedDestination()
        let changed: Bool
        if let current = destination, let next {
            changed = current.pid != next.pid || !CFEqual(current.element, next.element)
                || (next.selection.map { !caret.accepts($0, at: now) } ?? true)
        } else { changed = destination != nil || next != nil }
        if changed { keyboard.resetExternalComposition(); caret.reset(to: next?.selection) }
        destination = next
    }

    func emit(from old: String, to new: String) -> Bool {
        guard let target = verifiedDestination() else { return false }
        let delta = TextDelta(from: old, to: new)
        // Replacements belong exclusively to text entered since this caret was selected.
        var selection = caret.expected ?? target.selection
        guard delta.deleteCount == 0 || selection?.length == 0 else {
            status = "This field supports direct typing; select a suggestion before leaving the word."
            return false
        }
        // Do not guess a replacement range in editors that expose no caret.
        guard delta.deleteCount == 0 || selection != nil else { return false }
        for character in old.suffix(delta.deleteCount).reversed() {
            key(51, pid: target.pid)
            if let current = selection {
                selection = TextSelection(location: max(0, current.location - String(character).utf16.count))
                caret.posted(selection!, at: now)
            }
        }
        for character in delta.inserted {
            if character == "\n" { key(36, pid: target.pid) }
            else {
                let units = Array(String(character).utf16)
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
                units.withUnsafeBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress!)
                    up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress!)
                }
                down.flags = []; up.flags = []
                down.postToPid(target.pid); up.postToPid(target.pid)
            }
            if let current = selection {
                selection = TextSelection(location: current.location + String(character).utf16.count)
                caret.posted(selection!, at: now)
            }
        }
        return true
    }

    func deleteCharacter() {
        guard let current = destination, let target = focusedDestination(),
              current.pid == target.pid, CFEqual(current.element, target.element) else { return }
        key(51, pid: target.pid)
        // Empty-context Delete behaves like a hardware key, including hold-repeat.
        // The next new gesture re-reads the actual caret (including Unicode width).
        destination = target
        caret.reset(to: target.selection)
    }

    private func key(_ code: CGKeyCode, pid: pid_t) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = []
            event?.postToPid(pid)
        }
    }

    private func verifiedDestination() -> Destination? {
        guard let current = destination else {
            _ = focusedDestination() // retain the specific permission/focus explanation
            return nil
        }
        guard let focused = focusedDestination() else { return nil }
        guard current.pid == focused.pid, CFEqual(current.element, focused.element),
              focused.selection.map({ caret.accepts($0, at: now) }) ?? (current.selection == nil) else {
            status = "Text focus changed. Aim and pinch again."
            return nil
        }
        return focused
    }

    private func focusedDestination() -> Destination? {
        hasEditableFocus = false
        guard refreshPermission() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            status = "Click a text field in another app"; return nil
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
            return result
        }
        var element = unsafeDowncast(value, to: AXUIElement.self)
        for _ in 0..<5 {
            AXUIElementSetMessagingTimeout(element, 0.05)
            if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
                status = "Secure fields are excluded"; return nil
            }
            let role = attribute(element, kAXRoleAttribute) as? String
            let editable = attribute(element, kAXIsEditableAttribute) as? Bool
            if editable != false, attribute(element, kAXEnabledAttribute) as? Bool != false,
               editable == true || [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "") {
                var selection: TextSelection?
                if let rangeValue = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(rangeValue) == AXValueGetTypeID() {
                    var range = CFRange()
                    if AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &range), range.location >= 0, range.length >= 0 {
                        selection = TextSelection(range)
                    }
                }
                let label = "Typing into \(app.localizedName ?? "active app")"
                if status != label { status = label }
                hasEditableFocus = true
                return Destination(pid: app.processIdentifier, element: element, selection: selection)
            }
            guard let parent = attribute(element, "AXEditableAncestor") ?? attribute(element, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = unsafeDowncast(parent, to: AXUIElement.self)
        }
        status = "Click an editable text field in another app"
        return nil
    }
}
