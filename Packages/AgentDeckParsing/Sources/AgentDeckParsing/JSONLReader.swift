import Foundation

/// Reads complete JSONL lines from a byte offset. A trailing line without a newline is still being
/// written, so it is left for the next pass.
public enum JSONLReader {
    public struct Chunk: Sendable {
        /// Complete, non-empty lines without their newline.
        public var lines: [Data]
        /// Byte offset just past the last complete line.
        public var endOffset: UInt64
    }

    public enum ReadError: Error, Equatable {
        /// The file is shorter than the stored offset, so it was truncated or replaced.
        /// Rescan it from offset 0.
        case offsetBeyondEndOfFile(fileSize: UInt64, offset: UInt64)
    }

    public static func readCompleteLines(from url: URL, startingAt offset: UInt64) throws -> Chunk {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard offset <= size else {
            throw ReadError.offsetBeyondEndOfFile(fileSize: size, offset: offset)
        }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        return splitCompleteLines(data, baseOffset: offset)
    }

    static func splitCompleteLines(_ data: Data, baseOffset: UInt64) -> Chunk {
        var lines: [Data] = []
        var consumed = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count,
                  let hit = memchr(base + start, 0x0A, raw.count - start) {
                let end = base.distance(to: hit)
                if !isBlank(raw, start, end) {
                    lines.append(Data(bytes: base + start, count: end - start))
                }
                start = end + 1
                consumed = start
            }
        }
        return Chunk(lines: lines, endOffset: baseOffset + UInt64(consumed))
    }

    private static func isBlank(_ raw: UnsafeRawBufferPointer, _ start: Int, _ end: Int) -> Bool {
        for i in start..<end {
            switch raw[i] {
            case 0x20, 0x09, 0x0D: continue
            default: return false
            }
        }
        return true
    }
}
