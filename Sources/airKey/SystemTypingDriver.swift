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
    @Published private(set) var needsPermission: Bool
    private(set) var hasEditableFocus = false
    enum Output: Equatable { case key(CGKeyCode), text(String) }
    private let focus: TypingFocusReader
    private let permissionCheck: () -> Bool
    private let eventWriter: (Output, pid_t) -> Bool
    private var destination: TypingDestination?
    private var caret = PostedCaret()
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(focusAccess: TypingFocusAccess = .live,
         permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
         eventWriter: ((Output, pid_t) -> Bool)? = nil) {
        focus = TypingFocusReader(access: focusAccess)
        self.permissionCheck = permissionCheck
        self.eventWriter = eventWriter ?? Self.post
        needsPermission = !permissionCheck()
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func reset() { destination = nil; caret.reset(to: nil) }
    func refreshStatus() { _ = focusedDestination() }
    @discardableResult func refreshPermission() -> Bool {
        let trusted = permissionCheck()
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
            guard write(.key(51), to: target.pid) else { return false }
            if let current = selection {
                selection = TextSelection(location: max(0, current.location - String(character).utf16.count))
                caret.posted(selection!, at: now)
            }
        }
        for character in delta.inserted {
            let output: Output = character == "\n" ? .key(36) : .text(String(character))
            guard write(output, to: target.pid) else { return false }
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
        guard write(.key(51), to: target.pid) else { return }
        // Empty-context Delete behaves like a hardware key, including hold-repeat.
        // The next new gesture re-reads the actual caret (including Unicode width).
        destination = target
        caret.reset(to: target.selection)
    }

    private func write(_ output: Output, to pid: pid_t) -> Bool {
        guard eventWriter(output, pid) else {
            status = "Could not send the key. Click the destination text field again."
            return false
        }
        return true
    }

    private static func post(_ output: Output, pid: pid_t) -> Bool {
        let code: CGKeyCode
        switch output { case .key(let value): code = value; case .text: code = 0 }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return false }
        if case .text(let text) = output {
            let units = Array(text.utf16)
            guard !units.isEmpty else { return false }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress!)
            }
        }
        down.flags = []; up.flags = []
        down.postToPid(pid); up.postToPid(pid)
        return true
    }

    private func verifiedDestination() -> TypingDestination? {
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

    private func focusedDestination() -> TypingDestination? {
        hasEditableFocus = false
        guard refreshPermission() else { return nil }
        switch focus.read() {
        case .success(let target):
            let label = "Typing into \(target.appName)"
            if status != label { status = label }
            hasEditableFocus = true
            return target
        case .failure(let failure):
            if status != failure.message { status = failure.message }
            return nil
        }
    }
}
