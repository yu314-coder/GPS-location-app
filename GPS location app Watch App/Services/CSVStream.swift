import Foundation

/// A CSV file written as it grows (build 82).
///
/// Lines are buffered and appended every `flushEvery` lines, so a crash, a battery that dies in
/// the air or iOS ending the app mid-flight loses the last few seconds of a log instead of all of
/// it. The once-a-second log used to be held in memory until Stop and capped at about four hours,
/// so a long flight kept only its end and an interrupted one kept nothing.
///
/// An existing file is appended to, never replaced, so a workout restored after a relaunch carries
/// on in the same file. Only the first writer puts the header in.
///
/// A `.csv.gz` url (build 158) writes each batch as one gzip member (see LogCompression).
final class CSVStream {
    let url: URL
    private let header: String
    private let flushEvery: Int
    private let compressed: Bool
    private var handle: FileHandle?
    private var pending = ""
    private var pendingLines = 0
    private(set) var linesWritten = 0

    init(url: URL, header: String, flushEvery: Int) {
        self.url = url
        self.header = header
        self.flushEvery = max(1, flushEvery)
        self.compressed = LogCompression.isCompressed(url)
    }

    func append(_ line: String) {
        pending += line
        pendingLines += 1
        if pendingLines >= flushEvery { flush() }
    }

    func flush() {
        guard pendingLines > 0 else { return }
        if handle == nil { open() }
        guard let handle, let data = pending.data(using: .utf8) else { return }
        handle.seekToEndOfFile()
        handle.write(compressed ? LogCompression.gzipMember(data) : data)
        linesWritten += pendingLines
        pending = ""
        pendingLines = 0
    }

    func close() {
        flush()
        try? handle?.close()
        handle = nil
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            let head = header.data(using: .utf8) ?? Data()
            fm.createFile(atPath: url.path, contents: compressed ? LogCompression.gzipMember(head) : head)
        }
        handle = try? FileHandle(forWritingTo: url)
        if handle == nil { print("❌ Could not open \(url.lastPathComponent) for streaming") }
    }
}
