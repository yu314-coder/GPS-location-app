import Foundation

/// LEFTOVER TEMP FILES (build 78).
///
/// Every `.atomic` write goes through a hidden folder in tmp/ (NSIRD_…) and is moved into place
/// when it finishes. When the app is stopped mid-write the half-written copy is never moved and
/// never removed: on one phone three of them held 0.93 GB - a 568 MB and a 244 MB workout list
/// and a 115 MB workout checkpoint, left in May, June and September. Share-sheet copies of
/// exported logs and routes pile up in tmp/ the same way.
///
/// tmp/ is for files that live seconds to minutes, so at launch anything in it untouched for a
/// day is removed, on a background queue. A directory counts as touched when anything inside
/// it is, so a write or an export in progress is never touched.
enum TempFileSweeper {
    static let maxAge: TimeInterval = 24 * 3600

    static func sweep() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey]
            guard let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory,
                                                          includingPropertiesForKeys: keys) else { return }
            let cutoff = Date().addingTimeInterval(-maxAge)
            var removed = 0
            var freed: Int64 = 0
            for item in items {
                let (newest, bytes) = newestModificationAndSize(of: item, keys: keys)
                guard newest < cutoff else { continue }
                do {
                    try fm.removeItem(at: item)
                    removed += 1
                    freed += bytes
                } catch {
                    print("🧹 Could not remove \(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if removed > 0 {
                print("🧹 Removed \(removed) leftover temp item(s), \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
            }
        }
    }

    /// The latest modification date of an item and everything inside it, and its total size.
    private static func newestModificationAndSize(of url: URL, keys: [URLResourceKey]) -> (Date, Int64) {
        let values = try? url.resourceValues(forKeys: Set(keys))
        var newest = values?.contentModificationDate ?? .distantFuture   // unreadable: keep it
        var bytes = Int64(values?.fileSize ?? 0)
        if values?.isDirectory == true,
           let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let child as URL in walker {
                let v = try? child.resourceValues(forKeys: Set(keys))
                newest = max(newest, v?.contentModificationDate ?? .distantFuture)
                bytes += Int64(v?.fileSize ?? 0)
            }
        }
        return (newest, bytes)
    }
}
