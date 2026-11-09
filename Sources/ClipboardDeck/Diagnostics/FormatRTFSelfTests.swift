import AppKit
import ImageIO
import ClipboardCore

/// Focused regression checks for the text-only RTF parser. All input is generated
/// here; no user clipboard, documents, or application history are accessed.
@MainActor
enum FormatRTFSelfTests {
    private enum Failure: Error { case check(String) }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.check(message) }
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardDeck-rtf-parser-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = try HistoryStore(directory: root)

        let escaped = Data(
            #"{\rtf1\ansi\ansicpg1252\uc1 Before \{braces\} \\slash caf\'e9 \u20013?\u25991? \uc2\u20013??\u25991??\uc1  after\par Second\tab cell}"#
                .utf8)
        let escapedText = "Before {braces} \\slash café 中文 中文 after\nSecond\tcell"
        try roundTrip(
            escaped, expectedText: escapedText, label: "escaped text and Unicode fallback",
            consumeInTextView: true, store: store, board: board)

        let png = try makePNGWithRTFSyntaxBytes()
        let hex = png.map { String(format: "%02x", $0) }.joined()
        let hexadecimalPicture = Data(
            (#"{\rtf1\ansi Before {\pict\pngblip\picw2\pich2\picwgoal30\pichgoal30 "# + hex + #"} {\b After}}"#).utf8)
        try roundTrip(
            hexadecimalPicture, expectedText: "Before  After", label: "hexadecimal picture destination",
            consumeInTextView: false, store: store, board: board)

        // The PNG includes literal braces and backslashes in a valid ancillary
        // chunk. They are binary payload, never RTF group/control delimiters.
        var binaryPicture = Data((#"{\rtf1\ansi Before {\pict\pngblip\picw2\pich2\bin"# + String(png.count) + " ").utf8)
        binaryPicture.append(png)
        binaryPicture.append(Data(#"} {\b After}}"#.utf8))
        try roundTrip(
            binaryPicture, expectedText: "Before  After", label: "binary picture destination",
            consumeInTextView: false, store: store, board: board)

        for invalid in [
            #"{\rtf1 Before {\pict\pngblip\bin999999 {}} After}"#,
            #"{\rtf1 Before {\pict\pngblip\bin-1 x} After}"#,
        ] {
            board.clearContents()
            try require(board.setData(Data(invalid.utf8), forType: .rtf), "malformed binary RTF fixture")
            try require(board.setString("safe fallback", forType: .string), "binary RTF plain fallback fixture")
            let before = board.changeCount
            guard case .text("safe fallback") = try ClipboardAccess.read(from: board) else {
                throw Failure.check("invalid binary length falls back to plain text")
            }
            try require(board.changeCount == before, "invalid binary RTF capture leaves clipboard unchanged")
        }
        print(
            "PASS: RTF escaped braces and backslash / ANSI and Unicode fallback / native text consumer / hexadecimal and binary PNG destinations / exact bytes after restart / invalid binary length fallback"
        )
    }

    private static func roundTrip(
        _ rtf: Data, expectedText: String, label: String,
        consumeInTextView: Bool, store: HistoryStore, board: NSPasteboard
    ) throws {
        board.clearContents()
        try require(board.setData(rtf, forType: .rtf), "\(label): source fixture")
        let before = board.changeCount
        guard case .richText(let text, let formats) = try ClipboardAccess.read(from: board) else {
            throw Failure.check("\(label): capture")
        }
        try require(
            text == expectedText && formats[NSPasteboard.PasteboardType.rtf.rawValue] == rtf,
            "\(label): body text is extracted while original RTF remains intact")
        try require(board.changeCount == before, "\(label): capture never changes its source")

        let id = try store.add(.richText(text: text, formats: formats), sourceApp: "RTF parser self-test")
        let reopened = try HistoryStore(directory: store.directory)
        guard let entry = reopened.entries.first(where: { $0.id == id }) else {
            throw Failure.check("\(label): restart")
        }
        let written = try ClipboardAccess.write(entry, store: reopened, to: board)
        try require(
            written && board.data(forType: .rtf) == rtf && board.data(forType: .string) == Data(expectedText.utf8),
            "\(label): original RTF and plain fallback survive restart and write")
        if consumeInTextView {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
            view.isRichText = true
            try require(
                view.readSelection(from: board, type: .rtf) && view.string == expectedText,
                "\(label): native RTF consumer receives the expected text")
        }
    }

    private static func makePNGWithRTFSyntaxBytes() throws -> Data {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData
        else {
            throw Failure.check("RTF PNG fixture bitmap")
        }
        pixels.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count >= 12,
            png.suffix(8) == Data([0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82])
        else {
            throw Failure.check("RTF PNG fixture encoding")
        }

        // A PNG tEXt chunk is keyword, NUL, then Latin-1 text. Insert just before
        // IEND, with its standard CRC, so the binary RTF contains real syntax bytes.
        let content = Data("Comment\0RTF syntax bytes: { } \\".utf8)
        var typeAndContent = Data("tEXt".utf8)
        typeAndContent.append(content)
        var chunk = Data()
        appendBigEndian(UInt32(content.count), to: &chunk)
        chunk.append(typeAndContent)
        appendBigEndian(crc32(typeAndContent), to: &chunk)
        var result = Data(png.dropLast(12))
        result.append(chunk)
        result.append(png.suffix(12))
        guard let source = CGImageSourceCreateWithData(result as CFData, nil),
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else {
            throw Failure.check("binary RTF fixture must contain a valid decodable PNG")
        }
        return result
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        return ~value
    }
}
