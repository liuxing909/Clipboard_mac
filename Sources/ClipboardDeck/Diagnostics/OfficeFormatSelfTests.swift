import AppKit
import ClipboardCore

/// Synthetic standard Office-style content, not captured from Microsoft Word.
/// Compare actual native consumers before/after the production background path.
@MainActor
enum OfficeFormatSelfTests {
    private enum Failure: Error { case check(String) }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardDeck-office-formats-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(directory: root)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try styles(store: store, board: board)
        try lists(store: store, board: board)
        try tables(store: store, board: board)
        print(
            "PASS: Office-style RTF/HTML / bold and italic / underline and strike / superscript and subscript / hyperlinks / paragraph spacing / ordered and bullet lists / merged table cells / background restart round-trip"
        )
    }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure.check(message) }
    }

    private static func range(_ token: String, in text: NSAttributedString) throws -> NSRange {
        let found = (text.string as NSString).range(of: token)
        guard found.location != NSNotFound else { throw Failure.check("missing fixture token: " + token) }
        return found
    }

    private static func styles(store: HistoryStore, board: NSPasteboard) throws {
        let font = NSFont(name: "Helvetica", size: 15)!
        let document = NSMutableAttributedString(
            string: "Bold Italic Underline Strike Super Sub Link\n中文 🧪 第二段\n", attributes: [.font: font])
        func add(_ token: String, _ key: NSAttributedString.Key, _ value: Any) throws {
            document.addAttribute(key, value: value, range: try range(token, in: document))
        }
        try add("Bold", .font, NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask))
        try add("Italic", .font, NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask))
        try add("Underline", .underlineStyle, NSUnderlineStyle.single.rawValue)
        try add("Strike", .strikethroughStyle, NSUnderlineStyle.single.rawValue)
        try add("Super", .superscript, 1)
        try add("Sub", .superscript, -1)
        try add("Link", .link, URL(string: "https://example.invalid/office-fixture")!)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.headIndent = 8; paragraph.firstLineHeadIndent = 16
        paragraph.paragraphSpacing = 12; paragraph.lineSpacing = 3
        document.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: document.length))
        let original = try encode(document)
        board.clearContents(); board.setData(original, forType: .rtf)
        let baseline = try consume(board, type: .rtf)
        try checkStyles(baseline)
        try roundTrip(store: store, board: board, formats: [.rtf: original], expectedText: baseline.string)
        let restored = try consume(board, type: .rtf)
        try require(restored.string == baseline.string, "RTF body after restart")
        try checkStyles(restored)
        print("OFFICE CASE: RTF styles and paragraph formatting accepted by NSTextView before and after restart")
    }

    private static func checkStyles(_ text: NSAttributedString) throws {
        func attribute(_ token: String, _ key: NSAttributedString.Key) throws -> Any? {
            text.attribute(key, at: try range(token, in: text).location, effectiveRange: nil)
        }
        for (token, trait) in [("Bold", NSFontTraitMask.boldFontMask), ("Italic", .italicFontMask)] {
            guard let font = try attribute(token, .font) as? NSFont else { throw Failure.check("RTF font") }
            try require(
                NSFontManager.shared.traits(of: font).contains(trait) && abs(font.pointSize - 15) < 0.01,
                token + " font and size")
        }
        for (token, key, expected) in [
            ("Underline", NSAttributedString.Key.underlineStyle, 1),
            ("Strike", .strikethroughStyle, 1), ("Super", .superscript, 1), ("Sub", .superscript, -1),
        ] {
            let actual = try attribute(token, key) as? NSNumber
            try require(actual?.intValue == expected, token + " attribute")
        }
        let link = try attribute("Link", .link)
        let url = (link as? URL)?.absoluteString ?? (link as? String)
        try require(url == "https://example.invalid/office-fixture", "hyperlink target (never opened)")
        guard let paragraph = try attribute("中文", .paragraphStyle) as? NSParagraphStyle else {
            throw Failure.check("paragraph attributes")
        }
        try require(
            paragraph.alignment == .right && abs(paragraph.headIndent - 8) < 0.1
                && abs(paragraph.firstLineHeadIndent - 16) < 0.1 && abs(paragraph.paragraphSpacing - 12) < 0.1
                && abs(paragraph.lineSpacing - 3) < 0.1, "paragraph alignment, indentation and spacing")
    }

    private static func lists(store: HistoryStore, board: NSPasteboard) throws {
        let document = NSMutableAttributedString(string: "")
        let ordered = NSTextList(markerFormat: .decimal, options: 0)
        let bullets = NSTextList(markerFormat: .disc, options: 0)
        for (index, token) in ["OrderedOne", "OrderedTwo", "BulletOne", "BulletTwo"].enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.textLists = [index < 2 ? ordered : bullets]
            paragraph.headIndent = 24; paragraph.firstLineHeadIndent = 0
            document.append(
                NSAttributedString(
                    string: token + "\n",
                    attributes: [.paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: 14)]))
        }
        let rtf = try encode(document)
        board.clearContents(); board.setData(rtf, forType: .rtf)
        let baseline = try consume(board, type: .rtf)
        let before = try listMarkers(baseline)
        try require(
            before.count == 4 && before[0] == before[1] && before[2] == before[3] && before[0] != before[2],
            "native RTF has distinct ordered and bullet list structures")
        try roundTrip(store: store, board: board, formats: [.rtf: rtf], expectedText: baseline.string)
        let after = try consume(board, type: .rtf)
        let markers = try listMarkers(after)
        try require(
            after.string == baseline.string && markers == before, "list body and marker structures survive restart")
        print("OFFICE CASE: ordered and bullet list paragraph structures survive native RTF consumption")
    }

    private static func listMarkers(_ text: NSAttributedString) throws -> [String] {
        try ["OrderedOne", "OrderedTwo", "BulletOne", "BulletTwo"].map { token in
            guard
                let paragraph = text.attribute(
                    .paragraphStyle, at: try range(token, in: text).location, effectiveRange: nil) as? NSParagraphStyle,
                let list = paragraph.textLists.first
            else { throw Failure.check("native list structure: " + token) }
            return list.markerFormat.rawValue
        }
    }

    private static func tables(store: HistoryStore, board: NSPasteboard) throws {
        let table = NSTextTable()
        table.numberOfColumns = 2; table.collapsesBorders = true
        let document = NSMutableAttributedString(string: "")
        let cells = [("MergedHeader", 0, 0, 2), ("00123", 1, 0, 1), ("12.50", 1, 1, 1)]
        for (token, row, column, span) in cells {
            let block = NSTextTableBlock(
                table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: span)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setBorderColor(.black)
            let paragraph = NSMutableParagraphStyle(); paragraph.textBlocks = [block]
            document.append(
                NSAttributedString(
                    string: token + "\n",
                    attributes: [.paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: 14)]))
        }
        let rtf = try encode(document)
        // Self-contained synthetic HTML, with no images, stylesheets or other fetched resources.
        let html = Data(
            "<html><head><meta charset=\"utf-8\"></head><body><table border=\"1\"><tr><td colspan=\"2\">MergedHeader</td></tr><tr><td>00123</td><td>12.50</td></tr></table></body></html>"
                .utf8)
        let plain = "MergedHeader\n00123\t12.50"
        let expected = [[0, 0, 1, 2, 2], [1, 0, 1, 1, 2], [1, 1, 1, 1, 2]]
        for type in [NSPasteboard.PasteboardType.rtf, .html] {
            let bytes = type == .rtf ? rtf : html
            board.clearContents(); board.setData(bytes, forType: type)
            let baseline = try consume(board, type: type)
            let before = try tableStructure(baseline)
            try require(before == expected, "native table fixture has the intended merged header and two numeric cells")
            // Office commonly offers several representations for one selection.
            // Keep the original RTF, HTML and supplied plain-text alternative together.
            try roundTrip(
                store: store, board: board, formats: [.rtf: rtf, .html: html, .string: Data(plain.utf8)],
                expectedText: plain)
            let after = try consume(board, type: type)
            let structure = try tableStructure(after)
            try require(
                after.string == baseline.string && structure == before,
                "merged table structure and numeric text survive " + type.rawValue)
            try require(board.string(forType: .string) == plain, "tab-separated plain table alternative is preserved")
            print("OFFICE CASE: \(type.rawValue) table preserves merged cells, row/column positions, 00123 and 12.50")
        }
    }

    private static func tableStructure(_ text: NSAttributedString) throws -> [[Int]] {
        try ["MergedHeader", "00123", "12.50"].map { token in
            guard
                let paragraph = text.attribute(
                    .paragraphStyle, at: try range(token, in: text).location, effectiveRange: nil) as? NSParagraphStyle,
                let cell = paragraph.textBlocks.first as? NSTextTableBlock
            else { throw Failure.check("native table structure: " + token) }
            return [cell.startingRow, cell.startingColumn, cell.rowSpan, cell.columnSpan, cell.table.numberOfColumns]
        }
    }

    private static func encode(_ document: NSAttributedString) throws -> Data {
        guard
            let bytes = document.rtf(
                from: NSRange(location: 0, length: document.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        else {
            throw Failure.check("encode native RTF fixture")
        }
        return bytes
    }

    private static func consume(_ board: NSPasteboard, type: NSPasteboard.PasteboardType) throws -> NSAttributedString {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        view.isRichText = true; view.importsGraphics = true
        guard view.readSelection(from: board, type: type), let text = view.textStorage else {
            throw Failure.check("native consumer: " + type.rawValue)
        }
        return NSAttributedString(attributedString: text)
    }

    private static func background<Value: Sendable>(bytes: Int, _ work: @escaping @Sendable () throws -> Value) throws
        -> Value
    {
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        var result: Result<Value, Error>?
        guard scheduler.submit(byteCount: bytes, work: work, completion: { result = $0 }) != nil,
            SelfTestWait.until(timeout: 10, { result != nil }), let result
        else { throw Failure.check("background office work") }
        return try result.get()
    }

    private static func roundTrip(
        store: HistoryStore, board: NSPasteboard, formats: [NSPasteboard.PasteboardType: Data], expectedText: String
    ) throws {
        let item = NSPasteboardItem()
        for (type, bytes) in formats { try require(item.setData(bytes, forType: type), "fixture representation") }
        board.clearContents(); try require(board.writeObjects([item]), "fixture pasteboard write")
        guard let snapshot = try ClipboardAccess.snapshot(from: board) else { throw Failure.check("office snapshot") }
        board.clearContents(); board.setString("later isolated clipboard", forType: .string)
        guard let payload = try background(bytes: snapshot.byteCount, { try ClipboardAccess.process(snapshot) }),
            case .richText(let summary, _) = payload
        else { throw Failure.check("Office content must not degrade to plain text") }
        try require(
            summary == expectedText,
            "history/search text retains the complete native body or supplied plain alternative")
        let id = try store.add(payload, sourceApp: "Synthetic Office-style test")
        let reopened = try HistoryStore(directory: store.directory)
        guard let restored = reopened.entries.first(where: { $0.id == id }) else {
            throw Failure.check("office restart")
        }
        try require(restored.text == expectedText, "history/search text survives restart")
        let directory = reopened.directory
        let prepared = try background(bytes: restored.byteCount) {
            try ClipboardAccess.prepareWrite(restored, directory: directory)
        }
        let committed = try ClipboardAccess.commit(prepared, to: board)
        try require(committed, "office restored write")
        for (type, bytes) in formats {
            try require(board.data(forType: type) == bytes, "exact original representation: " + type.rawValue)
        }
    }
}
