import AppKit
import SwiftUI

struct KeyboardDragHandle: NSViewRepresentable {
    var dragging: (Bool) -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) { view.dragging = dragging }

    final class HandleView: NSView {
        var dragging: (Bool) -> Void = { _ in }
        override var acceptsFirstResponder: Bool { false }
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragging(true)
            window.performDrag(with: event)
            dragging(false)
        }
        override func accessibilityLabel() -> String? { "Move keyboard" }
        override func accessibilityHelp() -> String? { "Drag with the mouse, or aim here and hold a pinch to move the keyboard." }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .handle }
    }
}
