import AppKit
import ClipboardCore

/// Exercise both Foundation page layouts regardless of the current CPU.
@MainActor
enum AlignedRTFDSelfTests {
    private enum Failure: Error { case check(String) }
    private struct Fixture {
        let archive: Data
        let rtf: Data
        let text: String
        let recordOffset: Int
        let sizeOffset: Int
        let recordSize: Int
        let padding: Int
    }

    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardDeck-aligned-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = try HistoryStore(directory: directory)
        var rejectionCount = 0
        for alignment in [4_096, 16_384] {
            let fixture = fixture(alignment: alignment)
            try roundTrip(fixture, store: store, board: board)
            for (label, bytes) in malformed(fixture) {
                try reject(bytes, label: "\(alignment): \(label)", store: store, board: board)
                rejectionCount += 1
            }
        }
        print(
            "FORMAT RECHECK: 4 KiB / 16 KiB aligned RTFD native import and exact restart/write; \(rejectionCount) malformed layouts rejected with plain fallback and failed-write preservation"
        )
    }

    private static func read(_ data: Data) -> [String: Data]? {
        FlatRTFDReader.children(in: data, maxChildren: 33, maxBytes: HistoryStore.maxRichTextBytes)
    }

    private static func roundTrip(_ fixture: Fixture, store: HistoryStore, board: NSPasteboard) throws {
        try require(read(fixture.archive) == ["TXT.rtf": fixture.rtf], "aligned reader contents")
        let sliced = (Data([0]) + fixture.archive).dropFirst()
        try require(read(sliced) == ["TXT.rtf": fixture.rtf], "nonzero-startIndex archive")
        // Only our valid, bounded fixtures reach native FileWrapper decoding.
        guard let native = FileWrapper(serializedRepresentation: fixture.archive) else {
            throw Failure.check("native aligned fixture decoding")
        }
        try require(native.fileWrappers?["TXT.rtf"]?.regularFileContents == fixture.rtf, "native body bytes")
        board.clearContents()
        try require(board.setData(fixture.archive, forType: .rtfd), "write aligned fixture")
        guard let payload = try ClipboardAccess.read(from: board),
            case .richText(let text, let formats) = payload
        else { throw Failure.check("aligned rich-text capture") }
        try require(text == fixture.text && formats[HistoryStore.rtfdType] == fixture.archive, "aligned capture")
        let id = try store.add(payload, sourceApp: "Aligned RTFD self-test")
        let reopened = try HistoryStore(directory: store.directory)
        guard let entry = reopened.entries.first(where: { $0.id == id }) else {
            throw Failure.check("aligned history restart")
        }
        let wrote = try ClipboardAccess.write(entry, store: reopened, to: board)
        try require(wrote && board.data(forType: .rtfd) == fixture.archive, "aligned archive exact after write")
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        view.isRichText = true
        try require(view.readSelection(from: board, type: .rtfd), "native aligned rich-text import")
        try require(view.string == fixture.text, "aligned body text unchanged")
    }

    private static func reject(_ bytes: Data, label: String, store: HistoryStore, board: NSPasteboard) throws {
        try require(read(bytes) == nil, label + ": bounded rejection")
        board.clearContents()
        try require(board.setData(bytes, forType: .rtfd), label + ": write invalid fixture")
        let before = board.changeCount
        let captured = try ClipboardAccess.read(from: board)
        try require(
            captured == nil && board.changeCount == before && board.data(forType: .rtfd) == bytes,
            label + ": reject without source mutation")
        let fallback = "safe aligned RTFD fallback"
        try require(board.setString(fallback, forType: .string), label + ": add fallback")
        guard case .text(let text) = try ClipboardAccess.read(from: board), text == fallback else {
            throw Failure.check(label + ": exact fallback")
        }
        let id = try store.add(.richText(text: fallback, formats: [HistoryStore.rtfdType: bytes]), sourceApp: label)
        guard let entry = store.entries.first(where: { $0.id == id }) else {
            throw Failure.check(label + ": stored invalid fixture")
        }
        board.clearContents()
        try require(board.setString("preserve current clipboard", forType: .string), label + ": sentinel")
        let beforeWrite = board.changeCount
        do {
            _ = try ClipboardAccess.write(entry, store: store, to: board)
            throw Failure.check(label + ": invalid stored archive was pasted")
        } catch ClipboardAccess.FormatError.invalidRichText {}
        try require(
            board.changeCount == beforeWrite && board.string(forType: .string) == "preserve current clipboard",
            label + ": failed paste preserves clipboard")
    }

    private static func malformed(_ fixture: Fixture) -> [(String, Data)] {
        var cases: [(String, Data)] = []
        func changedWord(_ label: String, offset: Int, value: UInt32) {
            var bytes = fixture.archive
            bytes.replaceSubrange(offset..<(offset + 4), with: word(value))
            cases.append((label, bytes))
        }
        changedWord("unknown marker", offset: fixture.recordOffset + 4, value: 0x8000_0001)
        changedWord("oversized content", offset: fixture.recordOffset + 8, value: .max)
        changedWord("inexact content length", offset: fixture.recordOffset + 8, value: UInt32(fixture.rtf.count + 1))
        changedWord("oversized padding", offset: fixture.recordOffset + 12, value: .max)
        var unaligned = fixture.archive
        unaligned.insert(0, at: fixture.recordOffset + 16)
        unaligned.replaceSubrange(
            (fixture.recordOffset + 12)..<(fixture.recordOffset + 16), with: word(UInt32(fixture.padding + 1)))
        unaligned.replaceSubrange(
            fixture.sizeOffset..<(fixture.sizeOffset + 4), with: word(UInt32(fixture.recordSize + 1)))
        cases.append(("wrong alignment with exact lengths", unaligned))
        var nonzero = fixture.archive
        nonzero[fixture.recordOffset + 16] = 1
        cases.append(("nonzero padding", nonzero))
        cases.append(("trailing byte", fixture.archive + Data([0])))
        cases.append(("truncated archive", Data(fixture.archive.dropLast())))
        for size in [8, 12] {
            var short = fixture.archive
            short.removeSubrange((fixture.recordOffset + size)..<(fixture.recordOffset + fixture.recordSize))
            short.replaceSubrange(fixture.sizeOffset..<(fixture.sizeOffset + 4), with: word(UInt32(size)))
            cases.append(("truncated extended header \(size)", short))
        }
        return cases
    }

    private static func fixture(alignment: Int) -> Fixture {
        let prefix = "{\\rtf1\\ansi Alignment "
        let suffix = " end}"
        // This size places the second record's content at an already aligned
        // offset: both nonzero and zero padding are exercised in every fixture.
        let body = String(repeating: "x", count: alignment * 2 - 16 - prefix.utf8.count - suffix.utf8.count)
        let rtf = Data((prefix + body + suffix).utf8)
        let info = word(1) + string("TXT.rtf") + word(16) + word(0) + word(0o666) + word(0) + word(0)
        var header = Data("rtfd".utf8) + word(0) + word(3) + word(2) + string("TXT.rtf") + string(".")
        let sizeOffset = header.count
        let recordOffset = header.count + 8
        func record(_ contents: Data, offset: Int) -> Data {
            let padding = (alignment - (offset + 16) % alignment) % alignment
            return word(1) + word(0x8000_0000) + word(UInt32(contents.count)) + word(UInt32(padding))
                + Data(repeating: 0, count: padding) + contents
        }
        let first = record(rtf, offset: recordOffset)
        let second = record(info, offset: recordOffset + first.count)
        header += word(UInt32(first.count)) + word(UInt32(second.count))
        return Fixture(
            archive: header + first + second, rtf: rtf, text: "Alignment " + body + " end",
            recordOffset: recordOffset, sizeOffset: sizeOffset, recordSize: first.count,
            padding: (alignment - (recordOffset + 16) % alignment) % alignment)
    }

    private static func word(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24),
        ])
    }

    private static func string(_ value: String) -> Data { word(UInt32(value.utf8.count)) + Data(value.utf8) }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw Failure.check(label) }
    }
}
