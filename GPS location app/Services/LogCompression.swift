import Foundation
import zlib

/// LOGS ARE STORED GZIP-COMPRESSED (build 158).
///
/// The app's log folder had grown to 4.1 GB on the owner's iPhone (2026-11-21): 151 raw 50 Hz traces made 3.76 GB of
/// it, as plain text at about 32 MB an hour. Every log is now written as `.csv.gz`, and each batch the writers already
/// put on disk (the raw trace every ~40 s, the other logs every few dozen lines) becomes one complete gzip member. A
/// file of concatenated members is ordinary gzip (RFC 1952): gunzip, Python, pandas and macOS read it as one file. A
/// crash loses only the batch not yet written, as before; every member already on disk stays readable.
///
/// Measured on the archived logs: level 6 stores a raw trace in 36-38% of its text (level 1: 42%, level 9: 36.1% at 3x
/// the CPU), events 19%, debug rows 24%, watch logs 15-31%; batch-sized members cost 0.1 point against compressing a
/// whole file at once. Level 6 costs about a second of CPU per hour of logging and writes ~20 MB an hour less to
/// flash. Nothing is rounded or dropped: decompressed, the file is byte for byte what the app used to write.
enum LogCompression {
    static let level: Int32 = 6

    /// `name.csv.gz` is compressed, anything else plain.
    static func isCompressed(_ url: URL) -> Bool { url.pathExtension.lowercased() == "gz" }

    /// One complete gzip member holding `data`. `level` 1 for frequent rewrites (watch checkpoints of a saved route:
    /// 16.5% of the JSON at ~3x the speed of level 6's 14.6%).
    static func gzipMember(_ data: Data, level: Int32 = LogCompression.level) -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Data() }
        defer { deflateEnd(&stream) }
        let capacity = Int(deflateBound(&stream, uLong(data.count))) + 64
        var out = Data(count: capacity)
        var produced = 0
        let status: Int32 = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                let r = deflate(&stream, Z_FINISH)
                produced = capacity - Int(stream.avail_out)
                return r
            }
        }
        guard status == Z_STREAM_END else { return Data() }
        out.count = produced
        return out
    }

    /// Reads a file a megabyte at a time, decompressing a `.gz` one; `next()` returns nil at the end. A last member cut
    /// off by a crash ends the stream where its data ends instead of failing.
    final class ChunkReader {
        private let handle: FileHandle
        private let compressed: Bool
        private var stream = z_stream()
        private var inflating = false
        private var input = Data()
        private var inputOffset = 0
        private var finished = false

        /// `compressed`: decompress whatever the name (the conversion's temporary copy ends in .partial).
        init(_ url: URL, compressed forced: Bool? = nil) throws {
            handle = try FileHandle(forReadingFrom: url)
            self.compressed = forced ?? LogCompression.isCompressed(url)
            if compressed {
                guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                inflating = true
            }
        }

        deinit {
            if inflating { inflateEnd(&stream) }
            try? handle.close()
        }

        func next() throws -> Data? {
            if finished { return nil }
            guard compressed else {
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { finished = true; return nil }
                return chunk
            }
            let outCapacity = 1 << 20
            var out = Data(count: outCapacity)
            var produced = 0
            while produced == 0 {
                if inputOffset >= input.count {
                    input = try handle.read(upToCount: 1 << 18) ?? Data()
                    inputOffset = 0
                    if input.isEmpty { finished = true; return nil }      // end of file (or a cut-off member)
                }
                var status: Int32 = Z_OK
                let available = input.count - inputOffset
                input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                        stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress! + inputOffset)
                        stream.avail_in = uInt(available)
                        stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress! + produced
                        stream.avail_out = uInt(outCapacity - produced)
                        status = inflate(&stream, Z_NO_FLUSH)
                        inputOffset += available - Int(stream.avail_in)
                        produced = outCapacity - Int(stream.avail_out)
                    }
                }
                switch status {
                case Z_OK, Z_BUF_ERROR: break
                case Z_STREAM_END: inflateReset(&stream)            // the next member follows
                default: finished = true                             // damaged: keep what was read
                }
                if finished { break }
            }
            out.count = produced
            return produced > 0 ? out : nil
        }
    }

    /// `data` itself, or decompressed when it is gzip (starts 1f 8b): a saved route written by build 158 or later.
    static func gunzipIfNeeded(_ data: Data) throws -> Data {
        guard data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return data }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { inflateEnd(&stream) }
        var out = Data()
        let chunk = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < data.count {
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress! + offset)
                stream.avail_in = uInt(data.count - offset)
                var status: Int32 = Z_OK
                repeat {
                    let produced: Int = buffer.withUnsafeMutableBufferPointer { b in
                        stream.next_out = b.baseAddress
                        stream.avail_out = uInt(chunk)
                        status = inflate(&stream, Z_NO_FLUSH)
                        return chunk - Int(stream.avail_out)
                    }
                    if produced > 0 { out.append(contentsOf: buffer[0..<produced]) }
                } while status == Z_OK && stream.avail_out == 0
                let consumed = (data.count - offset) - Int(stream.avail_in)
                offset += consumed
                if status == Z_STREAM_END { inflateReset(&stream); continue }    // another member may follow
                if status != Z_OK && status != Z_BUF_ERROR { throw CocoaError(.fileReadCorruptFile) }
                if consumed == 0 { break }                                          // cut off: keep what was read
            }
        }
        return out
    }

    /// Compress `source` (a plain log) into `destination` (.csv.gz), then read the result back and compare it with the
    /// source byte for byte. Throws, leaving the source alone, if anything differs.
    static func compressFile(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try autoreleasepool {
                    let member = gzipMember(chunk)
                    guard !member.isEmpty else { throw CocoaError(.fileWriteUnknown) }
                    try output.write(contentsOf: member)
                }
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close(); try? fm.removeItem(at: destination); throw error
        }
        // Verify.
        let plain = try FileHandle(forReadingFrom: source)
        defer { try? plain.close() }
        let reader = try ChunkReader(destination, compressed: true)
        var pending = Data()
        while let chunk = try reader.next() {
            pending.append(chunk)
            let original = try plain.read(upToCount: pending.count) ?? Data()
            guard original == pending else { try? fm.removeItem(at: destination); throw CocoaError(.fileReadCorruptFile) }
            pending.removeAll(keepingCapacity: true)
        }
        guard (try plain.read(upToCount: 1) ?? Data()).isEmpty else {
            try? fm.removeItem(at: destination); throw CocoaError(.fileReadCorruptFile)
        }
    }
}
