import AppKit
import ApplicationServices
import ClipboardCore
import Darwin
import ImageIO

/// Deterministic malformed inputs, confined to a named pasteboard and temporary
/// store. Each case is at most a few KiB and releases its AppKit objects promptly.
@MainActor
enum FormatStressSelfTests {
    private enum Failure: Error { case check(String) }

    private struct Generator {
        var state: UInt64 = 0xC11F_0A7D_2026
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(bound))
        }
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardDeck-format-stress-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = try HistoryStore(directory: root)
        let image = try fixtureImage()
        let png = try encodedImage(image, type: "public.png", frames: 1)
        let rtf = Data(#"{\rtf1\ansi Alpha {\b bold} \u20013?\u25991?\par Omega}"#.utf8)
        let wrapper = FileWrapper(directoryWithFileWrappers: ["TXT.rtf": FileWrapper(regularFileWithContents: rtf)])
        guard let rtfd = wrapper.serializedRepresentation else { throw Failure.check("RTFD stress fixture") }
        try checkExplicitRichSnapshot(rtf: rtf, rtfd: rtfd, board: board)
        try checkBoundedRTFDReader(rtf: rtf, rtfd: rtfd, board: board)
        let seeds: [(NSPasteboard.PasteboardType, Data)] = [
            (.rtf, rtf), (.html, Data("<p><b>Alpha 中文</b> &amp; Omega</p>".utf8)), (.rtfd, rtfd), (.png, png),
        ]
        var generator = Generator()
        var truncatedRTFD: Data?
        let trace = ProcessInfo.processInfo.environment["STRESS_TRACE_FORMATS"] == "1"
        for iteration in 0..<256 {
            try autoreleasepool {
                let (type, seed) = seeds[iteration % seeds.count]
                var bytes = [UInt8](seed)
                switch (iteration / seeds.count) % 5 {
                case 0: bytes = Array(bytes.prefix(generator.next(bytes.count)))
                case 1:
                    for _ in 0..<8 { bytes[generator.next(bytes.count)] = UInt8(generator.next(256)) }
                case 2: bytes += (0..<8).map { _ in UInt8(generator.next(256)) }
                case 3:
                    let start = generator.next(bytes.count)
                    bytes.removeSubrange(start..<min(start + 8, bytes.count))
                default: break  // Keep known-valid controls in the same mixed workload.
                }
                let input = Data(bytes)
                if iteration == 2 { truncatedRTFD = input }
                if trace {
                    let line = "FORMAT FUZZ: case=\(iteration) type=\(type.rawValue) bytes=\(input.count)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
                let fallback = "stress fallback \(iteration) 中文 🧪"
                board.clearContents()
                try require(board.setData(input, forType: type), "case \(iteration): set input")
                try require(board.setString(fallback, forType: .string), "case \(iteration): set fallback")
                let changeCount = board.changeCount
                var heapBefore = malloc_statistics_t()
                if trace { malloc_zone_statistics(nil, &heapBefore) }
                let captured: ClipPayload?
                do { captured = try ClipboardAccess.read(from: board) } catch {
                    throw Failure.check("case \(iteration): capture failed: \(error)")
                }
                if trace {
                    var heapAfter = malloc_statistics_t()
                    malloc_zone_statistics(nil, &heapAfter)
                    let delta = Int64(heapAfter.size_in_use) - Int64(heapBefore.size_in_use)
                    if delta > 1_048_576 {
                        let line =
                            "FORMAT ALLOCATION: case=\(iteration) type=\(type.rawValue) delta=\(delta) input=\(input.base64EncodedString())\n"
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                }
                guard let payload = captured else {
                    throw Failure.check("case \(iteration): valid plain fallback must not disappear")
                }
                try require(board.changeCount == changeCount, "case \(iteration): capture must not mutate source")
                if iteration == 2 || iteration == 103 {
                    guard case .text(let text) = payload, text == fallback else {
                        throw Failure.check("case \(iteration): truncated RTFD/PNG becomes safe plain fallback")
                    }
                }
                switch payload {
                case .text(let text):
                    try require(text == fallback, "case \(iteration): exact plain fallback")
                case .richText(let text, let formats):
                    try require(
                        text == fallback && formats[type.rawValue] == input && formats.count == 1,
                        "case \(iteration): retained rich representation is byte-identical")
                case .image(_, let width, let height):
                    try require(width > 0 && height > 0, "case \(iteration): valid image dimensions")
                case .files: throw Failure.check("case \(iteration): never reinterpret malformed format as files")
                }
                let id: UUID
                do { id = try store.add(payload, sourceApp: "Format stress test") } catch {
                    throw Failure.check("case \(iteration): store.add failed: \(error)")
                }
                let restarted = try HistoryStore(directory: root)
                guard let saved = restarted.entries.first(where: { $0.id == id }) else {
                    throw Failure.check("case \(iteration): survives restart")
                }
                let prepared: ClipboardAccess.PreparedWrite
                do { prepared = try ClipboardAccess.prepareWrite(saved, directory: root) } catch {
                    throw Failure.check("case \(iteration): prepareWrite failed: \(error)")
                }
                try require(prepared.byteCount <= ClipboardAccess.maxPreparedWriteBytes, "bounded prepared output")
                let committed = try ClipboardAccess.commit(prepared, to: board)
                try require(committed, "case \(iteration): prepared output commits")
                switch payload {
                case .text(let text):
                    try require(board.string(forType: .string) == text, "case \(iteration): restored plain bytes")
                case .richText(_, let formats):
                    for (name, data) in formats {
                        try require(board.data(forType: .init(name)) == data, "case \(iteration): restored rich bytes")
                    }
                case .image(let data, _, _):
                    try require(board.data(forType: .png) == data, "case \(iteration): restored PNG bytes")
                case .files: break
                }
            }
        }
        print("FORMAT STRESS: 256 deterministic RTF/HTML/RTFD/PNG mutations, fallback, restart and write round-trips")

        // Case 2 previously terminated the process with NSDeserializeException.
        // Also exercise the same malformed bytes in a previously stored record:
        // the paste preflight must reject without clearing its destination.
        guard let truncatedRTFD, !truncatedRTFD.isEmpty else {
            throw Failure.check("truncated RTFD regression fixture")
        }
        let invalidID = try store.add(
            .richText(text: "damaged RTFD", formats: [HistoryStore.rtfdType: truncatedRTFD]),
            sourceApp: "Format stress regression")
        guard let invalidEntry = store.entries.first(where: { $0.id == invalidID }) else {
            throw Failure.check("stored malformed RTFD")
        }
        board.clearContents()
        try require(board.setString("keep before malformed RTFD write", forType: .string), "set rejection sentinel")
        let beforeMalformedWrite = board.changeCount
        do {
            _ = try ClipboardAccess.write(invalidEntry, store: store, to: board)
            throw Failure.check("malformed saved RTFD must not be written")
        } catch ClipboardAccess.FormatError.invalidRichText {}
        try require(
            board.changeCount == beforeMalformedWrite
                && board.string(forType: .string) == "keep before malformed RTFD write",
            "malformed saved RTFD preserves destination before any clear")
        try checkBackgroundRejection(truncatedRTFD, entry: invalidEntry, directory: root, board: board)
        print(
            "FORMAT STRESS: truncated RTFD exception and truncated PNG regressions / background fallback and rejection / drained budgets / failed-write preservation"
        )

        // A multipage image must never silently become just its first page.
        let multiPageTIFF = try encodedImage(image, type: "public.tiff", frames: 2)
        guard let source = CGImageSourceCreateWithData(multiPageTIFF as CFData, nil),
            CGImageSourceGetCount(source) == 2
        else { throw Failure.check("two-page TIFF fixture") }
        board.clearContents()
        try require(board.setData(multiPageTIFF, forType: .tiff), "set multipage TIFF")
        let before = board.changeCount
        var rejected = false
        do { rejected = try ClipboardAccess.read(from: board) == nil } catch HistoryError.invalidImage {
            rejected = true
        }
        try require(rejected, "multipage TIFF must be rejected instead of silently keeping only the first page")
        try require(board.changeCount == before, "multipage rejection leaves original clipboard intact")
        try require(board.setString("multipage fallback", forType: .string), "set multipage fallback")
        guard case .text("multipage fallback") = try ClipboardAccess.read(from: board) else {
            throw Failure.check("unsupported multipage image uses its valid text fallback")
        }
        try checkOrientedPNG(store: store, board: board)
        try checkAdditionalMutations(store: store, board: board, image: image, rtf: rtf, rtfd: rtfd, png: png)
        print(
            "PASS: bounded format mutations / capture immutability / persistent byte round-trips / multipage image rejection / oriented PNG parity / no-fallback mutations"
        )
    }

    private static func checkExplicitRichSnapshot(rtf: Data, rtfd: Data, board: NSPasteboard) throws {
        for (type, bytes) in [(NSPasteboard.PasteboardType.rtf, rtf), (.rtfd, rtfd)] {
            board.clearContents()
            try require(board.setData(bytes, forType: type), "explicit rich-only fixture")
            if type == .rtf {
                let plain = try plainFlavorMetadata(on: board)
                try require(
                    plain.status == badPasteboardFlavorErr || plain.flags.contains(.systemTranslated),
                    "RTF-only plain text is absent from the source or marked as a system translation")
            }
            guard let snapshot = try ClipboardAccess.snapshot(from: board) else {
                throw Failure.check("explicit rich-only snapshot")
            }
            // An exact byte count proves the snapshot copied only the supplied
            // representation: no synthesized text or alternate rich flavor.
            try require(snapshot.byteCount == bytes.count, "rich-only snapshot never asks for synthesized data")
            guard case .richText(let text, let formats) = try ClipboardAccess.process(snapshot) else {
                throw Failure.check("rich-only data uses bounded background-compatible parsing")
            }
            try require(
                formats == [type.rawValue: bytes] && text.contains("Alpha") && text.contains("中文"),
                "rich-only text is extracted while exact supplied format is retained")

            let fallback = "explicit plain fallback 中文"
            try require(board.setString(fallback, forType: .string), "explicit plain fallback fixture")
            let plain = try plainFlavorMetadata(on: board)
            try require(
                plain.status == noErr && !plain.flags.contains(.systemTranslated),
                "explicit plain fallback has its own underlying nontranslated flavor")
            guard let withFallback = try ClipboardAccess.snapshot(from: board),
                case .richText(let retainedText, let retainedFormats) = try ClipboardAccess.process(withFallback)
            else { throw Failure.check("explicit rich and plain snapshot") }
            try require(
                withFallback.byteCount == bytes.count + fallback.utf8.count
                    && retainedText == fallback && retainedFormats == [type.rawValue: bytes],
                "explicit plain fallback remains exact and takes precedence")
        }
        print("FORMAT RECHECK: RTF/RTFD snapshot copies only supplied formats; explicit plain fallback preserved")
    }

    private static func plainFlavorMetadata(on board: NSPasteboard) throws -> (
        status: OSStatus, flags: PasteboardFlavorFlags
    ) {
        var reference: Pasteboard?
        guard PasteboardCreate(board.name.rawValue as CFString, &reference) == noErr, let reference else {
            throw Failure.check("private pasteboard metadata reference")
        }
        PasteboardSynchronize(reference)
        var identifier: PasteboardItemID?
        guard PasteboardGetItemIdentifier(reference, 1, &identifier) == noErr, let identifier else {
            throw Failure.check("private pasteboard metadata item")
        }
        var flags: PasteboardFlavorFlags = []
        let status = PasteboardGetItemFlavorFlags(
            reference, identifier, NSPasteboard.PasteboardType.string.rawValue as CFString, &flags)
        return (status, flags)
    }

    private static func checkBoundedRTFDReader(rtf: Data, rtfd: Data, board: NSPasteboard) throws {
        func read(_ data: Data) -> [String: Data]? {
            FlatRTFDReader.children(in: data, maxChildren: 33, maxBytes: HistoryStore.maxRichTextBytes)
        }
        try require(read(rtfd) == ["TXT.rtf": rtf], "bounded reader matches native regular-file archive")
        var invalid: [(String, Data)] = []
        // Known-good native single-file fixture: two dictionary entries, TXT.rtf
        // and the root directory metadata. Mutate length/count words, not payloads.
        for offset in [4, 12, 16, 32, 44] {
            var bytes = rtfd
            guard bytes.count > offset + 3 else { throw Failure.check("native archive regression offsets") }
            for i in 0..<4 { bytes[offset + i] = 0xff }
            invalid.append(("oversized/unknown word at \(offset)", bytes))
        }
        invalid.append(("trailing unconsumed bytes", rtfd + Data([0])))
        var unknownMetadata = flatFixture(children: [("TXT.rtf", rtf)], rootNames: ["TXT.rtf"], kinds: [0])
        unknownMetadata[unknownMetadata.count - 4] = 1
        invalid.append(("unknown nonzero directory metadata", unknownMetadata))
        invalid.append(
            (
                "mismatched root metadata",
                flatFixture(
                    children: [("TXT.rtf", rtf)], rootNames: ["other.rtf"], kinds: [0])
            ))
        invalid.append(
            (
                "duplicate archive filename",
                flatFixture(
                    children: [("TXT.rtf", rtf), ("TXT.rtf", rtf)], rootNames: ["TXT.rtf", "TXT.rtf"], kinds: [0, 0])
            ))
        invalid.append(
            (
                "duplicate directory filename",
                flatFixture(
                    children: [("TXT.rtf", rtf), ("a.png", Data([1]))], rootNames: ["TXT.rtf", "TXT.rtf"],
                    kinds: [0, 0])
            ))
        invalid.append(
            (
                "nested directory kind",
                flatFixture(
                    children: [("TXT.rtf", rtf)], rootNames: ["TXT.rtf"], kinds: [1])
            ))
        invalid.append(
            (
                "symbolic link kind",
                flatFixture(
                    children: [("TXT.rtf", rtf)], rootNames: ["TXT.rtf"], kinds: [4])
            ))
        invalid.append(
            (
                "path traversal filename",
                flatFixture(
                    children: [("../TXT.rtf", rtf)], rootNames: ["../TXT.rtf"], kinds: [0])
            ))
        // These exact bounded mutations previously caused ~11.6 GiB retained
        // malloc allocation apiece inside the system deserializer before throwing.
        let formerlyAllocating = [
            "cnRmZAAAAAADAAAAAgAAAAcAAABUWFQucnRmAQAAAC4/AAAAKwAAAAEAAAA3AAAAe1xydGYxXGFuc3tcYiBib2xkfSBcdTIwMDEzP1x1MjU5OTE/XHBhciBPbWVnYX0BAAAAIwAAAAEAAAAHAAAAVFhULnJ0ZhAAAABEHPBqtgEAAAAAAAAAAAAA",
            "cnRmZAAAAAADAAAAAgAAAAcAAABUWFQucnRmAQAAAC4/AAAAKwAAAAEAAAA3AAAAe1xyIEFscGhhIHtcYiBib2xkfSBcdTIwMDEzP1x1MjU5OTE/XHBhciBPbWVnYX0BAAAAIwAAAAEAAAAHAAAAVFhULnJ0ZhAAAABEHPBqtgEAAAAAAAAAAAAA",
            "cnRmZAAAAAADAAAAAgAAAAcAAABUWFQucnRmAQAAAC4/AAAAKwAAAAEAAAA3AAAAe1xydGYxXGFuc2kgQWxwaGEge1xiIGJvbGQzP1x1MjU5OTE/XHBhciBPbWVnYX0BAAAAIwAAAAEAAAAHAAAAVFhULnJ0ZhAAAABEHPBqtgEAAAAAAAAAAAAA",
            "cnRmZAAAAAADAAAAAgAAAAcAAABUWFQucnRmAQAAAC4/AAAAKwAAAAEAAAA3AAAAe1xydGYxXGFuc2kgQWxwaGEge1xiIGJvbGR9IFx1MjAwMTM/XHUyNTk5MT9ccGFyIE8AIwAAAAEAAAAHAAAAVFhULnJ0ZhAAAABEHPBqtgEAAAAAAAAAAAAA",
            "cnRmZAAAAAADAAAAAgAAAAcAAABUWFQucnRmAQAAAC4/AAAAKwAAAAEAAAA3AAAAe1xydGYxXGFuc2kgQWxwaGEge1xiIGJvbGR9IFx1MjAwMTM/XHUyNTk5MT9cYX0BAAAAIwAAAAEAAAAHAAAAVFhULnJ0ZhAAAABEHPBqtgEAAAAAAAAAAAAA",
        ]
        for (index, encoded) in formerlyAllocating.enumerated() {
            guard let data = Data(base64Encoded: encoded) else { throw Failure.check("allocation regression fixture") }
            invalid.append(("formerly allocating mutation \(index)", data))
        }
        for (label, bytes) in invalid {
            try require(read(bytes) == nil, label + ": structure rejected before native decode")
            board.clearContents()
            try require(board.setData(bytes, forType: .rtfd), label + ": set no-fallback bytes")
            let version = board.changeCount
            let withoutFallback = try ClipboardAccess.read(from: board)
            try require(withoutFallback == nil && board.changeCount == version, label + ": no-fallback rejection")
            try require(board.setString("safe RTFD fallback", forType: .string), label + ": add fallback")
            guard case .text("safe RTFD fallback") = try ClipboardAccess.read(from: board) else {
                throw Failure.check(label + ": exact plain fallback")
            }
        }
        print(
            "FORMAT RECHECK: \(invalid.count) flat RTFD structural rejections, including 5 prior allocation regressions"
        )
    }

    /// Small independent fixture writer for hostile directory metadata. It does
    /// not invoke the native decoder or create any filesystem nodes.
    private static func flatFixture(
        children: [(String, Data)], rootNames: [String], kinds: [UInt32]
    ) -> Data {
        func word(_ value: UInt32) -> Data {
            Data([
                UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24),
            ])
        }
        func string(_ value: String) -> Data { word(UInt32(value.utf8.count)) + Data(value.utf8) }
        func record(_ value: Data) -> Data { word(1) + word(UInt32(value.count)) + value }
        var info = word(UInt32(rootNames.count))
        for name in rootNames { info += string(name) }
        for _ in rootNames { info += word(16) }
        for kind in kinds { info += word(0) + word(0o666) + word(kind) + word(0) }
        let entries = children + [(".", info)]
        var data = Data("rtfd".utf8) + word(0) + word(3) + word(UInt32(entries.count))
        for (name, _) in entries { data += string(name) }
        for (_, value) in entries { data += word(UInt32(value.count + 8)) }
        for (_, value) in entries { data += record(value) }
        return data
    }

    private static func checkOrientedPNG(store: HistoryStore, board: NSPasteboard) throws {
        let image = try fixtureImage(width: 4, height: 2)
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else {
            throw Failure.check("orientation PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
            let source = CGImageSourceCreateWithData(bytes, nil),
            let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            metadata[kCGImagePropertyOrientation] as? Int == 6
        else { throw Failure.check("orientation PNG fixture must contain EXIF orientation 6") }
        let png = bytes as Data
        board.clearContents()
        try require(board.setData(png, forType: .png), "set oriented PNG")
        guard case .image(let captured, let width, let height) = try ClipboardAccess.read(from: board) else {
            throw Failure.check("oriented PNG capture")
        }
        try require(captured == png && width == 4 && height == 2, "PNG retains original bytes and stored dimensions")
        let id = try store.add(.image(png: captured, width: width, height: height), sourceApp: "Orientation regression")
        let restarted = try HistoryStore(directory: store.directory)
        guard let entry = restarted.entries.first(where: { $0.id == id }) else {
            throw Failure.check("oriented PNG restart")
        }
        let written = try ClipboardAccess.write(entry, store: restarted, to: board)
        try require(written, "oriented PNG write")
        guard board.data(forType: .png) == png, let tiff = board.data(forType: .tiff) else {
            throw Failure.check("oriented PNG and TIFF outputs")
        }
        let pngDisplay = try displayedImage(png)
        let tiffDisplay = try displayedImage(tiff)
        try require(pngDisplay.width == 2 && pngDisplay.height == 4, "PNG native consumer rotates using EXIF")
        try require(
            pngDisplay.width == tiffDisplay.width && pngDisplay.height == tiffDisplay.height,
            "PNG and TIFF representations must have the same displayed orientation")
        print("FORMAT RECHECK: EXIF-oriented PNG retains exact original bytes and matching TIFF display dimensions")
    }

    private static func displayedImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4,
                ] as CFDictionary)
        else { throw Failure.check("native oriented image consumer") }
        return image
    }

    private static func checkAdditionalMutations(
        store: HistoryStore, board: NSPasteboard, image: CGImage, rtf: Data, rtfd: Data, png: Data
    ) throws {
        let formats: [(NSPasteboard.PasteboardType, Data)] = [
            (.rtf, rtf), (.html, Data("<b>中文 &amp; recheck</b>".utf8)), (.rtfd, rtfd), (.png, png),
            (.tiff, try encodedImage(image, type: "public.tiff", frames: 1)),
            (.init("public.jpeg"), try encodedImage(image, type: "public.jpeg", frames: 1)),
        ]
        var accepted = 0
        var rejected = 0
        for seed: UInt64 in [0x1212, 0xA11C_E55, 0xFFFF_2026] {
            var random = Generator(state: seed)
            for iteration in 0..<64 {
                try autoreleasepool {
                    let (type, original) = formats[iteration % formats.count]
                    var bytes = [UInt8](original)
                    switch iteration % 5 {
                    case 0: bytes = Array(bytes.prefix(random.next(bytes.count)))
                    case 1:
                        for _ in 0..<4 { bytes[random.next(bytes.count)] = UInt8(random.next(256)) }
                    case 2: bytes.append(contentsOf: (0..<4).map { _ in UInt8(random.next(256)) })
                    case 3:
                        let offset = random.next(bytes.count)
                        bytes.removeSubrange(offset..<min(offset + 4, bytes.count))
                    default: break
                    }
                    let input = Data(bytes)
                    let label = "seed \(seed) case \(iteration) (\(type.rawValue))"
                    board.clearContents()
                    try require(board.setData(input, forType: type), label + ": set no-fallback input")
                    let before = board.changeCount
                    let payload: ClipPayload?
                    do { payload = try ClipboardAccess.read(from: board) } catch is HistoryError { payload = nil }
                    try require(
                        board.changeCount == before && board.data(forType: type) == input,
                        label + ": acceptance or rejection never alters source")
                    guard let payload else {
                        try require(iteration % 5 != 4, label + ": valid control must not be rejected")
                        rejected += 1
                        return
                    }
                    accepted += 1
                    let id = try store.add(payload, sourceApp: "No-fallback format stress")
                    let reloaded = try HistoryStore(directory: store.directory)
                    guard let entry = reloaded.entries.first(where: { $0.id == id }) else {
                        throw Failure.check(label + ": accepted input survives restart")
                    }
                    let prepared: ClipboardAccess.PreparedWrite
                    do { prepared = try ClipboardAccess.prepareWrite(entry, directory: store.directory) } catch {
                        throw Failure.check(label + ": accepted input cannot be prepared: \(error)")
                    }
                    let written = try ClipboardAccess.commit(prepared, to: board)
                    try require(written, label + ": write accepted input")
                    switch payload {
                    case .text(let text): try require(board.string(forType: .string) == text, label + ": exact text")
                    case .richText(_, let raw):
                        for (key, value) in raw {
                            try require(board.data(forType: .init(key)) == value, label + ": exact rich bytes")
                        }
                    case .image(let image, _, _):
                        try require(board.data(forType: .png) == image, label + ": exact PNG output")
                    case .files: throw Failure.check(label + ": malformed content must not become file references")
                    }
                }
            }
        }
        try require(accepted > 0 && rejected > 0, "additional seeds cover both accepted and rejected inputs")
        print(
            "FORMAT RECHECK: 192 mutations across 3 new seeds without plain fallback; accepted=\(accepted), rejected=\(rejected)"
        )
    }

    private static func checkBackgroundRejection(
        _ data: Data, entry: ClipEntry, directory: URL, board: NSPasteboard
    ) throws {
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        board.clearContents()
        try require(board.setData(data, forType: .rtfd), "set background malformed RTFD")
        try require(board.setString("background RTFD fallback 中文", forType: .string), "set background fallback")
        guard let snapshot = try ClipboardAccess.snapshot(from: board) else {
            throw Failure.check("background malformed RTFD snapshot")
        }
        let beforeCapture = board.changeCount
        var captureResult: Result<(ClipPayload?, Bool), Error>?
        guard
            scheduler.submit(
                byteCount: snapshot.byteCount,
                work: { (try ClipboardAccess.process(snapshot), !Thread.isMainThread) },
                completion: { captureResult = $0 }) != nil,
            SelfTestWait.until(timeout: 10, { captureResult != nil }), let captureResult
        else { throw Failure.check("background malformed RTFD completes without crashing") }
        let (payload, offMainThread) = try captureResult.get()
        guard case .text("background RTFD fallback 中文") = payload else {
            throw Failure.check("background malformed RTFD returns exact plain fallback")
        }
        try require(offMainThread, "malformed RTFD is processed on the real worker thread")
        try require(
            board.changeCount == beforeCapture && board.data(forType: .rtfd) == data
                && board.string(forType: .string) == "background RTFD fallback 中文",
            "background exception recovery never mutates the source pasteboard")
        try require(
            scheduler.outstandingCount == 0 && scheduler.retainedBytes == 0,
            "background malformed RTFD capture releases task and byte budgets")

        board.clearContents()
        try require(board.setString("preserve background paste target", forType: .string), "set background target")
        let beforePrepare = board.changeCount
        var prepareResult: Result<ClipboardAccess.PreparedWrite, Error>?
        guard
            scheduler.submit(
                byteCount: entry.byteCount,
                work: {
                    guard !Thread.isMainThread else { throw Failure.check("paste preflight must run off main thread") }
                    return try ClipboardAccess.prepareWrite(entry, directory: directory)
                },
                completion: { prepareResult = $0 }) != nil,
            SelfTestWait.until(timeout: 10, { prepareResult != nil }), let prepareResult
        else { throw Failure.check("background malformed saved RTFD preflight completes") }
        do {
            _ = try prepareResult.get()
            throw Failure.check("background malformed saved RTFD must reject before commit")
        } catch ClipboardAccess.FormatError.invalidRichText {}
        try require(
            board.changeCount == beforePrepare && board.string(forType: .string) == "preserve background paste target",
            "background malformed saved RTFD leaves destination intact")
        try require(
            scheduler.outstandingCount == 0 && scheduler.retainedBytes == 0 && scheduler.canSubmit,
            "background rejection releases all budgets and worker remains usable")
    }

    private static func fixtureImage(width: Int = 4, height: Int = 4) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.check("image context") }
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw Failure.check("image fixture") }
        return image
    }

    private static func encodedImage(_ image: CGImage, type: String, frames: Int) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, frames, nil) else {
            throw Failure.check("image encoder")
        }
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
        guard CGImageDestinationFinalize(destination) else { throw Failure.check("image encoding") }
        return data as Data
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.check(message) }
    }
}
