import Foundation
import Darwin

/// A bounded, throwing read that also works on Catalina 10.15.0–10.15.3,
/// where FileHandle.read(upToCount:) is unavailable. Avoids Objective-C I/O exceptions.
public enum BoundedFileReader {
    public static func read(from handle: FileHandle, limit: Int) throws -> Data {
        precondition(limit >= 0)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(65_536, limit))
        while result.count < limit {
            let requested = min(buffer.count, limit - result.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, requested) }
            if count == 0 { break }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
