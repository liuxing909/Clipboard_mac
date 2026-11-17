import AppKit
import SwiftUI

/// A deliberately small, noninteractive title region. Keep buttons and inputs outside it.
class WindowDragView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "拖动标题区域移动窗口"
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Labels inside the native header must behave like its empty space.
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window, window.isMovable,
            window.attachedSheet == nil, event.windowNumber == window.windowNumber,
            bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        drag(window, with: event)
    }

    /// Kept overridable so routing tests never start a live Window Server drag.
    func drag(_ window: NSWindow, with event: NSEvent) {
        window.performDrag(with: event)
    }
}

/// Overlay only the title and adjacent blank space, leaving controls as sibling views.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}
