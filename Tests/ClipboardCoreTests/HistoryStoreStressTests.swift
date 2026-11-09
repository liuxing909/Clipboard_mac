import Foundation
import Testing
@testable import ClipboardCore

@Suite final class HistoryStoreStressTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func recopyCounterSaturatesAtIntegerLimit() throws {
        let store = try HistoryStore(directory: root)
        let id = try store.add(.text("same content"), sourceApp: "Stress")
        try mutateManifest { $0[0]["copyCount"] = Int.max }
        let reopened = try HistoryStore(directory: root)
        #expect(try reopened.add(.text("same content"), sourceApp: "Recopy") == id)
        #expect(reopened.entries.first?.copyCount == Int.max)
        #expect(reopened.entries.first?.sourceApp == "Recopy")
        #expect(try HistoryStore(directory: root).entries == reopened.entries)
    }

    @Test func corruptManifestMetadataIsRejectedWithoutRewrite() throws {
        let store = try HistoryStore(directory: root)
        try store.add(.text("first"), sourceApp: "Stress")
        try store.add(.text("second"), sourceApp: "Stress")
        let manifest = root.appendingPathComponent("history.json")
        let baseline = try Data(contentsOf: manifest)
        let mutations: [([[String: Any]]) -> [[String: Any]]] = [
            {
                var r = $0; r[0]["byteCount"] = Int.max; return r
            },
            {
                var r = $0; r[0]["copyCount"] = -1; return r
            },
            {
                var r = $0; r[0]["copyCount"] = 0; return r
            },
            {
                var r = $0; r[0]["text"] = "changed without matching digest"; return r
            },
            {
                var r = $0; r[0]["id"] = r[1]["id"]; return r
            },
            {
                var r = $0; r.append(r[0]); return r
            },
        ]
        for version in 1...3 {
            for mutation in mutations {
                try baseline.write(to: manifest)
                try mutateManifest(version: version) { $0 = mutation($0) }
                let corrupted = try Data(contentsOf: manifest)
                #expect(throws: HistoryError.self) { try HistoryStore(directory: root) }
                #expect(try Data(contentsOf: manifest) == corrupted)
            }
        }
    }

    @Test func replacedImageDirectoryCannotWriteOrDeleteExternalFiles() throws {
        for action in ["cleanup", "capture"] {
            let directory = root.appendingPathComponent(action)
            let store = try HistoryStore(directory: directory)
            let images = directory.appendingPathComponent("images")
            let outside = directory.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let sentinel = outside.appendingPathComponent(String(repeating: "a", count: 64) + ".png")
            let sentinelBytes = Data("must stay unchanged".utf8)
            try sentinelBytes.write(to: sentinel)
            try FileManager.default.removeItem(at: images)
            try FileManager.default.createSymbolicLink(at: images, withDestinationURL: outside)
            if action == "cleanup" {
                try store.clear(keepingPinned: false)
            } else {
                #expect(throws: HistoryError.self) {
                    try store.add(.image(png: Self.png, width: 1, height: 1), sourceApp: "Stress")
                }
                #expect(store.entries.isEmpty)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == [sentinel.lastPathComponent])
            #expect(try Data(contentsOf: sentinel) == sentinelBytes)
            #expect(throws: HistoryError.self) { try HistoryStore(directory: directory) }
        }
    }

    @Test func recopyRepairsCorruptedImageAndPreservesEntry() throws {
        let store = try HistoryStore(directory: root)
        let payload = ClipPayload.image(png: Self.png, width: 1, height: 1)
        let id = try store.add(payload, sourceApp: "Stress")
        try store.togglePin(id)
        let original = try #require(store.entries.first)
        let file = try #require(store.imageURL(for: original))
        var corrupt = Self.png
        corrupt[corrupt.count - 1] ^= 1
        try corrupt.write(to: file)
        #expect(try store.add(payload, sourceApp: "Recopy") == id)
        #expect(try Data(contentsOf: file) == Self.png)
        #expect(store.entries.first?.isPinned == true)
        #expect(store.entries.first?.createdAt == original.createdAt)
        #expect(store.entries.first?.copyCount == 2)
        #expect(try HistoryStore(directory: root).entries == store.entries)
    }

    @Test func recopyRepairsImageMetadataFromFreshPayload() throws {
        let store = try HistoryStore(directory: root)
        let payload = ClipPayload.image(png: Self.png, width: 1, height: 1)
        let id = try store.add(payload, sourceApp: "Original", at: Date(timeIntervalSince1970: 1))
        try store.togglePin(id)
        let original = try #require(store.entries.first)
        // These values remain within the supported range, so header-only
        // validation cannot know that they disagree with the saved PNG.
        try mutateManifest {
            $0[0]["imageWidth"] = 2
            $0[0]["imageHeight"] = 3
            $0[0]["byteCount"] = Self.png.count + 1
        }
        let reopened = try HistoryStore(directory: root)
        #expect(reopened.entries.first?.imageWidth == 2)
        #expect(try reopened.add(payload, sourceApp: "Fresh copy", at: Date(timeIntervalSince1970: 2)) == id)
        let repaired = try #require(reopened.entries.first)
        #expect(repaired.imageWidth == 1 && repaired.imageHeight == 1)
        #expect(repaired.byteCount == Self.png.count)
        #expect(repaired.id == original.id && repaired.createdAt == original.createdAt && repaired.isPinned)
        #expect(repaired.copyCount == 2 && repaired.sourceApp == "Fresh copy")
        #expect(try Data(contentsOf: #require(reopened.imageURL(for: repaired))) == Self.png)
        #expect(try HistoryStore(directory: root).entries == reopened.entries)
    }

    @Test func recopyRepairsRichTextMetadataFromFreshPayload() throws {
        let store = try HistoryStore(directory: root)
        let text = "rich content"
        let formats = ["public.rtf": Data(#"{\rtf1 rich content}"#.utf8)]
        let payload = ClipPayload.richText(text: text, formats: formats)
        let id = try store.add(payload, sourceApp: "Original", at: Date(timeIntervalSince1970: 1))
        try store.togglePin(id)
        let original = try #require(store.entries.first)
        try mutateManifest {
            $0[0]["byteCount"] = original.byteCount + 1
            $0[0]["text"] = "corrupted summary"
            $0[0]["richTextTypes"] = ["public.html"]
        }
        let reopened = try HistoryStore(directory: root)
        let broken = try #require(reopened.entries.first)
        #expect(throws: HistoryError.self) { try reopened.richTextFormats(for: broken) }
        #expect(try reopened.add(payload, sourceApp: "Fresh copy", at: Date(timeIntervalSince1970: 2)) == id)
        let repaired = try #require(reopened.entries.first)
        #expect(repaired.byteCount == original.byteCount)
        #expect(repaired.text == text && repaired.richTextTypes == ["public.rtf"])
        #expect(repaired.id == original.id && repaired.createdAt == original.createdAt && repaired.isPinned)
        #expect(repaired.copyCount == 2 && repaired.sourceApp == "Fresh copy")
        #expect(try reopened.richTextFormats(for: repaired) == formats)
        #expect(try HistoryStore(directory: root).entries == reopened.entries)
    }

    @Test func oversizedSparseManifestIsRejectedBeforeReading() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("history.json")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        // A sparse file has a large logical size without filling disk or RAM.
        let logicalSize = UInt64(HistoryStore.defaultMaxManifestBytes) + 1
        try handle.truncate(atOffset: logicalSize)
        #expect(throws: HistoryError.self) { try HistoryStore(directory: root) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.size] as? NSNumber)?.uint64Value == logicalSize)
    }

    @Test func manifestBudgetRejectsWritesAndReadsWithoutChangingHistory() throws {
        let limit = 2_048
        let store = try HistoryStore(directory: root, maxManifestBytes: limit)
        try store.add(.text("original"), sourceApp: "Stress")
        let original = store.entries
        let file = root.appendingPathComponent("history.json")
        let bytes = try Data(contentsOf: file)
        // Valid clipboard payloads whose JSON representation exceeds the budget.
        let attempts: [(String, String)] = [
            (String(repeating: "\u{0001}", count: 400), "Stress"),
            ("new content", String(repeating: "x", count: limit + 1)),
        ]
        for (text, source) in attempts {
            do {
                try store.add(.text(text), sourceApp: source)
                Issue.record("A serialized manifest over budget must not be committed")
            } catch HistoryError.manifestTooLarge {}
            #expect(store.entries == original)
            #expect(try Data(contentsOf: file) == bytes)
        }
        #expect(try HistoryStore(directory: root, maxManifestBytes: limit).entries == original)
        #expect(throws: HistoryError.self) {
            try HistoryStore(directory: root, maxManifestBytes: bytes.count - 1)
        }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try HistoryStore(directory: root, maxManifestBytes: bytes.count).entries == original)
    }

    @Test func excludedDigestsNeverUpdateHistoryOrRecreateDeletedSidecars() throws {
        let store = try HistoryStore(directory: root)
        let keeper = try store.add(.text("surviving pinned record"), sourceApp: "Original")
        try store.togglePin(keeper)
        let originalFile = root.appendingPathComponent("original.txt")
        let originalBytes = Data("referenced file stays unchanged".utf8)
        try originalBytes.write(to: originalFile)
        let payloads: [ClipPayload] = [
            .text("discarded text 中文"),
            .image(png: Self.png, width: 1, height: 1),
            .richText(text: "formatted", formats: ["public.html": Data("<b>formatted</b>".utf8)]),
            .files([originalFile]),
        ]
        let manifest = root.appendingPathComponent("history.json")

        func expectExcluded(_ payload: ClipPayload, digest: String) throws {
            let before = store.entries
            let diskBefore = try Data(contentsOf: manifest)
            let folders = ["images", "richtext"].map { root.appendingPathComponent($0) }
            let filesBefore = try folders.map { try FileManager.default.contentsOfDirectory(atPath: $0.path).sorted() }
            do {
                try store.add(payload, sourceApp: "Late capture", excludingDigests: [digest])
                Issue.record("A per-capture excluded digest must never be committed")
            } catch HistoryError.excludedContent {}
            #expect(store.entries == before)
            #expect(try Data(contentsOf: manifest) == diskBefore)
            #expect(
                try folders.map { try FileManager.default.contentsOfDirectory(atPath: $0.path).sorted() } == filesBefore
            )
            #expect(try Data(contentsOf: originalFile) == originalBytes)
        }

        for payload in payloads {
            let id = try store.add(payload, sourceApp: "Original")
            let entry = try #require(store.entries.first(where: { $0.id == id }))
            // An excluded duplicate must not increment counts or change metadata.
            try expectExcluded(payload, digest: entry.digest)
            try store.remove(id)
            // A late result must not resurrect a deleted entry or its sidecars.
            try expectExcluded(payload, digest: entry.digest)
            #expect(store.entries.map(\.id) == [keeper])
            // A later explicit copy has no tombstone and remains usable.
            let nextID = try store.add(payload, sourceApp: "New explicit copy")
            #expect(nextID != id && store.entries.first?.digest == entry.digest)
            try store.remove(nextID)
        }
    }

    @Test func seededMixedOperationsPreserveHistoryAndSidecars() throws {
        var rejectedCaptures = 0
        for seed: UInt64 in [0, 1, 2, 0xCAFE, 0xDEAD_BEEF, 0x2026_1108, 0x0123_4567_89AB_CDEF, .max] {
            let directory = root.appendingPathComponent("seed-\(seed)")
            var store = try HistoryStore(directory: directory, maxItems: 17, maxBytes: 4_096)
            let original = directory.appendingPathComponent("original.txt")
            let originalBytes = Data("file reference must never modify original".utf8)
            try originalBytes.write(to: original)
            var random = Generator(state: seed)
            var successfulCaptures = 0
            for step in 0..<500 {
                let before = store.entries
                let operation = random.next(10)
                switch operation {
                case 0...5:
                    let token = random.next(40)
                    let payload: ClipPayload
                    switch token % 4 {
                    case 0: payload = .text("文字 \(token) 👩🏽‍💻\r\n\t" + String(repeating: "x", count: random.next(128)))
                    case 1: payload = .image(png: Self.png, width: 1, height: 1)
                    case 2:
                        payload = .richText(
                            text: "item \(token)", formats: ["public.html": Data("<b>item \(token)</b>".utf8)])
                    default: payload = .files([original, directory.appendingPathComponent("missing-\(token).pdf")])
                    }
                    let diskBefore = try? Data(contentsOf: directory.appendingPathComponent("history.json"))
                    do {
                        let id = try store.add(
                            payload, sourceApp: "Stress", at: Date(timeIntervalSince1970: Double(step)))
                        successfulCaptures += 1
                        #expect(store.entries.first?.id == id)
                        #expect(Set(before.filter(\.isPinned).map(\.id)).isSubset(of: Set(store.entries.map(\.id))))
                    } catch HistoryError.capacityExceeded {
                        rejectedCaptures += 1
                        #expect(store.entries == before)
                        #expect((try? Data(contentsOf: directory.appendingPathComponent("history.json"))) == diskBefore)
                    }
                case 6:
                    if !before.isEmpty { try store.togglePin(before[random.next(before.count)].id) }
                case 7:
                    if !before.isEmpty {
                        let id = before[random.next(before.count)].id
                        try store.remove(id)
                        #expect(store.entries == before.filter { $0.id != id })
                    }
                case 8:
                    let keep = random.next(5) != 0
                    try store.clear(keepingPinned: keep)
                    #expect(store.entries == (keep ? before.filter(\.isPinned) : []))
                default: try store.applyLimit(1 + random.next(17))
                }
                #expect(Set(store.entries.map(\.id)).count == store.entries.count)
                #expect(Set(store.entries.map(\.digest)).count == store.entries.count)
                #expect(store.entries.filter(\.isPinned).count <= 20)
                #expect(store.entries.count <= max(store.maxItems, store.entries.filter(\.isPinned).count))
                #expect(store.entries.reduce(0) { $0 + $1.byteCount } <= store.maxBytes)
                if step % 25 == 0 {
                    let bytesBefore = try? Data(contentsOf: directory.appendingPathComponent("history.json"))
                    let reopened = try HistoryStore(
                        directory: directory, maxItems: store.maxItems, maxBytes: store.maxBytes)
                    #expect(reopened.entries == store.entries)
                    #expect((try? Data(contentsOf: directory.appendingPathComponent("history.json"))) == bytesBefore)
                    store = reopened
                    for entry in store.entries {
                        if entry.kind == .richText {
                            let formats = try store.richTextFormats(for: entry)
                            #expect(formats["public.html"] == Data("<b>\(entry.text!)</b>".utf8))
                        } else if entry.kind == .image {
                            #expect(try Data(contentsOf: #require(store.imageURL(for: entry))) == Self.png)
                        }
                    }
                    for (folder, expected) in [
                        ("images", Set(store.entries.compactMap(\.imageFilename))),
                        ("richtext", Set(store.entries.compactMap(\.richTextFilename))),
                    ] {
                        #expect(
                            Set(
                                try FileManager.default.contentsOfDirectory(
                                    atPath: directory.appendingPathComponent(folder).path)) == expected)
                    }
                }
                #expect(try Data(contentsOf: original) == originalBytes)
            }
            #expect(successfulCaptures > 100)
        }
        // Coverage across the corpus matters; an individual valid random trace
        // need not happen to fill a pinned capacity boundary.
        #expect(rejectedCaptures > 0)
    }

    private func mutateManifest(version: Int? = nil, _ update: (inout [[String: Any]]) -> Void) throws {
        let url = root.appendingPathComponent("history.json")
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var records = try #require(document["entries"] as? [[String: Any]])
        update(&records)
        document["entries"] = records
        if let version { document["version"] = version }
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: url)
    }

    private struct Generator {
        var state: UInt64
        mutating func next(_ upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 32) % UInt64(upperBound))
        }
    }
}
