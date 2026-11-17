import AppKit

@MainActor
enum WindowInteractionSelfTests {
    static func run() throws {
        try checkEventRouting()
        try checkPresentation(legacy: true)
        if #available(macOS 14.0, *) { try checkPresentation(legacy: false) }
        try checkPlacement()
        print(
            "PASS: title drag routing / modern and legacy control hit testing / remembered panel position / display changes"
        )
    }

    private static func checkEventRouting() throws {
        let window = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 416, height: 608),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovable = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 416, height: 608))
        window.contentView = content
        let drag = DragProbe(frame: NSRect(x: 14, y: 550, width: 280, height: 36))
        let label = NSTextField(labelWithString: "剪贴匣")
        label.frame = NSRect(x: 0, y: 0, width: 100, height: 36)
        drag.addSubview(label)
        content.addSubview(drag)
        let button = NSButton(frame: NSRect(x: 310, y: 550, width: 80, height: 36))
        content.addSubview(button)
        let input = FocusProbe(frame: NSRect(x: 14, y: 500, width: 380, height: 30))
        content.addSubview(input)
        window.makeFirstResponder(input)
        let responder = window.firstResponder
        try check(content.hitTest(NSPoint(x: 30, y: 560)) === drag, "title label routes to drag surface")
        try check(content.hitTest(NSPoint(x: 230, y: 560)) === drag, "blank title space routes to drag surface")
        try check(content.hitTest(NSPoint(x: 330, y: 560)) === button, "neighboring button remains clickable")
        try check(content.hitTest(NSPoint(x: 100, y: 510)) === input, "input remains outside drag surface")
        try check(drag.acceptsFirstMouse(for: nil) && !drag.acceptsFirstResponder, "drag does not steal text focus")

        func event(_ type: NSEvent.EventType, at point: NSPoint, windowNumber: Int? = nil) throws -> NSEvent {
            guard
                let value = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: windowNumber ?? window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)
            else { throw Failure.failed("constructing test mouse event") }
            return value
        }
        drag.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 30, y: 560)))
        try check(drag.dragCount == 1, "left click starts native drag routing exactly once")
        try check(window.firstResponder === responder, "routing preserves the prior first responder")
        drag.mouseDown(with: try event(.rightMouseDown, at: NSPoint(x: 30, y: 560)))
        drag.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 330, y: 560)))
        drag.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 30, y: 560), windowNumber: -1))
        window.isMovable = false
        drag.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 30, y: 560)))
        try check(drag.dragCount == 1, "non-left, outside, foreign and disabled events do not drag")
    }

    private static func checkPresentation(legacy: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardDeck-window-test-" + UUID().uuidString)
        let suite = "ClipboardDeck-window-test-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.failed("isolated window settings") }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(directory: directory, isPreview: true, defaults: defaults)
        let content = PanelContent.makeView(model: model, legacy: legacy)
        content.frame = NSRect(x: 0, y: 0, width: 416, height: 608)
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        content.layoutSubtreeIfNeeded()
        let allViews = descendants(of: content)
        let surfaces = allViews.compactMap { $0 as? WindowDragView }
        let name = legacy ? "legacy" : "modern"
        try check(surfaces.count == 1, "\(name) panel includes exactly one title drag region")
        guard let drag = surfaces.first else { return }
        try check(drag.bounds.width >= 100 && drag.bounds.height >= 30, "\(name) title drag region has usable bounds")
        for x in [CGFloat(4), drag.bounds.midX, drag.bounds.maxX - 4] {
            let point = drag.convert(NSPoint(x: x, y: drag.bounds.midY), to: content.superview)
            try check(content.hitTest(point) === drag, "\(name) title and blank space reach native drag view")
        }
        let dragFrame = drag.convert(drag.bounds, to: content)
        let buttonPoint = NSPoint(x: content.bounds.maxX - 30, y: dragFrame.midY)
        let searchPoint = NSPoint(x: content.bounds.midX, y: content.isFlipped ? 100 : 508)
        let historyPoint = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        for point in [buttonPoint, searchPoint, historyPoint] {
            let hit = content.hitTest(content.convert(point, to: content.superview))
            try check(hit != nil && hit !== drag, "\(name) controls and history are outside the drag hit region")
        }
        for control in allViews where control is NSButton || control is NSSearchField || control is NSTableView {
            let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: drag)
            try check(!drag.bounds.contains(point), "\(name) native controls do not overlap the title drag region")
        }
        window.contentView = nil
    }

    private static func checkPlacement() throws {
        let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let right = NSRect(x: 1440, y: 200, width: 1920, height: 1080)
        let size = NSSize(width: 416, height: 608)
        var placement = PanelPlacement()
        guard
            let initial = placement.frameForPresentation(size: size, visibleScreens: [main, left], initialScreen: left)
        else { throw Failure.failed("initial display placement") }
        try check(left.contains(initial), "first presentation follows the pointer's display")
        let manual = NSRect(origin: NSPoint(x: 2000, y: 400), size: size)
        placement.rememberMove(to: manual)
        try check(
            placement.frameForPresentation(size: size, visibleScreens: [main, right], initialScreen: main) == manual,
            "reopening preserves a manual position even after the pointer changes displays")
        let recovered = placement.frameForPresentation(size: size, visibleScreens: [main], initialScreen: main)
        try check(
            recovered.map { main.contains($0) && $0.size == size } == true,
            "disconnected display recovers without resizing")
        let negative = NSRect(origin: NSPoint(x: -1600, y: 200), size: size)
        try check(
            PanelPlacement.constrained(negative, to: [main, left]) == negative,
            "negative monitor coordinates are preserved")
        let small = NSRect(x: 100, y: 100, width: 360, height: 440)
        let tall = PanelPlacement.constrained(manual, to: [small])
        try check(
            tall.maxY == small.maxY - 12 && tall.minX == small.minX + 12, "small display keeps the title reachable")
        try check(
            PanelPlacement.constrained(manual, to: []) == manual, "temporary absence of displays preserves coordinates")
        try check(
            PanelPlacement().frameForPresentation(size: size, visibleScreens: [], initialScreen: nil) == nil,
            "first presentation tolerates absent display information")
        for index in 0..<1_000 {
            let candidate = NSRect(
                origin: NSPoint(x: CGFloat((index * 397) % 8000 - 4000), y: CGFloat((index * 197) % 5000 - 2000)),
                size: size)
            let constrained = PanelPlacement.constrained(candidate, to: [main, left, right])
            try check(
                [main, left, right].contains { $0.contains(constrained) }, "panel remains on one display at \(index)")
            try check(constrained.size == size, "position repair preserves panel dimensions at \(index)")
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func check(_ passed: Bool, _ message: String) throws {
        if !passed { throw Failure.failed(message) }
    }

    private enum Failure: Error { case failed(String) }

    private final class DragProbe: WindowDragView {
        var dragCount = 0
        override func drag(_ window: NSWindow, with event: NSEvent) { dragCount += 1 }
    }

    private final class FocusProbe: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}
