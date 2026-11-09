import AppKit
import ImageIO
import ClipboardCore
import CryptoKit

/// Exercises actual macOS pasteboard consumers without touching the user's
/// clipboard, opening an app window, or requesting automation permissions.
@MainActor
enum FormatSelfTests {
    private enum Failure: Error { case check(String) }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.check(message) }
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardDeck-formats-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = try HistoryStore(directory: root.appendingPathComponent("history"))
        try checkRichText(store: store, board: board)
        try checkRTFDAttachments(root: root, store: store, board: board)
        try checkImages(store: store, board: board)
        try checkLegacyLargeImage(root: root, board: board)
        try checkFiles(root: root, store: store, board: board)
        try checkRejections(board: board)
        try FormatRoundTripSelfTests.run()
        try FormatAttachmentSelfTests.run()
        try FormatRTFSelfTests.run()
        try OfficeFormatSelfTests.run()
        try FormatStressSelfTests.run()
        print(
            "PASS: formats / HTML and RTF byte preservation and restart / NSTextView font, color and paragraph alignment / RTFD inline PNG and background round-trip / invalid and oversized RTFD protection / rich-text priority / HTML-only / JPEG orientation / ordered local file URLs and missing-file protection / markers on every item / mixed-item rejection"
        )
    }

    private static func entry(_ payload: ClipPayload, store: HistoryStore) throws -> ClipEntry {
        let id = try store.add(payload, sourceApp: "Format self-test")
        guard let entry = store.entries.first(where: { $0.id == id }) else { throw Failure.check("saved entry") }
        return entry
    }

    private static func checkRichText(store: HistoryStore, board: NSPasteboard) throws {
        let text = "Hello 格式 🧪\n第二行"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.firstLineHeadIndent = 14
        paragraph.headIndent = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 19),
            .foregroundColor: NSColor(srgbRed: 0.8, green: 0.1, blue: 0.2, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        guard
            let rtf = attributed.rtf(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        else {
            throw Failure.check("RTF fixture")
        }
        let html = Data(
            "<p style=\"color:#cc1a33\"><b>Hello 格式 🧪</b><br>第二行<img src=\"https://example.invalid/no-request.png\"></p>"
                .utf8)
        board.clearContents()
        board.setData(rtf, forType: .rtf)
        board.setData(html, forType: .html)
        board.setString(text, forType: .string)
        board.setData(try PreviewSupport.png(PreviewSupport.sampleImage()), forType: .png)
        guard case .richText(let plain, let formats) = try ClipboardAccess.read(from: board) else {
            throw Failure.check("rich text wins over accompanying image")
        }
        try require(
            plain == text && formats["public.rtf"] == rtf && formats["public.html"] == html,
            "rich text capture preserves original bytes and fallback")
        let original = try entry(.richText(text: plain, formats: formats), store: store)
        let reopened = try HistoryStore(directory: store.directory)
        guard let restored = reopened.entries.first(where: { $0.id == original.id }) else {
            throw Failure.check("rich entry restart")
        }
        try require(tryWrite(restored, store: reopened, board: board), "rich pasteboard write")
        try require(
            board.data(forType: .rtf) == rtf && board.data(forType: .html) == html
                && board.string(forType: .string) == text,
            "rich paste representations after restart")

        // Ask an actual AppKit text control to consume the RTF representation.
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        view.isRichText = true
        try require(view.readSelection(from: board, type: .rtf), "NSTextView accepts restored RTF")
        try require(view.string == text, "NSTextView RTF Unicode contents")
        guard let restoredFont = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
            let restoredColor = (view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.sRGB)
        else {
            throw Failure.check("NSTextView RTF attributes")
        }
        try require(
            abs(restoredFont.pointSize - 19) < 0.01
                && NSFontManager.shared.traits(of: restoredFont).contains(.boldFontMask),
            "RTF font size and bold trait")
        try require(
            abs(restoredColor.redComponent - 0.8) < 0.015 && abs(restoredColor.greenComponent - 0.1) < 0.015,
            "RTF foreground color")
        guard
            let restoredParagraph = view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        else {
            throw Failure.check("NSTextView RTF paragraph")
        }
        try require(
            restoredParagraph.alignment == .center && abs(restoredParagraph.firstLineHeadIndent - 14) < 0.1
                && abs(restoredParagraph.headIndent - 8) < 0.1, "RTF paragraph alignment and indentation")

        let changed = try entry(
            .richText(text: text, formats: ["public.html": Data("<i>\(text)</i>".utf8)]), store: store)
        try require(
            changed.id != original.id && changed.digest != original.digest,
            "same text in different formats stays distinct")
        let unchanged = try entry(.richText(text: plain, formats: formats), store: store)
        try require(unchanged.id == original.id, "identical formats deduplicate")

        board.clearContents(); board.setData(rtf, forType: .rtf)
        guard case .richText(let extracted, let rtfOnly) = try ClipboardAccess.read(from: board) else {
            throw Failure.check("RTF-only capture")
        }
        try require(extracted == text && rtfOnly["public.rtf"] == rtf, "RTF-only safe text extraction")

        board.clearContents(); board.setData(html, forType: .html)
        guard case .richText(let emptyText, let htmlOnly) = try ClipboardAccess.read(from: board) else {
            throw Failure.check("HTML-only capture")
        }
        try require(emptyText.isEmpty && htmlOnly["public.html"] == html, "HTML-only no invented plain text")
        let htmlEntry = try entry(.richText(text: emptyText, formats: htmlOnly), store: store)
        let htmlReopened = try HistoryStore(directory: store.directory)
        guard let htmlRestored = htmlReopened.entries.first(where: { $0.id == htmlEntry.id }) else {
            throw Failure.check("HTML-only restart")
        }
        try require(tryWrite(htmlRestored, store: htmlReopened, board: board), "HTML-only write")
        try require(
            board.data(forType: .html) == html && !(board.types ?? []).contains(.string),
            "HTML-only writes exact HTML with no invented fallback")

        board.clearContents(); board.setData(Data("not RTF".utf8), forType: .rtf)
        board.setString("safe fallback", forType: .string)
        guard case .text("safe fallback") = try ClipboardAccess.read(from: board) else {
            throw Failure.check("invalid RTF uses available plain fallback")
        }

        guard let richName = htmlEntry.richTextFilename else { throw Failure.check("rich sidecar fixture") }
        let sidecar = store.directory.appendingPathComponent("richtext").appendingPathComponent(richName)
        try Data("damaged fixture".utf8).write(to: sidecar)
        board.clearContents(); board.setString("preserve before invalid rich text", forType: .string)
        let before = board.changeCount
        do {
            _ = try ClipboardAccess.write(htmlEntry, store: store, to: board)
            throw Failure.check("damaged rich sidecar must reject write")
        } catch HistoryError.invalidFormats {}
        try require(
            board.changeCount == before && board.string(forType: .string) == "preserve before invalid rich text",
            "damaged rich sidecar preserves clipboard before any clear")
    }

    // Keep throwing operations out of the assertion autoclosure.
    private static func tryWrite(_ entry: ClipEntry, store: HistoryStore, board: NSPasteboard) -> Bool {
        (try? ClipboardAccess.write(entry, store: store, to: board)) == true
    }

    private static func background<Value: Sendable>(bytes: Int, _ work: @escaping @Sendable () throws -> Value) throws
        -> Value
    {
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        var result: Result<Value, Error>?
        guard scheduler.submit(byteCount: bytes, work: work, completion: { result = $0 }) != nil,
            SelfTestWait.until(timeout: 5, { result != nil }), let result
        else {
            throw Failure.check("background format operation completes")
        }
        return try result.get()
    }

    private static func checkRTFDAttachments(root: URL, store: HistoryStore, board: NSPasteboard) throws {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData
        else {
            throw Failure.check("RTFD image fixture")
        }
        for y in 0..<8 {
            for x in 0..<8 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = UInt8(x * 30)
                pixels[offset + 1] = UInt8(y * 30)
                pixels[offset + 2] = 120
                pixels[offset + 3] = 255
            }
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.check("RTFD PNG encoding")
        }
        let imageFile = FileWrapper(regularFileWithContents: png)
        imageFile.preferredFilename = "clipboard-test.png"
        let attachment = NSTextAttachment(fileWrapper: imageFile)
        let attributed = NSMutableAttributedString(
            string: "办公图文\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        attributed.append(NSAttributedString(attachment: attachment))
        attributed.append(NSAttributedString(string: "\n附件后的文字"))
        guard
            let rtfd = attributed.rtfd(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        else {
            throw Failure.check("native RTFD fixture")
        }
        board.clearContents(); board.setData(rtfd, forType: .rtfd)
        guard let snapshot = try ClipboardAccess.snapshot(from: board) else { throw Failure.check("RTFD snapshot") }
        // The queued value must not consult a later owner of the pasteboard.
        board.clearContents(); board.setString("later clipboard owner", forType: .string)
        guard
            case .richText(let text, let formats) = try background(
                bytes: snapshot.byteCount,
                {
                    try ClipboardAccess.process(snapshot)
                })
        else { throw Failure.check("RTFD background capture") }
        try require(
            text.contains("办公图文") && text.contains("附件后的文字") && formats[HistoryStore.rtfdType] == rtfd,
            "RTFD-only extraction preserves text and original attachment bytes")
        let saved = try entry(.richText(text: text, formats: formats), store: store)
        let reopened = try HistoryStore(directory: store.directory)
        guard let restored = reopened.entries.first(where: { $0.id == saved.id }) else {
            throw Failure.check("RTFD restart")
        }
        let directory = reopened.directory
        let prepared = try background(bytes: restored.byteCount) {
            try ClipboardAccess.prepareWrite(restored, directory: directory)
        }
        try require(
            prepared.byteCount <= ClipboardAccess.maxPreparedWriteBytes, "RTFD prepared output has a bounded size")
        let wrote = try ClipboardAccess.commit(prepared, to: board)
        try require(
            wrote && board.data(forType: .rtfd) == rtfd, "RTFD bytes survive background preparation and restart")

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        view.isRichText = true
        view.importsGraphics = true
        try require(view.readSelection(from: board, type: .rtfd), "NSTextView consumes restored RTFD")
        try require(view.string == attributed.string, "RTFD text and attachment placeholder reach the text editor")
        var attachmentBytes: [Data] = []
        view.textStorage?.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)
        ) { value, _, _ in
            if let value = value as? NSTextAttachment, let bytes = value.fileWrapper?.regularFileContents {
                attachmentBytes.append(bytes)
            }
        }
        try require(attachmentBytes == [png], "NSTextView receives exactly one unchanged inline PNG attachment")

        guard let document = FileWrapper(serializedRepresentation: rtfd),
            let rtf = document.fileWrappers?.first(where: { $0.key.lowercased() == "txt.rtf" })?.value
                .regularFileContents
        else {
            throw Failure.check("native RTFD package contents")
        }
        let badAttachment = FileWrapper(directoryWithFileWrappers: [
            "TXT.rtf": FileWrapper(regularFileWithContents: rtf),
            "unsupported.bin": FileWrapper(regularFileWithContents: Data([1, 2, 3])),
        ])
        let linkedAttachment = FileWrapper(directoryWithFileWrappers: [
            "TXT.rtf": FileWrapper(regularFileWithContents: rtf),
            "linked.png": FileWrapper(symbolicLinkWithDestinationURL: root.appendingPathComponent("never-read.png")),
        ])
        guard let unknownData = badAttachment.serializedRepresentation,
            let linkedData = linkedAttachment.serializedRepresentation
        else { throw Failure.check("invalid RTFD fixtures") }
        for invalid in [Data("not an RTFD package".utf8), unknownData, linkedData] {
            board.clearContents(); board.setData(invalid, forType: .rtfd)
            board.setString("safe RTFD fallback", forType: .string)
            let before = board.changeCount
            guard case .text("safe RTFD fallback") = try ClipboardAccess.read(from: board) else {
                throw Failure.check("invalid or unsupported RTFD falls back to text")
            }
            try require(board.changeCount == before, "rejecting an RTFD representation never mutates its source")
        }
        let oversizedRTFD = Data(repeating: 0, count: HistoryStore.maxRichTextBytes + 1)
        board.clearContents(); board.setData(oversizedRTFD, forType: .rtfd)
        let before = board.changeCount
        do {
            _ = try ClipboardAccess.read(from: board)
            throw Failure.check("oversized RTFD without a usable fallback must be rejected")
        } catch HistoryError.tooLarge {}
        try require(board.changeCount == before, "oversized RTFD rejection preserves the clipboard")

        board.setString("oversized attachment fallback", forType: .string)
        guard case .text("oversized attachment fallback") = try ClipboardAccess.read(from: board) else {
            throw Failure.check("oversized RTFD preserves usable plain text")
        }
        let html = Data("<p><b>usable office format</b></p>".utf8)
        let plainRTF = Data(#"{\rtf1 usable office format}"#.utf8)
        board.clearContents(); board.setData(oversizedRTFD, forType: .rtfd)
        board.setData(plainRTF, forType: .rtf); board.setData(html, forType: .html)
        guard case .richText(let fallbackText, let fallbackFormats) = try ClipboardAccess.read(from: board) else {
            throw Failure.check("oversized RTFD retains other supported rich formats")
        }
        try require(
            fallbackText == "usable office format" && fallbackFormats[HistoryStore.rtfdType] == nil
                && fallbackFormats[NSPasteboard.PasteboardType.rtf.rawValue] == plainRTF
                && fallbackFormats[NSPasteboard.PasteboardType.html.rawValue] == html,
            "one oversized representation cannot discard a valid RTF and HTML selection")

        let provider = LazyPreviewProvider()
        let lazy = NSPasteboardItem()
        lazy.setData(plainRTF, forType: .rtf)
        lazy.setString("usable office format", forType: .string)
        try require(lazy.setDataProvider(provider, forTypes: [.png, .tiff]), "lazy office preview fixture")
        board.clearContents(); try require(board.writeObjects([lazy]), "write lazy office preview fixture")
        guard case .richText = try ClipboardAccess.read(from: board) else {
            throw Failure.check("lazy rich-text capture")
        }
        try require(
            provider.requestCount == 0, "capturing office rich text never requests redundant PNG or TIFF previews")
    }

    private static func checkLegacyLargeImage(root: URL, board: NSPasteboard) throws {
        // A real, compact PNG from the older 40 MP policy. This uses a single
        // temporary pixel buffer, then releases it before preparing the paste.
        let width = 4_250, height = 4_000
        let png = try autoreleasepool { () throws -> Data in
            guard
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData
            else {
                throw Failure.check("legacy large PNG bitmap")
            }
            pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw Failure.check("legacy large PNG encoding")
            }
            return data
        }
        var hash = SHA256()
        hash.update(data: Data("image".utf8)); hash.update(data: png)
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent("legacy-large-image")
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let sidecar = images.appendingPathComponent(digest + ".png")
        try png.write(to: sidecar)
        let metadata: [String: Any] = [
            "id": UUID().uuidString, "digest": digest, "kind": "image",
            "imageFilename": digest + ".png", "imageWidth": width, "imageHeight": height,
            "byteCount": png.count, "createdAt": 0.0, "copiedAt": 0.0,
            "sourceApp": "Legacy image fixture", "isPinned": false, "copyCount": 1,
        ]
        try JSONSerialization.data(withJSONObject: ["version": 2, "entries": [metadata]])
            .write(to: directory.appendingPathComponent("history.json"))
        let old = try HistoryStore(directory: directory)
        guard let saved = old.entries.first else { throw Failure.check("legacy 17 MP image loads") }
        let prepared = try background(bytes: saved.byteCount) {
            try ClipboardAccess.prepareWrite(saved, directory: directory)
        }
        let wrote = try ClipboardAccess.commit(prepared, to: board)
        // The system can advertise synthesized TIFF even when we supply PNG
        // only. Inspect our prepared byte budget, not the system's type aliases.
        try require(
            wrote && board.data(forType: .png) == png && prepared.byteCount == png.count,
            "legacy 17 MP PNG remains pasteable without a large TIFF allocation")

        var changed = png
        changed[changed.count / 2] ^= 1
        try changed.write(to: sidecar)
        board.clearContents(); board.setString("preserve clipboard on image corruption", forType: .string)
        let before = board.changeCount
        do {
            _ = try ClipboardAccess.write(saved, store: old, to: board)
            throw Failure.check("a legacy PNG with a mismatched content digest must not be pasted")
        } catch HistoryError.invalidImage {}
        try require(
            board.changeCount == before && board.string(forType: .string) == "preserve clipboard on image corruption",
            "image digest failure is detected before clearing the clipboard")
    }

    private static func checkImages(store: HistoryStore, board: NSPasteboard) throws {
        guard let tiff = PreviewSupport.sampleImage().tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
            let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.check("JPEG fixture") }
        let oriented = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(oriented, "public.jpeg" as CFString, 1, nil) else {
            throw Failure.check("oriented JPEG destination")
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "oriented JPEG fixture")
        board.clearContents(); board.setData(oriented as Data, forType: NSPasteboard.PasteboardType("public.jpeg"))
        guard let jpegSnapshot = try ClipboardAccess.snapshot(from: board) else { throw Failure.check("JPEG snapshot") }
        try require(
            jpegSnapshot.byteCount == oriented.length,
            "JPEG capture retains the source representation without asking the system to synthesize TIFF")
        guard case .image(let png, let width, let height) = try ClipboardAccess.read(from: board) else {
            throw Failure.check("JPEG capture")
        }
        try require(
            width == 400 && height == 800 && png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
            "JPEG is normalized to upright PNG")
        let imageEntry = try entry(.image(png: png, width: width, height: height), store: store)
        try require(tryWrite(imageEntry, store: store, board: board), "normalized JPEG write")
        try require(
            board.data(forType: .png) == png && board.data(forType: .tiff) != nil, "normalized image uses PNG and TIFF")
        board.clearContents(); board.setData(Data(png.prefix(43)), forType: .png)
        board.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
        guard case .image(_, let fallbackWidth, let fallbackHeight) = try ClipboardAccess.read(from: board) else {
            throw Failure.check("valid alternative image representation")
        }
        try require(fallbackWidth == 800 && fallbackHeight == 400, "bad PNG can use valid JPEG representation")
    }

    private static func checkFiles(root: URL, store: HistoryStore, board: NSPasteboard) throws {
        let urls = [root.appendingPathComponent("文件 一.txt"), root.appendingPathComponent("second.png")]
        for (index, url) in urls.enumerated() { try Data("temporary fixture \(index)".utf8).write(to: url) }
        for selection in [[urls[0]], urls] {
            let items = selection.map { url -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                item.setString(url.lastPathComponent, forType: .string)
                return item
            }
            board.clearContents(); try require(board.writeObjects(items), "file source fixture")
            guard case .files(let captured) = try ClipboardAccess.read(from: board) else {
                throw Failure.check("file capture")
            }
            try require(captured == selection, "file capture retains order and exact URLs")
            let saved = try entry(.files(captured), store: store)
            let reopened = try HistoryStore(directory: store.directory)
            guard let restored = reopened.entries.first(where: { $0.id == saved.id }) else {
                throw Failure.check("file restart")
            }
            try require(tryWrite(restored, store: reopened, board: board), "file restore")
            let native = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            try require(native == selection, "system NSURL reader accepts single/multiple ordered file URLs")
            try require(
                board.pasteboardItems?.allSatisfy {
                    $0.types.contains(NSPasteboard.PasteboardType(ClipboardPolicy.ownType))
                } == true,
                "every file item has own-write marker")
            let ignored = try ClipboardAccess.read(from: board)
            try require(ignored == nil, "multi-file own-write suppression")
        }
        let selected = try entry(.files(urls), store: store)
        try FileManager.default.removeItem(at: urls[1])
        board.clearContents(); board.setString("keep current clipboard", forType: .string)
        let before = board.changeCount
        do {
            _ = try ClipboardAccess.write(selected, store: store, to: board)
            throw Failure.check("missing file must reject entire selection")
        } catch ClipboardAccess.FormatError.missingFile {}
        try require(
            board.changeCount == before && board.string(forType: .string) == "keep current clipboard",
            "missing file preflight preserves current clipboard")

        board.clearContents()
        board.setPropertyList([urls[0].path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        guard case .files(let legacy) = try ClipboardAccess.read(from: board) else {
            throw Failure.check("legacy file path capture")
        }
        try require(legacy == [urls[0]], "legacy Finder file paths")

        let vanishingFile = root.appendingPathComponent("removed-after-preparation.txt")
        try Data("temporary fixture".utf8).write(to: vanishingFile)
        let vanishing = try entry(.files([vanishingFile]), store: store)
        let directory = store.directory
        let prepared = try background(bytes: vanishing.byteCount) {
            try ClipboardAccess.prepareWrite(vanishing, directory: directory)
        }
        try FileManager.default.removeItem(at: vanishingFile)
        board.clearContents(); board.setString("keep clipboard after preparation", forType: .string)
        let beforeCommit = board.changeCount
        do {
            _ = try ClipboardAccess.commit(prepared, to: board)
            throw Failure.check("a file removed after preparation must reject commit")
        } catch ClipboardAccess.FormatError.missingFile {}
        try require(
            board.changeCount == beforeCommit && board.string(forType: .string) == "keep clipboard after preparation",
            "commit rechecks file references before clearing the clipboard")
    }

    private static func checkRejections(board: NSPasteboard) throws {
        for marker in ["org.nspasteboard.ConcealedType", ClipboardPolicy.ownType] {
            let first = NSPasteboardItem(); first.setString("not captured", forType: .string)
            let second = NSPasteboardItem(); second.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
            board.clearContents(); try require(board.writeObjects([first, second]), "later-item marker fixture")
            let payload = try ClipboardAccess.read(from: board)
            try require(payload == nil, "sensitive or own marker on later item blocks capture")
        }
        let htmlItem = NSPasteboardItem(); htmlItem.setData(Data("<b>one</b>".utf8), forType: .html)
        let textItem = NSPasteboardItem(); textItem.setString("different item", forType: .string)
        board.clearContents(); try require(board.writeObjects([htmlItem, textItem]), "mixed source fixture")
        let before = board.changeCount
        do {
            _ = try ClipboardAccess.read(from: board)
            throw Failure.check("mixed representations must not be combined")
        } catch ClipboardAccess.FormatError.unsupportedMultipleItems {}
        try require(board.changeCount == before, "rejected capture does not mutate clipboard")
        board.clearContents(); board.setString("https://example.invalid/file.txt", forType: .fileURL)
        do {
            _ = try ClipboardAccess.read(from: board)
            throw Failure.check("remote URL is not a local file")
        } catch ClipboardAccess.FormatError.invalidFiles {}
        board.clearContents();
        board.setData(Data([0, 1, 2, 3]), forType: NSPasteboard.PasteboardType("app.unknown.type"))
        let unknown = try ClipboardAccess.read(from: board)
        try require(unknown == nil, "unknown formats are ignored")
    }
}

private final class LazyPreviewProvider: NSObject, NSPasteboardItemDataProvider {
    private let lock = NSLock()
    private var requests = 0
    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.lock(); requests += 1; lock.unlock()
        item.setData(Data([0]), forType: type)
    }
}
