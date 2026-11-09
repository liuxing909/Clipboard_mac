import AppKit
import ImageIO
import ClipboardCore

/// Additional format contracts, exercised through the production background
/// capture/write path and a reopened history, using only an isolated pasteboard.
@MainActor
enum FormatRoundTripSelfTests {
    private enum Failure: Error { case check(String) }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardDeck-roundtrip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try checkText(root: root, board: board)
        try checkHTML(root: root, board: board)
        try checkImages(root: root, board: board)
        try checkFolders(root: root, board: board)
        print(
            "PASS: extended format round-trips / text whitespace and byte limits / UTF-8 and UTF-16 HTML / transparent PNG and TIFF pixels / JPEG restart / folder URLs and special filenames"
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.check(message) }
    }

    private static func background<Value: Sendable>(bytes: Int, _ work: @escaping @Sendable () throws -> Value) throws
        -> Value
    {
        let worker = ClipboardWorkScheduler(observesMemoryPressure: false)
        var result: Result<Value, Error>?
        guard worker.submit(byteCount: bytes, work: work, completion: { result = $0 }) != nil,
            SelfTestWait.until(timeout: 5, { result != nil }), let result
        else {
            throw Failure.check("background format task must finish")
        }
        return try result.get()
    }

    @discardableResult
    private static func roundTrip(root: URL, board: NSPasteboard) throws -> ClipEntry {
        guard let snapshot = try ClipboardAccess.snapshot(from: board) else { throw Failure.check("capture snapshot") }
        // The worker must consume its snapshot, not a newer clipboard owner.
        board.clearContents(); board.setString("later isolated clipboard", forType: .string)
        guard let payload = try background(bytes: snapshot.byteCount, { try ClipboardAccess.process(snapshot) }) else {
            throw Failure.check("process format snapshot")
        }
        let directory = root.appendingPathComponent(UUID().uuidString)
        let store = try HistoryStore(directory: directory)
        let id = try store.add(payload, sourceApp: "Format round-trip self-test")
        let reopened = try HistoryStore(directory: directory)
        guard let restored = reopened.entries.first(where: { $0.id == id }) else {
            throw Failure.check("reload saved format")
        }
        let prepared = try background(bytes: restored.byteCount) {
            try ClipboardAccess.prepareWrite(restored, directory: directory)
        }
        try require(prepared.byteCount <= ClipboardAccess.maxPreparedWriteBytes, "prepared format respects byte budget")
        let committed = try ClipboardAccess.commit(prepared, to: board)
        try require(committed, "commit restored format")
        return restored
    }

    private static func checkText(root: URL, board: NSPasteboard) throws {
        let text = "  中文 👨‍👩‍👧‍👦 e\u{301}\t列二\n第二行\n\n尾部  "
        board.clearContents(); board.setString(text, forType: .string)
        let restored = try roundTrip(root: root, board: board)
        try require(
            restored.kind == .text && board.string(forType: .string) == text,
            "Unicode, tabs, newlines and spaces survive restart")
        let view = NSTextView(frame: .zero)
        view.isRichText = false
        try require(
            view.readSelection(from: board, type: .string) && view.string == text,
            "native plain editor receives exact text")
        let lineEndings = "Windows\r\nMac\rUnix\n"
        board.clearContents(); board.setString(lineEndings, forType: .string)
        try roundTrip(root: root, board: board)
        try require(
            board.data(forType: .string) == Data(lineEndings.utf8),
            "CRLF, CR and LF remain unchanged in the restored clipboard")
        let limit = HistoryStore.maxTextBytes
        let atLimit = String(repeating: "中", count: limit / 3) + String(repeating: "a", count: limit % 3)
        board.clearContents(); board.setString(atLimit, forType: .string)
        try roundTrip(root: root, board: board)
        try require(board.data(forType: .string) == Data(atLimit.utf8), "exact 1 MiB UTF-8 text survives restart")
        board.clearContents(); board.setString(atLimit + "界", forType: .string)
        let before = board.changeCount
        do {
            _ = try ClipboardAccess.read(from: board)
            throw Failure.check("over-limit UTF-8 must reject")
        } catch HistoryError.tooLarge {}
        try require(board.changeCount == before, "text limit rejection preserves source clipboard")
        print("FORMAT CASE: text — Unicode/whitespace/native reader/restart/exact 1 MiB/over-limit rejection")
    }

    private static func checkHTML(root: URL, board: NSPasteboard) throws {
        let html = "<html><body><p><b>中文 🧪</b> &amp; <i>format</i></p></body></html>"
        let variants: [(String, Data)] = [
            ("UTF-8", Data(html.utf8)),
            ("UTF-16LE", Data([0xff, 0xfe]) + html.data(using: .utf16LittleEndian)!),
            ("UTF-16BE", Data([0xfe, 0xff]) + html.data(using: .utf16BigEndian)!),
        ]
        for (name, bytes) in variants {
            board.clearContents(); board.setData(bytes, forType: .html)
            let restored = try roundTrip(root: root, board: board)
            try require(
                restored.kind == .richText && board.data(forType: .html) == bytes,
                "\(name) HTML retains exact bytes after restart")
            try require(
                board.pasteboardItems?.first?.types.contains(.string) == false,
                "HTML-only does not invent a text representation")
        }
        for invalid in [Data([0xc3, 0x28]), Data("<b>bad\0html</b>".utf8)] {
            board.clearContents(); board.setData(invalid, forType: .html);
            board.setString("plain fallback", forType: .string)
            let restored = try roundTrip(root: root, board: board)
            try require(
                restored.kind == .text && board.string(forType: .string) == "plain fallback",
                "invalid HTML falls back to provided text")
        }
        print("FORMAT CASE: HTML — UTF-8/UTF-16LE/UTF-16BE/exact restart bytes/invalid encoding fallback")
    }

    private static func checkImages(root: URL, board: NSPasteboard) throws {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: 0, bitsPerPixel: 0),
            let bytes = bitmap.bitmapData
        else {
            throw Failure.check("transparent image fixture")
        }
        for y in 0..<8 {
            for x in 0..<12 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = UInt8(x * 20)
                bytes[offset + 1] = UInt8(y * 30)
                bytes[offset + 2] = 100
                bytes[offset + 3] = x < 4 ? 0 : (x < 8 ? 128 : 255)
            }
        }
        let variants: [(String, NSBitmapImageRep.FileType, NSPasteboard.PasteboardType)] = [
            ("PNG", .png, .png), ("TIFF", .tiff, .tiff), ("JPEG", .jpeg, NSPasteboard.PasteboardType("public.jpeg")),
        ]
        for (name, format, type) in variants {
            guard let input = bitmap.representation(using: format, properties: [:]) else {
                throw Failure.check("\(name) fixture encoding")
            }
            let expected = try pixels(input)
            if format != .jpeg {
                let alpha = stride(from: 3, to: expected.count, by: 4).map { expected[$0] }
                try require(
                    alpha.contains(0) && alpha.contains(128) && alpha.contains(255),
                    "\(name) fixture has three alpha levels before capture")
            }
            board.clearContents(); board.setData(input, forType: type)
            let restored = try roundTrip(root: root, board: board)
            guard let png = board.data(forType: .png), let tiff = board.data(forType: .tiff) else {
                throw Failure.check("\(name) PNG/TIFF output")
            }
            try require(
                restored.kind == .image && restored.imageWidth == 12 && restored.imageHeight == 8,
                "\(name) restored image dimensions")
            let pngPixels = try pixels(png), tiffPixels = try pixels(tiff)
            // JPEG is already lossy at the source: compare decoded source pixels,
            // not the pre-encoding fixture. Ignore RGB of fully transparent pixels.
            try samePixels(expected, pngPixels, name + " -> PNG")
            try samePixels(pngPixels, tiffPixels, name + " -> TIFF")
            if type == .png { try require(png == input, "PNG original bytes remain unchanged") }
            if type != NSPasteboard.PasteboardType("public.jpeg") {
                let alpha = stride(from: 3, to: pngPixels.count, by: 4).map { pngPixels[$0] }
                try require(
                    alpha.contains(0) && alpha.contains(255) && alpha.contains(where: { (120...136).contains($0) }),
                    "\(name) transparent, half-transparent and opaque pixels survive")
            }
        }
        print("FORMAT CASE: PNG/TIFF/JPEG — background capture/restart/PNG+TIFF consumers/pixel and alpha preservation")
    }

    private static func pixels(_ data: Data) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw Failure.check("decode test pixels") }
        var output = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = output.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try require(drawn, "render test pixels")
        return output
    }

    private static func samePixels(_ lhs: [UInt8], _ rhs: [UInt8], _ name: String) throws {
        try require(lhs.count == rhs.count, "\(name) pixel count")
        for offset in stride(from: 0, to: lhs.count, by: 4) {
            try require(abs(Int(lhs[offset + 3]) - Int(rhs[offset + 3])) <= 1, "\(name) alpha")
            if lhs[offset + 3] == 0 { continue }
            for channel in 0..<3 {
                try require(abs(Int(lhs[offset + channel]) - Int(rhs[offset + channel])) <= 2, "\(name) color pixels")
            }
        }
    }

    private static func checkFolders(root: URL, board: NSPasteboard) throws {
        let folder = root.appendingPathComponent("资料 #100% 🧪", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("文稿 #1% & ?.txt")
        let contents = Data("original file remains untouched".utf8)
        try contents.write(to: file)
        for selected in [[folder], [file, folder]] {
            board.clearContents()
            try require(board.writeObjects(selected.map { $0 as NSURL }), "native file/folder source")
            let restored = try roundTrip(root: root, board: board)
            let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            try require(
                restored.kind == .files
                    && urls?.map(\.standardizedFileURL.path) == selected.map(\.standardizedFileURL.path),
                "folder and percent-encoded file paths retain order through native reader")
        }
        let remaining = try Data(contentsOf: file)
        try require(remaining == contents, "file-reference paste leaves original contents unchanged")
        print("FORMAT CASE: files — folders/mixed file-folder order/Unicode and # % & ? paths/native URL reader")
    }
}
