import AppKit
import ClipboardCore

/// Real RTFD archives and AppKit consumers, isolated from the user's clipboard.
@MainActor
enum FormatAttachmentSelfTests {
    private enum Failure: Error { case check(String) }
    private struct Fixture {
        let archive: Data
        let text: String
        let attachments: [Data]
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardDeck-attachments-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = try HistoryStore(directory: root)

        let mixed = try fixture(count: 3)
        try roundTrip(mixed, store: store, board: board)
        print(
            "FORMAT CASE: RTFD mixed PNG/TIFF/JPEG attachments retain order, bytes and text after restart and NSTextView import"
        )

        let limit = try fixture(count: ClipboardAccess.maxRTFDAttachments)
        try roundTrip(limit, store: store, board: board)
        print("FORMAT CASE: RTFD 32 referenced attachments survive background capture, restart and native import")

        let excess = try fixture(count: ClipboardAccess.maxRTFDAttachments + 1)
        board.clearContents()
        try require(board.setData(excess.archive, forType: .rtfd), "write 33-attachment fixture")
        let before = board.changeCount
        let rejected = try ClipboardAccess.read(from: board)
        try require(rejected == nil, "33-attachment RTFD without fallback is rejected")
        try require(
            board.changeCount == before && board.data(forType: .rtfd) == excess.archive,
            "rejecting excessive attachments does not mutate the source clipboard")

        let fallback = "超额图文保留纯文字 🧪"
        try require(board.setString(fallback, forType: .string), "write excess attachment fallback")
        let beforeFallback = board.changeCount
        guard case .text(let text) = try ClipboardAccess.read(from: board) else {
            throw Failure.check("excess attachments use the available plain-text fallback")
        }
        try require(
            text == fallback && board.changeCount == beforeFallback,
            "fallback remains exact and capture does not mutate the clipboard")

        // A previously saved record must also be validated before any clipboard clear.
        let invalidID = try store.add(
            .richText(text: fallback, formats: [HistoryStore.rtfdType: excess.archive]),
            sourceApp: "Attachment self-test")
        guard let invalidEntry = store.entries.first(where: { $0.id == invalidID }) else {
            throw Failure.check("stored excessive-attachment fixture")
        }
        board.clearContents()
        try require(board.setString("keep current test clipboard", forType: .string), "write rejection sentinel")
        let beforeWrite = board.changeCount
        do {
            _ = try ClipboardAccess.write(invalidEntry, store: store, to: board)
            throw Failure.check("excessive stored attachments must not be pasted")
        } catch ClipboardAccess.FormatError.invalidRichText {}
        try require(
            board.changeCount == beforeWrite && board.string(forType: .string) == "keep current test clipboard",
            "invalid stored RTFD is rejected before clearing the clipboard")
        print(
            "FORMAT CASE: RTFD 33 attachments rejected; capture fallback and failed-write clipboard preservation verified"
        )
        print(
            "PASS: RTFD attachment formats / native ordered import / 32-attachment boundary / 33-attachment rejection / plain fallback / failed-write preservation"
        )
    }

    private static func fixture(count: Int) throws -> Fixture {
        let document = NSMutableAttributedString(string: "图文测试 🧪\n", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let types: [(NSBitmapImageRep.FileType, String)] = [(.png, "png"), (.tiff, "tiff"), (.jpeg, "jpg")]
        var attachments: [Data] = []
        for index in 0..<count {
            let (type, ext) = types[index % types.count]
            guard
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData
            else {
                throw Failure.check("attachment bitmap fixture")
            }
            for y in 0..<8 {
                for x in 0..<8 {
                    let offset = y * bitmap.bytesPerRow + x * 4
                    pixels[offset] = UInt8((index * 7 + x * 19) % 256)
                    pixels[offset + 1] = UInt8((index * 13 + y * 23) % 256)
                    pixels[offset + 2] = UInt8((index * 17 + 90) % 256)
                    pixels[offset + 3] = 255
                }
            }
            guard let bytes = bitmap.representation(using: type, properties: [:]) else {
                throw Failure.check("attachment \(ext) encoding")
            }
            let file = FileWrapper(regularFileWithContents: bytes)
            file.preferredFilename = "attachment-\(index).\(ext)"
            document.append(NSAttributedString(string: "附件 \(index)："))
            document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: file)))
            document.append(NSAttributedString(string: "\n"))
            attachments.append(bytes)
        }
        document.append(NSAttributedString(string: "图文结束"))
        guard
            let archive = document.rtfd(
                from: NSRange(location: 0, length: document.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]),
            let package = FileWrapper(serializedRepresentation: archive),
            let children = package.fileWrappers
        else { throw Failure.check("native RTFD archive fixture") }
        try require(children.count == count + 1, "native RTFD fixture contains every distinct attachment and TXT.rtf")
        try require(
            archive.count < HistoryStore.maxRichTextBytes, "attachment-count boundary is independent of byte limit")
        return Fixture(archive: archive, text: document.string, attachments: attachments)
    }

    private static func roundTrip(_ fixture: Fixture, store: HistoryStore, board: NSPasteboard) throws {
        board.clearContents()
        try require(board.setData(fixture.archive, forType: .rtfd), "write native RTFD fixture")
        guard let snapshot = try ClipboardAccess.snapshot(from: board) else {
            throw Failure.check("attachment snapshot")
        }
        let before = board.changeCount
        guard let payload = try background(bytes: snapshot.byteCount, { try ClipboardAccess.process(snapshot) }),
            case .richText(let plain, let formats) = payload
        else { throw Failure.check("attachment background capture") }
        try require(
            formats[HistoryStore.rtfdType] == fixture.archive && plain.contains("图文结束"),
            "RTFD capture preserves original archive and trailing text")
        try require(board.changeCount == before, "background RTFD capture does not mutate source")
        let id = try store.add(payload, sourceApp: "Attachment self-test")
        let reopened = try HistoryStore(directory: store.directory)
        guard let saved = reopened.entries.first(where: { $0.id == id }) else {
            throw Failure.check("attachment history restart")
        }
        let directory = reopened.directory
        let prepared = try background(bytes: saved.byteCount) {
            try ClipboardAccess.prepareWrite(saved, directory: directory)
        }
        let wrote = try ClipboardAccess.commit(prepared, to: board)
        try require(
            wrote && board.data(forType: .rtfd) == fixture.archive,
            "RTFD archive survives save, restart and prepared write")

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        view.isRichText = true
        view.importsGraphics = true
        try require(view.readSelection(from: board, type: .rtfd), "NSTextView accepts restored RTFD")
        try require(view.string == fixture.text, "RTFD body and inline attachment positions survive native import")
        var imported: [Data] = []
        view.textStorage?.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)
        ) { value, _, _ in
            if let attachment = value as? NSTextAttachment, let bytes = attachment.fileWrapper?.regularFileContents {
                imported.append(bytes)
            }
        }
        try require(imported == fixture.attachments, "all imported attachment bytes and their order remain exact")
    }

    private static func background<Value: Sendable>(bytes: Int, _ work: @escaping @Sendable () throws -> Value) throws
        -> Value
    {
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        var result: Result<Value, Error>?
        guard scheduler.submit(byteCount: bytes, work: work, completion: { result = $0 }) != nil,
            SelfTestWait.until(timeout: 10, { result != nil }), let result
        else {
            throw Failure.check("background attachment operation completes")
        }
        return try result.get()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.check(message) }
    }
}
