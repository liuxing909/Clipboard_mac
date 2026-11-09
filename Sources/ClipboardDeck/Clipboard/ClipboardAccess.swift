import AppKit
import ApplicationServices
import ImageIO
import ClipboardCore
import ClipboardNativeBridge
import CryptoKit

enum ClipboardAccess {
    private static let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    private static let legacyFilesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let richTypes: [NSPasteboard.PasteboardType] = [.rtfd, .rtf, .html]
    static let maxSnapshotBytes = 25 * 1_048_576
    static let maxPreparedWriteBytes = 25 * 1_048_576
    static let maxRTFDAttachments = 32

    /// An immutable, bounded copy of one change. No pasteboard or AppKit object
    /// crosses the queue boundary; decoding starts only in process(_:).
    struct Snapshot: Sendable {
        fileprivate let files: [URL]?
        fileprivate let text: Data?
        fileprivate let formats: [String: Data]
        fileprivate let images: [Data]
        fileprivate let oversizedRepresentation: Bool
        let changeCount: Int
        let byteCount: Int
    }

    struct PreparedWrite: Sendable {
        fileprivate let items: [[String: Data]]
        fileprivate let fileURLs: [URL]
        let byteCount: Int
    }

    enum FormatError: LocalizedError {
        case invalidFiles, missingFile(String), invalidRichText, unsupportedMultipleItems, changedDuringCapture
        var errorDescription: String? {
            switch self {
            case .invalidFiles: return "文件记录不是有效的本地文件地址。"
            case .missingFile(let name): return "文件“\(name)”已移动、删除或无法读取，请重新复制。"
            case .invalidRichText: return "富文本格式无效或包含暂不支持的附件。"
            case .unsupportedMultipleItems: return "暂不支持混合类型的多项复制，请分别复制。"
            case .changedDuringCapture: return "复制内容已更新，正在等待最新内容。"
            }
        }
    }

    /// Call on the pasteboard's owning (main) thread. Only bounded byte copying
    /// happens here. The system may still materialize a promised representation
    /// before its size is known; that IPC latency is outside the app's control.
    static func snapshot(from board: NSPasteboard) throws -> Snapshot? {
        let changeCount = board.changeCount
        let items = board.pasteboardItems ?? []
        let types = (board.types ?? []) + items.flatMap(\.types)
        guard !ClipboardPolicy.shouldIgnore(types: types.map(\.rawValue)) else { return nil }
        func finish(_ value: Snapshot?) throws -> Snapshot? {
            guard board.changeCount == changeCount else { throw FormatError.changedDuringCapture }
            let finalTypes = (board.types ?? []) + (board.pasteboardItems ?? []).flatMap(\.types)
            guard !ClipboardPolicy.shouldIgnore(types: finalTypes.map(\.rawValue)) else { return nil }
            guard board.changeCount == changeCount else { throw FormatError.changedDuringCapture }
            return value
        }
        func filesSnapshot(_ urls: [URL]) throws -> Snapshot? {
            try validateFileReferenceSize(urls)
            return try finish(
                Snapshot(
                    files: urls, text: nil, formats: [:], images: [], oversizedRepresentation: false,
                    changeCount: changeCount, byteCount: urls.reduce(0) { $0 + $1.absoluteString.utf8.count }))
        }
        let fileItems = items.filter { $0.types.contains(.fileURL) }
        if !fileItems.isEmpty {
            guard fileItems.count == items.count else { throw FormatError.unsupportedMultipleItems }
            guard fileItems.count <= HistoryStore.maxFileCount else { throw HistoryError.tooLarge }
            var bytes = 0
            let urls = try fileItems.map { item -> URL in
                guard let data = item.data(forType: .fileURL),
                    data.count <= HistoryStore.maxFileReferenceBytes - bytes
                else { throw HistoryError.tooLarge }
                bytes += data.count
                guard let raw = String(data: data, encoding: .utf8), let url = localFileURL(raw) else {
                    throw FormatError.invalidFiles
                }
                return url
            }
            return try filesSnapshot(urls)
        }
        // Never merge representations originating from different logical items.
        guard items.count <= 1 else { throw FormatError.unsupportedMultipleItems }
        if types.contains(legacyFilesType) {
            guard let data = board.data(forType: legacyFilesType),
                data.count <= HistoryStore.maxFileReferenceBytes
            else { throw HistoryError.tooLarge }
            guard
                let paths = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    as? [String],
                !paths.isEmpty, paths.count <= HistoryStore.maxFileCount,
                paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") })
            else { throw FormatError.invalidFiles }
            return try filesSnapshot(paths.map { URL(fileURLWithPath: $0) })
        }
        let itemTypes = items.first?.types ?? []
        let sourceTypes = try suppliedRichTypes(on: board, offered: itemTypes)
        let sourceHasRTF = itemTypes.contains(.rtf) || itemTypes.contains(.rtfd)
        // Asking the board for a synthesized string can run the system RTF
        // decoder here, before our bounded background validation. Capture an
        // explicit fallback; otherwise extract RTF/RTFD text in process(_:).
        let mayReadText = !sourceHasRTF || sourceTypes.contains(.string)
        let text = mayReadText && types.contains(.string) ? board.data(forType: .string) : nil
        guard (text?.count ?? 0) <= HistoryStore.maxTextBytes else { throw HistoryError.tooLarge }
        var bytes = text?.count ?? 0
        var richBytes = 0
        var formats: [String: Data] = [:]
        var oversizedRepresentation = false
        for type in richTypes {
            // A synthesized RTF flavor could deserialize RTFD before its safe
            // structural check. Only copy rich flavors the item actually offers.
            guard sourceTypes.contains(type), let data = board.data(forType: type), !data.isEmpty else { continue }
            guard data.count <= HistoryStore.maxRichTextBytes - richBytes else {
                oversizedRepresentation = true
                continue
            }
            formats[type.rawValue] = data
            richBytes += data.count
            bytes += data.count
        }
        var images: [Data] = []
        // Rich-text sources (notably Office) may lazily render large image
        // previews. Never ask them to produce those redundant representations.
        let sourceHasRichText = richTypes.contains { types.contains($0) }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, jpegType]
        let explicitImages = imageTypes.filter { itemTypes.contains($0) }
        // board.types includes system-synthesized flavors (e.g. JPEG -> TIFF).
        // Prefer representations actually supplied by the item to avoid doing
        // that conversion through pasteboard IPC on the main thread.
        let candidates = explicitImages.isEmpty ? imageTypes : explicitImages
        for type in sourceHasRichText ? [] : candidates {
            guard types.contains(type), let data = board.data(forType: type), !data.isEmpty else { continue }
            // An optional duplicate image flavor must not consume unbounded
            // memory or reject an otherwise usable preferred representation.
            guard data.count <= HistoryStore.maxImageBytes, data.count <= maxSnapshotBytes - bytes else {
                oversizedRepresentation = true
                continue
            }
            // Inspect only the container metadata on the main thread. A broken
            // header may use the next flavor; pixels are decoded by process(_:).
            guard
                let source = CGImageSourceCreateWithData(
                    data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetStatus(source) == .statusComplete,
                imageDimensions(source) != nil
            else {
                if images.isEmpty { images = [data] }  // Preserve a meaningful decode error if no fallback exists.
                continue
            }
            images = [data]
            bytes += data.count
            break  // Do not materialize every duplicate representation.
        }
        bytes = (text?.count ?? 0) + richBytes + images.reduce(0) { $0 + $1.count }
        guard bytes > 0 || oversizedRepresentation else { return try finish(nil) }
        return try finish(
            Snapshot(
                files: nil, text: text, formats: formats, images: images,
                oversizedRepresentation: oversizedRepresentation, changeCount: changeCount, byteCount: bytes))
    }

    /// NSPasteboardItem.types also lists AppKit-generated conversions. Query
    /// the underlying flavor metadata without requesting any representation.
    /// These Pasteboard Manager APIs are available since macOS 10.3.
    private static func suppliedRichTypes(
        on board: NSPasteboard, offered: [NSPasteboard.PasteboardType]
    ) throws -> Set<NSPasteboard.PasteboardType> {
        guard offered.contains(where: { richTypes.contains($0) }) else { return [] }
        // If metadata becomes unavailable, retry the snapshot rather than guess
        // a source flavor from AppKit's list of original and converted types.
        var reference: Pasteboard?
        guard PasteboardCreate(board.name.rawValue as CFString, &reference) == noErr, let reference else {
            throw FormatError.changedDuringCapture
        }
        PasteboardSynchronize(reference)
        var identifier: PasteboardItemID?
        guard PasteboardGetItemIdentifier(reference, 1, &identifier) == noErr, let identifier else {
            throw FormatError.changedDuringCapture
        }
        var supplied: Set<NSPasteboard.PasteboardType> = []
        for type in offered where type == .string || richTypes.contains(type) {
            var flags: PasteboardFlavorFlags = []
            let status = PasteboardGetItemFlavorFlags(reference, identifier, type.rawValue as CFString, &flags)
            if status == noErr {
                if !flags.contains(.systemTranslated) { supplied.insert(type) }
            } else if status != badPasteboardFlavorErr {
                throw FormatError.changedDuringCapture
            }
        }
        return supplied
    }

    /// May run on a serial background queue inside an autorelease pool.
    static func process(_ snapshot: Snapshot) throws -> ClipPayload? {
        if let urls = snapshot.files { return .files(urls) }
        let plain = snapshot.text.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
        var formats: [String: Data] = [:]
        var extracted: String?
        for type in richTypes {
            guard let data = snapshot.formats[type.rawValue] else { continue }
            if type == .rtfd {
                guard let text = validatedRTFDText(data) else { continue }
                extracted = text
            } else if type == .rtf {
                guard let text = validatedRTFText(data) else { continue }
                if extracted == nil { extracted = text }
            } else if !validHTMLBytes(data) {
                continue
            }
            formats[type.rawValue] = data
        }
        if !formats.isEmpty {
            let text = plain ?? extracted ?? ""
            guard text.utf8.count <= HistoryStore.maxTextBytes else { throw HistoryError.tooLarge }
            return .richText(text: text, formats: formats)
        }
        var imageError: Error? = snapshot.oversizedRepresentation ? HistoryError.tooLarge : nil
        for data in snapshot.images {
            do {
                return try autoreleasepool { () throws -> ClipPayload in
                    let decoded = try decodeImage(data)
                    let png: Data
                    if CGImageSourceGetType(decoded.source) as String? == "public.png" {
                        png = data
                    } else {
                        png = try encodeImage(decoded.image, type: "public.png")
                    }
                    guard png.count <= HistoryStore.maxImageBytes else { throw HistoryError.tooLarge }
                    return .image(png: png, width: decoded.image.width, height: decoded.image.height)
                }
            } catch { imageError = error }
        }
        if let plain { return .text(plain) }
        if let imageError { throw imageError }
        return nil
    }

    static func read(from board: NSPasteboard) throws -> ClipPayload? {
        guard let value = try snapshot(from: board) else { return nil }
        return try process(value)
    }

    /// Read only this entry's sidecar, never construct/share a mutable store.
    static func prepareWrite(_ entry: ClipEntry, directory: URL) throws -> PreparedWrite {
        var items: [[String: Data]] = []
        var fileURLs: [URL] = []
        switch entry.kind {
        case .text:
            guard let text = entry.text, !text.isEmpty else { throw HistoryError.emptyContent }
            guard text.utf8.count <= HistoryStore.maxTextBytes else { throw HistoryError.tooLarge }
            items.append([NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)])
        case .richText:
            let formats = try HistoryStore.richTextFormats(for: entry, directory: directory)
            guard !formats.isEmpty else { throw FormatError.invalidRichText }
            for (type, data) in formats {
                let valid: Bool
                switch type {
                case NSPasteboard.PasteboardType.rtfd.rawValue: valid = validatedRTFDText(data) != nil
                case NSPasteboard.PasteboardType.rtf.rawValue: valid = validatedRTFText(data) != nil
                case NSPasteboard.PasteboardType.html.rawValue: valid = validHTMLBytes(data)
                default: valid = false
                }
                guard valid else { throw FormatError.invalidRichText }
            }
            var item = formats
            if let text = entry.text, !text.isEmpty {
                item[NSPasteboard.PasteboardType.string.rawValue] = Data(text.utf8)
            }
            items.append(item)
        case .image:
            guard let name = entry.imageFilename, name == entry.digest + ".png",
                name.range(of: "^[a-f0-9]{64}\\.png$", options: .regularExpression) != nil
            else { throw HistoryError.invalidImage }
            let parent = directory.appendingPathComponent("images", isDirectory: true)
            let url = parent.appendingPathComponent(name)
            let parentInfo = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard parentInfo.isDirectory == true, parentInfo.isSymbolicLink != true,
                info.isRegularFile == true, info.isSymbolicLink != true,
                let size = info.fileSize, size > 0, size <= HistoryStore.maxImageBytes
            else { throw HistoryError.invalidImage }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try BoundedFileReader.read(from: handle, limit: HistoryStore.maxImageBytes + 1)
            guard data.count <= HistoryStore.maxImageBytes else { throw HistoryError.tooLarge }
            // Stored images have already been decoded at capture. Check the exact
            // persisted bytes and container here without expanding large historical
            // PNGs into pixels again. Earlier releases accepted up to 40 MP.
            var hasher = SHA256()
            hasher.update(data: Data(ClipKind.image.rawValue.utf8))
            hasher.update(data: data)
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard data.count == entry.byteCount, digest == entry.digest, completePNGContainer(data),
                let source = CGImageSourceCreateWithData(
                    data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetType(source) as String? == "public.png",
                CGImageSourceGetCount(source) == 1,
                CGImageSourceGetStatus(source) == .statusComplete,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0, width <= 20_000, height <= 20_000,
                Int64(width) * Int64(height) <= 40_000_000,
                entry.imageWidth == width, entry.imageHeight == height
            else { throw HistoryError.invalidImage }
            var item = [NSPasteboard.PasteboardType.png.rawValue: data]
            // Budget TIFF before decoding. Eight bytes per pixel conservatively
            // covers 16-bit RGBA PNGs; account for row alignment and container overhead.
            // Large old records keep their original PNG flavor without a full decode.
            let estimatedRowBytes = ((width * 8 + 63) / 64) * 64
            let estimatedTIFF = estimatedRowBytes * height + 65_536
            if Int64(width) * Int64(height) <= Int64(HistoryStore.maxImagePixels),
                estimatedTIFF <= maxPreparedWriteBytes - data.count
            {
                let decoded = try decodeImage(data, normalizingPNGOrientation: true)
                let tiff = try encodeImage(decoded.image, type: "public.tiff")
                if tiff.count <= maxPreparedWriteBytes - data.count {
                    item[NSPasteboard.PasteboardType.tiff.rawValue] = tiff
                }
            }
            items.append(item)
        case .files:
            guard let references = entry.fileURLs, !references.isEmpty else { throw FormatError.invalidFiles }
            fileURLs = try references.map { raw in
                guard let url = localFileURL(raw) else { throw FormatError.invalidFiles }
                return url
            }
            try validateFileReferenceSize(fileURLs)
            try validateFilesExist(fileURLs)
            items = fileURLs.map { [NSPasteboard.PasteboardType.fileURL.rawValue: Data($0.absoluteString.utf8)] }
        }
        let bytes = items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        guard bytes <= maxPreparedWriteBytes else { throw HistoryError.tooLarge }
        return PreparedWrite(items: items, fileURLs: fileURLs, byteCount: bytes)
    }

    /// The only mutation stage. Finish validation and setData before clearing.
    static func commit(_ prepared: PreparedWrite, to board: NSPasteboard) throws -> Bool {
        try validateFilesExist(prepared.fileURLs)
        let items = try prepared.items.map { data -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, bytes) in data {
                guard item.setData(bytes, forType: NSPasteboard.PasteboardType(type)) else {
                    throw FormatError.invalidRichText
                }
            }
            guard item.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardPolicy.ownType)) else {
                throw FormatError.invalidRichText
            }
            return item
        }
        guard !items.isEmpty else { return false }
        board.clearContents()
        return board.writeObjects(items)
    }

    static func write(_ entry: ClipEntry, store: HistoryStore, to board: NSPasteboard) throws -> Bool {
        try commit(prepareWrite(entry, directory: store.directory), to: board)
    }

    private static func validateFilesExist(_ urls: [URL]) throws {
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path), FileManager.default.isReadableFile(atPath: url.path)
            else {
                throw FormatError.missingFile(url.lastPathComponent)
            }
        }
    }

    private static func localFileURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= HistoryStore.maxFileReferenceBytes, !raw.contains("\0"),
            let url = URL(string: raw), url.isFileURL,
            url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
            url.user == nil, url.password == nil, url.port == nil,
            url.query == nil, url.fragment == nil, !url.path.contains("\0"), url.path.hasPrefix("/")
        else { return nil }
        return url
    }

    private static func validateFileReferenceSize(_ urls: [URL]) throws {
        guard !urls.isEmpty, urls.count <= HistoryStore.maxFileCount,
            urls.reduce(0, { $0 + $1.absoluteString.utf8.count }) <= HistoryStore.maxFileReferenceBytes
        else {
            throw HistoryError.tooLarge
        }
    }

    /// Strip image/object destinations before the system's text-only parse. Raw
    /// bytes are preserved for the receiving editor; this app never instantiates
    /// embedded objects or follows RTFD attachment paths just to build a title.
    private static func validatedRTFText(_ data: Data) -> String? {
        guard data.count <= HistoryStore.maxRichTextBytes, data.starts(with: Data("{\\rtf".utf8)),
            let textData = textOnlyRTF(data),
            let text = ClipboardDecodeRTFText(textData),
            text.utf8.count <= HistoryStore.maxTextBytes
        else { return nil }
        return text
    }

    private static func textOnlyRTF(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var output = Data()
        var starts: [Int] = []
        var skippingDepth: Int?
        var index = 0
        let excluded: Set<String> = ["pict", "object", "objdata", "nextgraphic", "nonshppict", "shppict"]
        while index < bytes.count {
            let value = bytes[index]
            if value == 123 {  // {
                guard starts.count < 128 else { return nil }
                starts.append(output.count)
                if skippingDepth == nil { output.append(value) }
                index += 1
            } else if value == 125 {  // }
                guard !starts.isEmpty else { return nil }
                if skippingDepth == starts.count {
                    skippingDepth = nil
                } else if skippingDepth == nil {
                    output.append(value)
                }
                starts.removeLast()
                index += 1
            } else if value == 92 {  // backslash; consume escaped braces and binary atomically
                let start = index
                index += 1
                guard index < bytes.count else { return nil }
                func isLetter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }
                if isLetter(bytes[index]) {
                    let wordStart = index
                    while index < bytes.count, isLetter(bytes[index]) { index += 1 }
                    let word = String(decoding: bytes[wordStart..<index], as: UTF8.self).lowercased()
                    let numberStart = index
                    if index < bytes.count, bytes[index] == 45 { index += 1 }
                    while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                    let number = Int(String(decoding: bytes[numberStart..<index], as: UTF8.self))
                    if index < bytes.count, bytes[index] == 32 { index += 1 }
                    if excluded.contains(word) {
                        guard starts.count > 1 else { return nil }
                        if skippingDepth == nil {
                            skippingDepth = starts.count
                            output.removeSubrange(starts.last!..<output.count)
                        }
                    }
                    if word == "bin" {
                        guard let count = number, count >= 0, count <= bytes.count - index else { return nil }
                        index += count
                    }
                } else {
                    if bytes[index] == 39 {  // escaped hex byte \'hh
                        guard index + 2 < bytes.count else { return nil }
                        index += 3
                    } else {
                        index += 1
                    }
                }
                if skippingDepth == nil { output.append(contentsOf: bytes[start..<index]) }
            } else {
                // Only insignificant whitespace may follow the root group.
                if starts.isEmpty, value != 10, value != 13, value != 9, value != 32 { return nil }
                if skippingDepth == nil { output.append(value) }
                index += 1
            }
        }
        guard starts.isEmpty, skippingDepth == nil else { return nil }
        return output
    }

    private static func validatedRTFDText(_ data: Data) -> String? {
        guard data.count <= HistoryStore.maxRichTextBytes,
            let children = FlatRTFDReader.children(
                in: data, maxChildren: maxRTFDAttachments + 1, maxBytes: HistoryStore.maxRichTextBytes)
        else { return nil }
        var rtf: Data?
        var bytes = 0
        var pixels: Int64 = 0
        for (name, content) in children {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                !name.contains("\0"), content.count <= HistoryStore.maxRichTextBytes - bytes
            else { return nil }
            bytes += content.count
            if name.lowercased() == "txt.rtf" {
                guard rtf == nil else { return nil }
                rtf = content
            } else {
                let valid = autoreleasepool { () -> Bool in
                    guard let source = CGImageSourceCreateWithData(content as CFData, nil),
                        let type = CGImageSourceGetType(source) as String?,
                        ["public.png", "public.jpeg", "public.tiff"].contains(type),
                        CGImageSourceGetCount(source) == 1,
                        let info = imageDimensions(source)
                    else { return false }
                    let count = Int64(info.width) * Int64(info.height)
                    guard count <= Int64(HistoryStore.maxImagePixels) - pixels,
                        (try? decodeImage(content)) != nil
                    else { return false }
                    pixels += count
                    return true
                }
                guard valid else { return nil }
            }
        }
        guard let rtf else { return nil }
        return validatedRTFText(rtf)
    }

    private static func validHTMLBytes(_ data: Data) -> Bool {
        let string: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            string = String(data: data, encoding: .utf16)
        } else {
            string = String(data: data, encoding: .utf8)
        }
        guard let string, !string.contains("\0") else { return false }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func imageDimensions(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 20_000, height <= 20_000,
            Int64(width) * Int64(height) <= Int64(HistoryStore.maxImagePixels)
        else { return nil }
        return (width, height)
    }

    private static func decodeImage(_ data: Data, normalizingPNGOrientation: Bool = false) throws -> (
        source: CGImageSource, image: CGImage
    ) {
        guard data.count <= HistoryStore.maxImageBytes else { throw HistoryError.tooLarge }
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let size = imageDimensions(source), CGImageSourceGetStatus(source) == .statusComplete
        else {
            throw HistoryError.invalidImage
        }
        // ImageIO can render truncated PNG data and report a complete first image,
        // even though its container will fail a later paste preflight. Preserve
        // original bytes only when the complete chunk stream reaches IEND.
        if CGImageSourceGetType(source) as String? == "public.png", !completePNGContainer(data) {
            throw HistoryError.invalidImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let image: CGImage?
        if (CGImageSourceGetType(source) as String? != "public.png" || normalizingPNGOrientation),
            (2...8).contains(orientation)
        {
            // Apply EXIF orientation in the first decode, avoiding two full-size buffers.
            image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw HistoryError.invalidImage
        }
        return (source, image)
    }

    /// Validate chunk boundaries without decoding or copying the PNG. ImageIO
    /// still validates pixels; this closes its tolerant truncated-container path.
    private static func completePNGContainer(_ data: Data) -> Bool {
        guard data.count >= 20, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return false }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var offset = 8
            var imageDataBytes = 0
            while offset <= bytes.count - 12 {
                let length =
                    Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                    | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                guard length <= bytes.count - offset - 12 else { return false }
                let type =
                    UInt32(bytes[offset + 4]) << 24 | UInt32(bytes[offset + 5]) << 16
                    | UInt32(bytes[offset + 6]) << 8 | UInt32(bytes[offset + 7])
                if offset == 8 {
                    guard type == 0x4948_4452, length == 13 else { return false }  // IHDR
                } else if type == 0x4948_4452 {
                    return false  // A second header is not a PNG image.
                }
                if type == 0x4944_4154 { imageDataBytes += length }  // IDAT
                if type == 0x4945_4E44 { return length == 0 && imageDataBytes > 0 }  // IEND
                offset += length + 12
            }
            return false
        }
    }

    private static func encodeImage(_ image: CGImage, type: String) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw HistoryError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw HistoryError.invalidImage }
        return data as Data
    }
}
