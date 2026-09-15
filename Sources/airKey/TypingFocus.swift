import AppKit
@preconcurrency import ApplicationServices

struct TypingDestination {
    let pid: pid_t
    let element: AXUIElement
    let selection: TextSelection?
    let appName: String
}

enum TypingFocusFailure: Error {
    case noFocus, unavailable, changed, secure, notEditable

    var message: String {
        switch self {
        case .noFocus: "Click a text field in another app"
        case .unavailable: "Could not read keyboard focus. Click the destination text field again."
        case .changed: "Text focus changed. Aim and pinch again."
        case .secure: "Secure fields are excluded"
        case .notEditable: "Click an editable text field in another app"
        }
    }
}

/// The small AX boundary also lets regression tests model two apps changing
/// focus during a read without inspecting real windows or posting real keys.
@MainActor
struct TypingFocusAccess {
    let systemWide: AXUIElement
    let ownPID: pid_t
    let attribute: (AXUIElement, String) -> CFTypeRef?
    let pid: (AXUIElement) -> pid_t?
    let appName: (pid_t) -> String

    static var live: Self {
        Self(systemWide: AXUIElementCreateSystemWide(), ownPID: ProcessInfo.processInfo.processIdentifier,
             attribute: { element, name in
                 AXUIElementSetMessagingTimeout(element, 0.05)
                 var value: CFTypeRef?
                 guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
                 return value
             }, pid: { element in
                 var pid: pid_t = 0
                 guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
                 return pid
             }, appName: { NSRunningApplication(processIdentifier: $0)?.localizedName ?? "active app" })
    }
}

@MainActor
struct TypingFocusReader {
    let access: TypingFocusAccess

    private func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = access.attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    func read() -> Result<TypingDestination, TypingFocusFailure> {
        // System-wide AX focus identifies the keyboard recipient. Never fall
        // back to NSWorkspace's frontmost app or a previously focused app.
        guard let application = element(access.systemWide, kAXFocusedApplicationAttribute),
              let pid = access.pid(application) else { return .failure(.unavailable) }
        guard pid != access.ownPID else { return .failure(.noFocus) }
        guard let focused = element(access.systemWide, kAXFocusedUIElementAttribute) else { return .failure(.unavailable) }
        guard access.pid(focused) == pid else { return .failure(.changed) }
        var current = focused
        for _ in 0..<5 {
            guard access.pid(current) == pid else { return .failure(.changed) }
            if access.attribute(current, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
                return .failure(.secure)
            }
            let role = access.attribute(current, kAXRoleAttribute) as? String
            let editable = access.attribute(current, kAXIsEditableAttribute) as? Bool
            if editable != false, access.attribute(current, kAXEnabledAttribute) as? Bool != false,
               editable == true || [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "") {
                var selection: TextSelection?
                if let value = access.attribute(current, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                    var range = CFRange()
                    if AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range), range.location >= 0, range.length >= 0 {
                        selection = TextSelection(range)
                    }
                }
                // AX reads are separate messages. A switch between them must
                // not combine one app's identity with another field's caret.
                guard let finalApplication = element(access.systemWide, kAXFocusedApplicationAttribute),
                      access.pid(finalApplication) == pid,
                      let finalFocus = element(access.systemWide, kAXFocusedUIElementAttribute),
                      CFEqual(finalFocus, focused) else { return .failure(.changed) }
                return .success(TypingDestination(pid: pid, element: current, selection: selection, appName: access.appName(pid)))
            }
            guard let parent = element(current, "AXEditableAncestor") ?? element(current, kAXParentAttribute) else { break }
            current = parent
        }
        return .failure(.notEditable)
    }
}
