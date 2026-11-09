import AppKit
import SwiftUI
import ClipboardCore

@MainActor
enum PreviewSupport {
    static func sampleImage() -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let rect = NSRect(x: 0, y: 0, width: 800, height: 400)
        NSGradient(
            starting: NSColor(red: 0.75, green: 0.87, blue: 0.87, alpha: 1),
            ending: NSColor(red: 0.93, green: 0.95, blue: 0.88, alpha: 1))?.draw(in: rect, angle: 90)
        NSColor(red: 0.98, green: 0.87, blue: 0.58, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 580, y: 240, width: 72, height: 72)).fill()
        let back = NSBezierPath()
        back.move(to: NSPoint(x: 0, y: 50)); back.line(to: NSPoint(x: 230, y: 310))
        back.line(to: NSPoint(x: 460, y: 80)); back.line(to: NSPoint(x: 610, y: 220))
        back.line(to: NSPoint(x: 800, y: 10)); back.line(to: NSPoint(x: 800, y: 0))
        back.line(to: .zero); back.close()
        NSColor(red: 0.36, green: 0.60, blue: 0.58, alpha: 1).setFill(); back.fill()
        let front = NSBezierPath()
        front.move(to: .zero); front.line(to: NSPoint(x: 160, y: 100))
        front.line(to: NSPoint(x: 330, y: 30)); front.line(to: NSPoint(x: 520, y: 150))
        front.line(to: NSPoint(x: 800, y: 25)); front.line(to: NSPoint(x: 800, y: 0)); front.close()
        NSColor(red: 0.17, green: 0.39, blue: 0.36, alpha: 1).setFill(); front.fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 800, height: 400))
        image.addRepresentation(bitmap)
        return image
    }

    static func png(_ image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else { throw HistoryError.invalidImage }
        return data
    }

    static func populate(_ model: AppModel) throws {
        guard let store = model.store else { throw HistoryError.damagedHistory }
        let now = Date()
        let pinned = try store.add(
            .text("把灵感留下，把重复的操作交给工具。"), sourceApp: "备忘录 · 示例",
            at: now.addingTimeInterval(-3600))
        try store.togglePin(pinned)
        try store.add(.text("git status\ngit diff --stat"), sourceApp: "终端 · 示例", at: now.addingTimeInterval(-80))
        try store.add(
            .image(png: png(sampleImage()), width: 800, height: 400), sourceApp: "预览 · 示例",
            at: now.addingTimeInterval(-45))
        let sampleFile = store.directory.appendingPathComponent("项目说明.txt")
        try Data("剪贴匣临时演示文件".utf8).write(to: sampleFile)
        try store.add(.files([sampleFile]), sourceApp: "Finder · 示例", at: now.addingTimeInterval(-20))
        let richText = "让每一次复制，都能轻松找回来。\n文字与格式，一起保存。"
        try store.add(
            .richText(
                text: richText, formats: ["public.html": Data("<p><b>让每一次复制，都能轻松找回来。</b><br>文字与格式，一起保存。</p>".utf8)]),
            sourceApp: "Safari · 示例", at: now.addingTimeInterval(-10))
        model.refresh()
        model.accessibilityGranted = true
        model.selectedID = model.visibleEntries.first(where: { !$0.isPinned })?.id
    }

    static func render(to destination: URL, hotkeyWarning: Bool = false, legacy: Bool = false) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardDeck-preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let board = hotkeyWarning ? NSPasteboard.withUniqueName() : nil
        defer { board?.releaseGlobally() }
        let suite = "ClipboardDeck-preview-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw TestError.failed("preview settings") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(directory: temporary, isPreview: !hotkeyWarning, pasteboard: board, defaults: defaults)
        try populate(model)
        if hotkeyWarning {
            model.onHotkeyChange = { _ in .success(()) }
            model.activateHotkey()
            model.onHotkeyChange = { _ in .failure(.occupied) }
            model.setHotkey(1)
        }
        let view = PanelContent.makeView(model: model, legacy: legacy)
        let size = NSSize(width: 416, height: 608)
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw HistoryError.invalidImage }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw HistoryError.invalidImage }
        try data.write(to: destination, options: .atomic)
        window.orderOut(nil)
    }

    static func makeIcon(to destination: URL) throws {
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        let shape = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 190, yRadius: 190)
        NSGradient(
            starting: NSColor(red: 0.16, green: 0.61, blue: 0.55, alpha: 1),
            ending: NSColor(red: 0.08, green: 0.35, blue: 0.34, alpha: 1))?.draw(in: shape, angle: -90)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: 266, y: 241, width: 450, height: 540), xRadius: 52, yRadius: 52).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 310, y: 205, width: 450, height: 540), xRadius: 52, yRadius: 52).fill()
        NSColor(red: 0.10, green: 0.43, blue: 0.39, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 416, y: 699, width: 236, height: 95), xRadius: 35, yRadius: 35).fill()
        NSColor(red: 0.64, green: 0.79, blue: 0.76, alpha: 1).setFill()
        for y in [550, 445, 340] {
            NSBezierPath(
                roundedRect: NSRect(x: 390, y: y, width: y == 340 ? 190 : 290, height: 30), xRadius: 15, yRadius: 15
            ).fill()
        }
        image.unlockFocus()
        try png(image).write(to: destination, options: .atomic)
    }

    static func selfTest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardDeck-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: NSPasteboard.Name("ClipboardDeck-tests-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = try HistoryStore(directory: directory)
        board.clearContents(); board.setString("剪贴匣 test 🧪", forType: .string)
        guard case .text(let text) = try ClipboardAccess.read(from: board), text == "剪贴匣 test 🧪" else {
            throw TestError.failed("Unicode clipboard round trip")
        }
        let textID = try store.add(.text(text), sourceApp: "Test")
        guard let textEntry = store.entries.first(where: { $0.id == textID }),
            try ClipboardAccess.write(textEntry, store: store, to: board),
            board.string(forType: .string) == text,
            try ClipboardAccess.read(from: board) == nil
        else { throw TestError.failed("self-write suppression") }
        board.clearContents()
        board.setString("test secret", forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        guard try ClipboardAccess.read(from: board) == nil else { throw TestError.failed("concealed content") }
        let image = sampleImage()
        board.clearContents(); board.setData(image.tiffRepresentation!, forType: .tiff)
        guard case .image(let png, let width, let height) = try ClipboardAccess.read(from: board), width == 800,
            height == 400
        else {
            throw TestError.failed("TIFF to PNG")
        }
        let imageID = try store.add(.image(png: png, width: width, height: height), sourceApp: "Test")
        guard let entry = store.entries.first(where: { $0.id == imageID }),
            try ClipboardAccess.write(entry, store: store, to: board),
            board.data(forType: .png) == png, board.data(forType: .tiff) != nil
        else { throw TestError.failed("image paste types") }
        board.clearContents()
        board.setData(png, forType: .png)
        guard case .image(let restoredPNG, let w, let h) = try ClipboardAccess.read(from: board),
            restoredPNG == png, w == width, h == height
        else { throw TestError.failed("PNG capture") }
        board.clearContents()
        // The header still advertises valid dimensions, but the image is incomplete.
        board.setData(Data(png.prefix(43)), forType: .png)
        do {
            _ = try ClipboardAccess.read(from: board)
            throw TestError.failed("truncated PNG must be rejected")
        } catch HistoryError.invalidImage {}
        print(
            "PASS: private pasteboard text / Unicode / own-write suppression / concealed type / TIFF conversion / PNG output and corruption rejection"
        )
        try AppModelSelfTests.run(directory: directory.appendingPathComponent("model"), board: board)
        try HotkeySelfTests.run()
        try ThumbnailCacheSelfTests.run()
        try FormatSelfTests.run()
        try PollingSelfTests.run()
        try ThumbnailPipelineSelfTests.run()
        try ClipboardWorkSchedulerSelfTests.run()
        try LegacyHistoryView.selfTest()
    }

    enum TestError: Error { case failed(String) }
}
