import Foundation

/// Reads the flat, regular-file subset emitted by NSFileWrapper's version-zero
/// RTFD serializer. Unknown variants fail closed instead of reaching the native
/// deserializer, which may allocate from unchecked lengths before throwing.
enum FlatRTFDReader {
    static func children(in data: Data, maxChildren: Int, maxBytes: Int) -> [String: Data]? {
        guard maxChildren >= 1, data.count <= maxBytes, data.starts(with: [0x72, 0x74, 0x66, 0x64]) else { return nil }
        var cursor = Cursor(data: data, offset: 4)
        guard cursor.uint32() == 0, cursor.uint32() == 3,
            let count = cursor.uint32(), count >= 2, count - 1 <= maxChildren
        else { return nil }
        var names: [String] = []
        for _ in 0..<count {
            guard let name = cursor.string(), validName(name, allowingRoot: true), !names.contains(name) else {
                return nil
            }
            names.append(name)
        }
        guard names.contains(".") else { return nil }
        var sizes: [Int] = []
        for _ in 0..<count {
            guard let size = cursor.uint32(), size >= 8, size <= cursor.remaining else { return nil }
            sizes.append(size)
        }
        var children: [String: Data] = [:]
        var directoryInfo: Data?
        for (name, size) in zip(names, sizes) {
            guard let block = cursor.bytes(count: size) else { return nil }
            var record = Cursor(data: block)
            guard record.uint32() == 1, let size = record.uint32(), size == record.remaining,
                let contents = record.bytes(count: size)
            else { return nil }
            if name == "." { directoryInfo = contents } else { children[name] = contents }
        }
        guard cursor.remaining == 0, let directoryInfo else { return nil }
        // The root directory record lists the same children and their file kind.
        // A nested dictionary or symbolic-link record is never treated as bytes.
        var directory = Cursor(data: directoryInfo)
        guard directory.uint32() == children.count else { return nil }
        var describedNames: [String] = []
        for _ in 0..<children.count {
            guard let name = directory.string(), validName(name, allowingRoot: false),
                children[name] != nil, !describedNames.contains(name)
            else { return nil }
            describedNames.append(name)
        }
        // The supported v0 serializer uses four UInt32 fields per child:
        // timestamp, mode, kind (0 = regular file), and a zero reserved word.
        // Unknown metadata variants must not be passed on to native consumers.
        for _ in 0..<children.count {
            guard directory.uint32() == 16 else { return nil }
        }
        for _ in 0..<children.count {
            guard directory.uint32() != nil, directory.uint32() != nil,
                directory.uint32() == 0, directory.uint32() == 0
            else { return nil }
        }
        guard directory.remaining == 0 else { return nil }
        return children
    }

    private static func validName(_ name: String, allowingRoot: Bool) -> Bool {
        if allowingRoot && name == "." { return true }
        return !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private struct Cursor {
        let data: Data
        var offset = 0
        var remaining: Int { data.count - offset }

        mutating func uint32() -> Int? {
            guard remaining >= 4 else { return nil }
            let value = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                    | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
            }
            offset += 4
            return value
        }

        mutating func bytes(count: Int) -> Data? {
            guard count >= 0, count <= remaining else { return nil }
            let start = data.startIndex + offset
            offset += count
            return data.subdata(in: start..<(start + count))
        }

        mutating func string() -> String? {
            guard let count = uint32(), count > 0, let bytes = bytes(count: count) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
    }
}
