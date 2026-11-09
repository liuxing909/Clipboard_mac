import Foundation
import Testing
@testable import ClipboardCore

@Suite final class HistoryStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    // One red RGB pixel; PNG chunk CRCs and ImageIO decoding were verified.
    private static let onePixelPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func digestsRemainCompatibleWithExistingHistory() throws {
        let store = try HistoryStore(directory: root)
        let textID = try store.add(.text("你好，World\nline\t2"), sourceApp: "Editor")
        let text = try #require(store.entries.first)
        // Golden values from the original SHA256(kind UTF-8 + payload) format.
        #expect(text.digest == "70f3d19af645b2cf2a708d1c8d55370d4592f045928cf45f5f4885628199f4d5")
        try store.togglePin(textID)
        let imageID = try store.add(.image(png: Self.onePixelPNG, width: 1, height: 1), sourceApp: "Preview")
        let image = try #require(store.entries.first)
        #expect(image.digest == "7871b9610d4b4434ae73c9699d5f9cd3e7a135d33bbb75b92b04c71fa8123752")
        #expect(image.imageFilename == "7871b9610d4b4434ae73c9699d5f9cd3e7a135d33bbb75b92b04c71fa8123752.png")

        let restored = try HistoryStore(directory: root)
        #expect(try restored.add(.text("你好，World\nline\t2"), sourceApp: "Browser") == textID)
        #expect(restored.entries.first?.isPinned == true)
        #expect(try restored.add(.image(png: Self.onePixelPNG, width: 1, height: 1), sourceApp: "Preview") == imageID)
        #expect(restored.entries.count == 2)
        #expect(restored.entries.allSatisfy { $0.copyCount == 2 })
    }

    @Test func unchangedOperationsDoNotRewriteHistory() throws {
        let store = try HistoryStore(directory: root)
        let manifest = root.appendingPathComponent("history.json")
        try store.remove(UUID())
        try store.clear()
        try store.clear(keepingPinned: false)
        try store.applyLimit(100)
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
        #expect(store.maxItems == 100)

        let pinned = try store.add(.image(png: Self.onePixelPNG, width: 1, height: 1), sourceApp: "Preview")
        try store.togglePin(pinned)
        let original = try Data(contentsOf: manifest)
        let oldDate = Date(timeIntervalSince1970: 946_684_800)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: manifest.path)

        try store.remove(UUID())
        try store.clear()
        try store.applyLimit(100)
        try store.applyLimit(1)
        let attributes = try FileManager.default.attributesOfItem(atPath: manifest.path)
        #expect(attributes[.modificationDate] as? Date == oldDate)
        #expect(try Data(contentsOf: manifest) == original)
        #expect(store.maxItems == 1)
        #expect(try HistoryStore(directory: root).entries == store.entries)
        let imageURL = try #require(store.imageURL(for: store.entries[0]))
        #expect(try Data(contentsOf: imageURL) == Self.onePixelPNG)

        // The in-memory limit changes even though no manifest write was needed.
        #expect(throws: HistoryError.self) { try store.add(.text("cannot displace pinned image"), sourceApp: "Editor") }
        #expect(store.entries.map(\.id) == [pinned])
    }

    @Test func changedLimitPersistsEvictionAndCleansImages() throws {
        let store = try HistoryStore(directory: root, maxItems: 4)
        let pinned = try store.add(.text("pinned"), sourceApp: "Editor")
        try store.togglePin(pinned)
        try store.add(.image(png: Self.onePixelPNG, width: 1, height: 1), sourceApp: "Preview")
        let oldImage = try #require(store.imageURL(for: store.entries[0]))
        let newest = try store.add(.text("newest"), sourceApp: "Editor")

        try store.applyLimit(2)
        #expect(store.maxItems == 2)
        #expect(store.entries.map(\.id) == [newest, pinned])
        #expect(!FileManager.default.fileExists(atPath: oldImage.path))
        #expect(try HistoryStore(directory: root).entries == store.entries)

        let next = try store.add(.text("next"), sourceApp: "Editor")
        #expect(store.entries.map(\.id) == [next, pinned])
        #expect(try HistoryStore(directory: root).entries == store.entries)
    }

    @Test func unchangedOperationsRecoverOrphanAfterFailedImageCapture() throws {
        for operation in ["remove", "clear", "limit"] {
            let directory = root.appendingPathComponent(operation, isDirectory: true)
            let store = try HistoryStore(directory: directory)
            let manifest = directory.appendingPathComponent("history.json")
            let images = directory.appendingPathComponent("images")
            // Block the manifest write after the PNG has been saved. This is
            // deterministic and does not depend on filesystem permission rules.
            try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) {
                try store.add(.image(png: Self.onePixelPNG, width: 1, height: 1), sourceApp: "Preview")
            }
            #expect(store.entries.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: images.path).count == 1)
            try FileManager.default.removeItem(at: manifest)

            switch operation {
            case "remove": try store.remove(UUID())
            case "clear": try store.clear(keepingPinned: false)
            default: try store.applyLimit(100)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: images.path).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: manifest.path))
            #expect(store.entries.isEmpty)
        }
    }

    @Test func duplicatePreservesPinAndPersists() throws {
        let store = try HistoryStore(directory: root)
        let id = try store.add(.text("你好，World"), sourceApp: "Editor", at: Date(timeIntervalSince1970: 1))
        try store.togglePin(id)
        try store.add(.text("other"), sourceApp: "Browser", at: Date(timeIntervalSince1970: 2))
        let same = try store.add(.text("你好，World"), sourceApp: "Terminal", at: Date(timeIntervalSince1970: 3))
        #expect(id == same)
        let restored = try HistoryStore(directory: root)
        #expect(restored.entries.count == 2)
        #expect(restored.entries[0].isPinned)
        #expect(restored.entries[0].copyCount == 2)
        #expect(restored.entries[0].sourceApp == "Terminal")
        #expect(restored.matching("world").count == 1)
    }

    @Test func evictionPreservesPinnedItems() throws {
        let store = try HistoryStore(directory: root, maxItems: 2)
        let first = try store.add(.text("pinned"), sourceApp: "Test")
        try store.togglePin(first)
        try store.add(.text("old"), sourceApp: "Test")
        try store.add(.text("new"), sourceApp: "Test")
        #expect(Set(store.entries.compactMap(\.text)) == ["pinned", "new"])
        try store.clear()
        #expect(store.entries.map(\.id) == [first])
        try store.clear(keepingPinned: false)
        #expect(store.entries.isEmpty)
    }

    @Test func imageLifecycleAndKindFiltering() throws {
        let store = try HistoryStore(directory: root)
        let png = Self.onePixelPNG
        let id = try store.add(.image(png: png, width: 1, height: 1), sourceApp: "Preview")
        let entry = try #require(store.entries.first)
        let image = try #require(store.imageURL(for: entry))
        #expect(try Data(contentsOf: image) == png)
        try store.add(.text("text"), sourceApp: "Editor")
        #expect(store.matching("", kind: .image).map(\.id) == [id])
        let restored = try HistoryStore(directory: root)
        #expect(restored.entries.count == 2)
        try restored.remove(id)
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }

    @Test func recopyRepairsMissingImageAndPreservesEntry() throws {
        let store = try HistoryStore(directory: root)
        let png = Self.onePixelPNG
        let payload = ClipPayload.image(png: png, width: 1, height: 1)
        let id = try store.add(payload, sourceApp: "Preview", at: Date(timeIntervalSince1970: 1))
        try store.togglePin(id)
        let original = try #require(store.entries.first)
        let image = try #require(store.imageURL(for: original))
        try store.add(.text("another record"), sourceApp: "Editor", at: Date(timeIntervalSince1970: 2))
        try FileManager.default.removeItem(at: image)
        #expect(!FileManager.default.fileExists(atPath: image.path))

        let recopied = try store.add(payload, sourceApp: "Browser", at: Date(timeIntervalSince1970: 3))
        #expect(recopied == id)
        #expect(try Data(contentsOf: image) == png)
        let repaired = try #require(store.entries.first)
        #expect(repaired.id == id)
        #expect(repaired.isPinned)
        #expect(repaired.createdAt == original.createdAt)
        #expect(repaired.copyCount == 2)
        #expect(repaired.sourceApp == "Browser")
        #expect(store.entries.count == 2)

        let restored = try HistoryStore(directory: root)
        #expect(restored.entries == store.entries)
        let restoredImage = try #require(restored.imageURL(for: repaired))
        #expect(try Data(contentsOf: restoredImage) == png)
    }

    @Test func byteBudgetAndInvalidInputs() throws {
        let store = try HistoryStore(directory: root, maxBytes: 10)
        try store.add(.text("123456"), sourceApp: "Test")
        try store.add(.text("abcdef"), sourceApp: "Test")
        #expect(store.entries.compactMap(\.text) == ["abcdef"])
        #expect(throws: HistoryError.self) { try store.add(.text(""), sourceApp: "Test") }
        #expect(throws: HistoryError.self) {
            try store.add(.text(String(repeating: "a", count: HistoryStore.maxTextBytes + 1)), sourceApp: "Test")
        }
        #expect(throws: HistoryError.self) {
            try store.add(.image(png: Data([0]), width: 1, height: 1), sourceApp: "Test")
        }
    }

    @Test func capacityFailurePreservesExistingHistory() throws {
        let store = try HistoryStore(directory: root, maxBytes: 10)
        let pinned = try store.add(.text("12345678"), sourceApp: "Test")
        try store.togglePin(pinned)
        try store.add(.text("ok"), sourceApp: "Test")
        let before = store.entries
        let manifest = root.appendingPathComponent("history.json")
        let saved = try Data(contentsOf: manifest)

        do {
            try store.add(.text("new"), sourceApp: "Test")
            Issue.record("A capture that cannot fit beside pinned records must fail")
        } catch HistoryError.capacityExceeded {}
        #expect(store.entries == before)
        #expect(try Data(contentsOf: manifest) == saved)
        #expect(try HistoryStore(directory: root, maxBytes: 10).entries == before)

        // Recopying existing content requires no extra capacity and still works.
        #expect(try store.add(.text("12345678"), sourceApp: "Test") == pinned)
        #expect(store.entries.first?.copyCount == 2)
    }

    @Test func rejectedImageDoesNotCreateOrphanFile() throws {
        let png = Self.onePixelPNG
        let store = try HistoryStore(directory: root, maxBytes: png.count)
        let pinned = try store.add(.text(String(repeating: "a", count: png.count - 1)), sourceApp: "Test")
        try store.togglePin(pinned)
        try store.add(.text("x"), sourceApp: "Test")
        let before = store.entries

        do {
            try store.add(.image(png: png, width: 1, height: 1), sourceApp: "Test")
            Issue.record("An image exceeding the remaining capacity must fail")
        } catch HistoryError.capacityExceeded {}
        #expect(store.entries == before)
        #expect(try HistoryStore(directory: root, maxBytes: png.count).entries == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("images").path).isEmpty)
    }

    @Test func payloadLargerThanStoreBudgetDoesNotEraseHistory() throws {
        let store = try HistoryStore(directory: root, maxBytes: 4)
        try store.add(.text("old"), sourceApp: "Test")
        let before = store.entries
        do {
            try store.add(.text("12345"), sourceApp: "Test")
            Issue.record("A payload larger than the total budget must fail")
        } catch HistoryError.capacityExceeded {}
        #expect(store.entries == before)
        #expect(try HistoryStore(directory: root, maxBytes: 4).entries == before)
    }

    @Test func corruptHistoryIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("history.json")
        let original = Data("broken history".utf8)
        try original.write(to: file)
        #expect(throws: HistoryError.self) { try HistoryStore(directory: root) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func sensitiveAndOwnClipboardTypesAreIgnored() {
        #expect(ClipboardPolicy.shouldIgnore(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(ClipboardPolicy.shouldIgnore(types: [ClipboardPolicy.ownType]))
        #expect(!ClipboardPolicy.shouldIgnore(types: ["public.png"]))
    }

    @Test func searchMatchesSourceAndPinnedOrdering() throws {
        let store = try HistoryStore(directory: root)
        let older = try store.add(.text("command"), sourceApp: "Terminal", at: Date(timeIntervalSince1970: 1))
        try store.togglePin(older)
        try store.add(.text("note"), sourceApp: "Notes", at: Date(timeIntervalSince1970: 2))
        #expect(store.matching("").first?.id == older)
        #expect(store.matching("TERMINAL").first?.id == older)
        #expect(store.matching("missing").isEmpty)
    }

    @Test func versionOneHistoryMigratesOnNextCommit() throws {
        let store = try HistoryStore(directory: root)
        let textID = try store.add(.text("旧版本记录"), sourceApp: "Editor")
        try store.togglePin(textID)
        try store.add(.image(png: Self.onePixelPNG, width: 1, height: 1), sourceApp: "Preview")
        let manifest = root.appendingPathComponent("history.json")
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var records = try #require(document["entries"] as? [[String: Any]])
        for index in records.indices {
            for key in ["richTextFilename", "richTextTypes", "fileURLs"] { records[index].removeValue(forKey: key) }
        }
        document["entries"] = records
        document["version"] = 1
        let oldBytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try oldBytes.write(to: manifest)

        let migrated = try HistoryStore(directory: root)
        #expect(migrated.entries == store.entries)
        #expect(try Data(contentsOf: manifest) == oldBytes)  // Loading is read-only.
        #expect(try migrated.add(.text("旧版本记录"), sourceApp: "Editor") == textID)
        #expect(migrated.entries.first?.isPinned == true)
        let current = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        #expect(current["version"] as? Int == 2)
        #expect(try HistoryStore(directory: root).entries == migrated.entries)
    }

    @Test func unknownVersionIsRejectedBeforeUnknownKindAndPreservesFile() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("history.json")
        let original = Data(#"{"version":99,"entries":[{"kind":"future-kind"}]}"#.utf8)
        try original.write(to: manifest)
        do {
            _ = try HistoryStore(directory: root)
            Issue.record("A future schema must be rejected")
        } catch HistoryError.unsupportedVersion {}
        #expect(try Data(contentsOf: manifest) == original)
    }

    @Test func richTextPreservesExactRepresentationsAcrossRestart() throws {
        let store = try HistoryStore(directory: root)
        let formats = [
            "public.rtf": Data(#"{\rtf1\ansi plain \b bold\b0}"#.utf8),
            "public.html": Data("<meta charset=\"utf-8\"><p>你好 <b>bold</b></p>\r\n".utf8),
        ]
        let id = try store.add(.richText(text: "你好 bold", formats: formats), sourceApp: "Word")
        try store.togglePin(id)
        let entry = try #require(store.entries.first)
        #expect(entry.kind == .richText)
        #expect(entry.richTextTypes == ["public.html", "public.rtf"])
        #expect(entry.byteCount == formats.values.reduce(0, { $0 + $1.count }) + "你好 bold".utf8.count)
        #expect(try store.richTextFormats(for: entry) == formats)
        let sidecar = root.appendingPathComponent("richtext").appendingPathComponent(
            try #require(entry.richTextFilename))
        #expect(try Data(contentsOf: sidecar).starts(with: Data("bplist00".utf8)))
        let manifest = try Data(contentsOf: root.appendingPathComponent("history.json"))
        let record = try #require(
            (JSONSerialization.jsonObject(with: manifest) as? [String: Any])?["entries"] as? [[String: Any]])[0]
        #expect(record["formats"] == nil)
        #expect(record["richTextFilename"] as? String == entry.richTextFilename)

        let restored = try HistoryStore(directory: root)
        #expect(restored.entries == store.entries)
        #expect(try restored.richTextFormats(for: restored.entries[0]) == formats)
        #expect(try restored.add(.richText(text: "你好 bold", formats: formats), sourceApp: "Browser") == id)
        #expect(restored.entries[0].isPinned)
        #expect(restored.entries[0].copyCount == 2)
    }

    @Test func rtfdPreservesBytesAndUpgradesOnlyWhenNeeded() throws {
        let store = try HistoryStore(directory: root)
        try store.add(.text("previous version text"), sourceApp: "Editor")
        let manifest = root.appendingPathComponent("history.json")
        func version() throws -> Int? {
            (try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])?["version"] as? Int
        }
        #expect(try version() == 2)
        // The Core layer stores exact opaque bytes. AppKit validation is covered
        // by named-pasteboard integration tests, without reading user data.
        let rtfd = Data([0x72, 0x74, 0x66, 0x64, 0, 1, 2, 0xff])
        let formats = [
            HistoryStore.rtfdType: rtfd,
            "public.rtf": Data(#"{\rtf1 rich text}"#.utf8),
            "public.html": Data("<b>rich text</b>".utf8),
        ]
        let id = try store.add(.richText(text: "rich text", formats: formats), sourceApp: "Word")
        try store.togglePin(id)
        let entry = try #require(store.entries.first)
        #expect(try version() == 3)
        #expect(try HistoryStore.richTextFormats(for: entry, directory: root) == formats)
        let sidecar = root.appendingPathComponent("richtext").appendingPathComponent(
            try #require(entry.richTextFilename))
        let payload = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: sidecar), format: nil) as? [String: Any])
        #expect(payload["version"] as? Int == 2)
        let original = try Data(contentsOf: manifest)
        let restored = try HistoryStore(directory: root)
        #expect(try Data(contentsOf: manifest) == original)
        #expect(restored.entries == store.entries)
        #expect(try restored.richTextFormats(for: entry) == formats)
        #expect(try restored.add(.richText(text: "rich text", formats: formats), sourceApp: "Pages") == id)
        #expect(restored.entries[0].isPinned)
        #expect(restored.entries[0].copyCount == 2)

        // A manifest cannot claim the older schema while smuggling a new type.
        var downgraded = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        downgraded["version"] = 2
        let invalid = try JSONSerialization.data(withJSONObject: downgraded)
        try invalid.write(to: manifest)
        #expect(throws: HistoryError.self) { try HistoryStore(directory: root) }
        #expect(try Data(contentsOf: manifest) == invalid)
        try original.write(to: manifest)
        try restored.remove(id)
        #expect(try version() == 2)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func rtfdSharesRichTextBudgetAndPreservesHistoryOnRejection() throws {
        let store = try HistoryStore(directory: root)
        try store.add(.text("keep"), sourceApp: "Editor")
        let before = store.entries
        let manifest = root.appendingPathComponent("history.json")
        let bytes = try Data(contentsOf: manifest)
        let cases: [ClipPayload] = [
            .richText(
                text: "", formats: [HistoryStore.rtfdType: Data(repeating: 1, count: HistoryStore.maxRichTextBytes + 1)]
            ),
            .richText(
                text: "",
                formats: [
                    HistoryStore.rtfdType: Data(repeating: 1, count: HistoryStore.maxRichTextBytes),
                    "public.rtf": Data([1]),
                ]),
            .richText(
                text: String(repeating: "x", count: HistoryStore.maxTextBytes + 1),
                formats: [HistoryStore.rtfdType: Data([1])]),
        ]
        for payload in cases { #expect(throws: HistoryError.self) { try store.add(payload, sourceApp: "Word") } }
        #expect(store.entries == before)
        #expect(try Data(contentsOf: manifest) == bytes)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("richtext").path).isEmpty)
        let boundary = [HistoryStore.rtfdType: Data(repeating: 1, count: HistoryStore.maxRichTextBytes)]
        try store.add(.richText(text: "", formats: boundary), sourceApp: "Word")
        #expect(try store.richTextFormats(for: store.entries[0]) == boundary)
    }

    @Test func imagePixelBudgetRejectsBeforeCreatingSidecars() throws {
        let store = try HistoryStore(directory: root)
        try store.add(.text("keep"), sourceApp: "Editor")
        let before = store.entries
        #expect(throws: HistoryError.self) {
            try store.add(.image(png: Self.onePixelPNG, width: 4_001, height: 4_000), sourceApp: "Preview")
        }
        #expect(store.entries == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("images").path).isEmpty)
    }

    @Test func richTextDeduplicationIncludesFormatsAndFallback() throws {
        let store = try HistoryStore(directory: root)
        let regular = ["public.rtf": Data(#"{\rtf1 same}"#.utf8)]
        let bold = ["public.rtf": Data(#"{\rtf1\b same}"#.utf8)]
        let plain = try store.add(.text("same"), sourceApp: "Editor")
        let first = try store.add(.richText(text: "same", formats: regular), sourceApp: "Editor")
        let second = try store.add(.richText(text: "same", formats: bold), sourceApp: "Editor")
        let third = try store.add(
            .richText(text: "same", formats: ["public.html": Data("<b>same</b>".utf8)]), sourceApp: "Browser")
        #expect(Set([plain, first, second, third]).count == 4)
        #expect(try store.add(.richText(text: "same", formats: regular), sourceApp: "Editor") == first)
        let noFallback = try store.add(
            .richText(text: "", formats: ["public.html": Data("<b>same</b>".utf8)]), sourceApp: "Browser")
        #expect(noFallback != third)
        #expect(store.entries[0].title == "富文本内容")
        #expect(store.entries[0].text == "")
        #expect(try HistoryStore(directory: root).entries == store.entries)
        #expect(store.matching("same", kind: .richText).count == 3)
    }

    @Test func richTextLimitsRejectWithoutChangingHistory() throws {
        let store = try HistoryStore(directory: root)
        try store.add(.text("keep me"), sourceApp: "Editor")
        let before = store.entries
        let manifest = root.appendingPathComponent("history.json")
        let original = try Data(contentsOf: manifest)
        let cases: [ClipPayload] = [
            .richText(text: "", formats: [:]),
            .richText(text: "text", formats: ["public.rtf": Data()]),
            .richText(text: "text", formats: ["unknown/type": Data([1])]),
            .richText(
                text: String(repeating: "x", count: HistoryStore.maxTextBytes + 1), formats: ["public.rtf": Data([1])]),
            .richText(
                text: "",
                formats: [
                    "public.rtf": Data(repeating: 1, count: HistoryStore.maxRichTextBytes), "public.html": Data([2]),
                ]),
        ]
        for payload in cases { #expect(throws: HistoryError.self) { try store.add(payload, sourceApp: "Editor") } }
        #expect(store.entries == before)
        #expect(try Data(contentsOf: manifest) == original)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("richtext").path).isEmpty)

        let boundary = ["public.html": Data(repeating: 32, count: HistoryStore.maxRichTextBytes)]
        try store.add(.richText(text: "", formats: boundary), sourceApp: "Browser")
        #expect(try store.richTextFormats(for: store.entries[0]) == boundary)
    }

    @Test func richTextCorruptionIsDetectedAndRecopyRepairs() throws {
        let store = try HistoryStore(directory: root)
        let formats = ["public.rtf": Data(#"{\rtf1 preserved}"#.utf8)]
        let payload = ClipPayload.richText(text: "preserved", formats: formats)
        let id = try store.add(payload, sourceApp: "Editor")
        try store.togglePin(id)
        let entry = try #require(store.entries.first)
        let sidecar = root.appendingPathComponent("richtext").appendingPathComponent(
            try #require(entry.richTextFilename))

        // Well-formed plist with altered bytes must fail the digest check too.
        let tampered: [String: Any] = ["version": 1, "formats": ["public.rtf": Data(#"{\rtf1 corrupted}"#.utf8)]]
        try PropertyListSerialization.data(fromPropertyList: tampered, format: .binary, options: 0).write(to: sidecar)
        #expect(throws: HistoryError.self) { try store.richTextFormats(for: entry) }
        let reopened = try HistoryStore(directory: root)
        #expect(reopened.entries == store.entries)
        #expect(throws: HistoryError.self) { try reopened.richTextFormats(for: entry) }
        #expect(try reopened.add(payload, sourceApp: "Editor") == id)
        #expect(try reopened.richTextFormats(for: reopened.entries[0]) == formats)
        #expect(reopened.entries[0].isPinned)

        try FileManager.default.removeItem(at: sidecar)
        #expect(throws: HistoryError.self) { try reopened.richTextFormats(for: entry) }
        #expect(try reopened.add(payload, sourceApp: "Editor") == id)
        #expect(try reopened.richTextFormats(for: reopened.entries[0]) == formats)
    }

    @Test func richTextTraversalAndSymlinksCannotReadExternalData() throws {
        let store = try HistoryStore(directory: root)
        try store.add(
            .richText(text: "text", formats: ["public.rtf": Data(#"{\rtf1 text}"#.utf8)]), sourceApp: "Editor")
        let entry = try #require(store.entries.first)
        let manifest = root.appendingPathComponent("history.json")
        let original = try Data(contentsOf: manifest)
        var document = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var records = try #require(document["entries"] as? [[String: Any]])
        records[0]["richTextFilename"] = "../outside.plist"
        document["entries"] = records
        let unsafe = try JSONSerialization.data(withJSONObject: document)
        try unsafe.write(to: manifest)
        #expect(throws: HistoryError.self) { try HistoryStore(directory: root) }
        #expect(try Data(contentsOf: manifest) == unsafe)
        try original.write(to: manifest)

        let sidecar = root.appendingPathComponent("richtext").appendingPathComponent(
            try #require(entry.richTextFilename))
        let outside = root.appendingPathComponent("outside.plist")
        let bytes = try Data(contentsOf: sidecar)
        try bytes.write(to: outside)
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
        #expect(throws: HistoryError.self) { try store.richTextFormats(for: entry) }
        try store.clear(keepingPinned: false)
        #expect(try Data(contentsOf: outside) == bytes)
    }

    @Test func richTextEvictionAndFailedCommitCleanupPreservePinnedData() throws {
        let store = try HistoryStore(directory: root, maxItems: 2)
        let first = try store.add(
            .richText(text: "pinned", formats: ["public.rtf": Data(#"{\rtf1 pinned}"#.utf8)]), sourceApp: "Editor")
        try store.togglePin(first)
        let pinned = try #require(store.entries.first)
        try store.add(.richText(text: "old", formats: ["public.html": Data("<p>old</p>".utf8)]), sourceApp: "Browser")
        let old = root.appendingPathComponent("richtext").appendingPathComponent(
            try #require(store.entries[0].richTextFilename))
        try store.add(.text("new"), sourceApp: "Editor")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try store.richTextFormats(for: pinned)["public.rtf"] != nil)
        try store.clear()
        #expect(store.entries.map(\.id) == [first])

        let blockedRoot = root.appendingPathComponent("blocked")
        let blocked = try HistoryStore(directory: blockedRoot)
        let manifest = blockedRoot.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try blocked.add(
                .richText(text: "failed", formats: ["public.html": Data("<p>failed</p>".utf8)]), sourceApp: "Editor")
        }
        let sidecars = blockedRoot.appendingPathComponent("richtext")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sidecars.path).count == 1)
        #expect(blocked.entries.isEmpty)
        try FileManager.default.removeItem(at: manifest)
        try blocked.remove(UUID())
        #expect(try FileManager.default.contentsOfDirectory(atPath: sidecars.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test func fileReferencesPreserveOrderDeduplicateAndNeverTouchOriginals() throws {
        let store = try HistoryStore(directory: root)
        let first = root.appendingPathComponent("原始文稿.txt")
        let folder = root.appendingPathComponent("资料", isDirectory: true)
        let missing = root.appendingPathComponent("已经删除.pdf")
        try Data("original bytes".utf8).write(to: first)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let id = try store.add(.files([first, folder, first, missing]), sourceApp: "Finder")
        let entry = try #require(store.entries.first)
        #expect(entry.kind == .files)
        #expect(entry.fileURLs == [first, folder, missing].map { $0.standardizedFileURL.absoluteString })
        #expect(entry.title == "原始文稿.txt\n资料\n已经删除.pdf")
        #expect(store.matching("文稿", kind: .files).map(\.id) == [id])
        #expect(try store.add(.files([first, folder, missing]), sourceApp: "Finder") == id)
        let reversed = try store.add(.files([missing, folder, first]), sourceApp: "Finder")
        #expect(reversed != id)
        let restored = try HistoryStore(directory: root)
        #expect(restored.entries == store.entries)
        try restored.clear(keepingPinned: false)
        #expect(try Data(contentsOf: first) == Data("original bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func invalidFileReferencesAndLimitsAreRejectedAtomically() throws {
        let store = try HistoryStore(directory: root)
        try store.add(.text("untouched"), sourceApp: "Editor")
        let before = store.entries
        let cases: [[URL]] = [
            [], [URL(string: "https://example.com/a")!], [URL(string: "file://remote-host/share/a")!],
            [URL(string: "file:///tmp/a?query=value")!], [URL(string: "file:///tmp/a#fragment")!],
            (0...HistoryStore.maxFileCount).map { root.appendingPathComponent("file-\($0)") },
            [URL(fileURLWithPath: "/" + String(repeating: "x", count: HistoryStore.maxFileReferenceBytes))],
        ]
        for urls in cases { #expect(throws: HistoryError.self) { try store.add(.files(urls), sourceApp: "Finder") } }
        #expect(store.entries == before)
        #expect(try HistoryStore(directory: root).entries == before)
        let boundary = (0..<HistoryStore.maxFileCount).map { root.appendingPathComponent("file-\($0)") }
        try store.add(.files(boundary), sourceApp: "Finder")
        #expect(store.entries[0].fileURLs?.count == HistoryStore.maxFileCount)
    }
}
