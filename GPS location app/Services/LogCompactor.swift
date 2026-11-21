import Foundation
import UIKit

/// THE LOGS ALREADY ON THE PHONE (build 158). Logs written before build 158 are plain `.csv`: 4.1 GB in the owner's
/// app on 2026-11-21, 3.76 GB of it raw traces. At launch the app offers once to store them compressed (the owner's
/// choice: it asks, never converts silently). Each file is compressed to a hidden temporary copy beside it, read back
/// and compared byte for byte with the original, and only then replaces it; a file that fails is left as it was.
///
/// Battery and storage: it runs only when accepted, at utility priority, one file at a time, and stops whenever a
/// workout is recording (it carries on at the next launch's offer); it skips a file while free space is short. The
/// logs stay where they were, Documents/VelocityLogs, the folder Files and the share sheet already show, so nothing
/// moves for the person collecting them; compressed they also take ~60% less of the phone's iCloud backup.
@MainActor
final class LogCompactor: ObservableObject {
    static let shared = LogCompactor()

    struct Offer: Identifiable { let id = UUID(); let files: [URL]; let bytes: Int64; let estimate: Int64; let routes: Int }
    struct Outcome: Identifiable { let id = UUID(); let files: Int; let before: Int64; let after: Int64; let failed: Int; let stopped: Bool }

    @Published var offer: Offer?
    @Published var running = false
    @Published var progress: (done: Int, total: Int) = (0, 0)
    @Published var outcome: Outcome?
    /// Bytes of originals waiting in Before compression for the owner to delete (keepOriginals).
    @Published var originalsKept: Int64 = 0

    func refreshOriginals() {
        Task.detached(priority: .utility) {
            let b = Self.originalsBytes()
            await MainActor.run { self.originalsKept = b }
        }
    }

    /// The owner's manual step: remove the kept originals (each one's compressed copy already passed the checks).
    func deleteOriginals() {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: Self.originalsDirectory)
            await MainActor.run { self.originalsKept = 0 }
        }
    }

    nonisolated static func originalsBytes() -> Int64 {
        guard let e = FileManager.default.enumerator(at: originalsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    private static let askedKey = "logCompressionDeclinedAt"

    /// KEEP THE ORIGINALS WHILE THE OWNER TESTS (owner, 2026-11-21): each converted original is moved, not deleted, into
    /// Documents/Before compression (visible in Files), and removed only when the owner taps "Delete originals" (the
    /// result alert or Settings → Developer). Turn off for the public release, which swaps directly.
    static let keepOriginals = true
    nonisolated static var originalsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Before compression", isDirectory: true)
    }
    private static let askAgainAfter: TimeInterval = 7 * 24 * 3600

    private var logDirectory: URL { SessionDiagnosticsRecorder.velocityLogDirectory }

    /// Plain files that may be compressed, none written in the last ten minutes: this phone's and the watch's logs, and
    /// the saved workouts' full routes (flight_details_*.json, beside VelocityLogs in Documents; build 158 writes them
    /// as .json.gz, see FlightDataStore).
    nonisolated static func plainLogs(in dir: URL) -> [(URL, Int64)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
            + ((try? fm.contentsOfDirectory(at: dir.deletingLastPathComponent(), includingPropertiesForKeys: keys)) ?? [])
        return files.compactMap { url in
            let name = url.lastPathComponent
            let isLog = name.hasSuffix(".csv") && (name.hasPrefix("velocity_") || name.hasPrefix("watch_velocity_"))
            let isRoute = name.hasPrefix("flight_details_") && name.hasSuffix(".json")
            guard isLog || isRoute,
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = v.contentModificationDate, Date().timeIntervalSince(modified) > 600 else { return nil }
            return (url, Int64(v.fileSize ?? 0))
        }
    }

    /// Called when the app's first screen appears: offer to compress, unless declined in the last week or recording.
    func offerIfNeeded() {
        guard offer == nil, !running, !WorkoutSession.shared.isActive else { return }
        if let declined = UserDefaults.standard.object(forKey: Self.askedKey) as? Date,
           Date().timeIntervalSince(declined) < Self.askAgainAfter { return }
        let dir = logDirectory
        Task.detached(priority: .utility) {
            Self.removeLeftovers(in: dir)
            Self.removeLeftovers(in: dir.deletingLastPathComponent())
            let logs = Self.plainLogs(in: dir)
            guard !logs.isEmpty else { return }
            let bytes = logs.reduce(Int64(0)) { $0 + $1.1 }
            // Measured: logs to ~38%, route JSON to ~15%.
            let estimate = logs.reduce(Int64(0)) { $0 + ($1.0.pathExtension == "json" ? $1.1 * 15 / 100 : $1.1 * 38 / 100) }
            let routes = logs.filter { $0.0.pathExtension == "json" }.count
            await MainActor.run {
                guard !WorkoutSession.shared.isActive else { return }
                self.offer = Offer(files: logs.map { $0.0 }, bytes: bytes, estimate: estimate, routes: routes)
            }
        }
    }

    func decline() {
        UserDefaults.standard.set(Date(), forKey: Self.askedKey)
        offer = nil
    }

    func start(_ offer: Offer) {
        self.offer = nil
        guard !running else { return }
        running = true
        progress = (0, offer.files.count)
        UserDefaults.standard.removeObject(forKey: Self.askedKey)
        // A few minutes of work: keep going briefly if the app is sent to the background; a file cut short stays a
        // hidden temporary copy, removed at the next launch, and its original is untouched.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Compress logs") {
            UIApplication.shared.endBackgroundTask(task); task = .invalid
        }
        let files = offer.files
        Task.detached(priority: .utility) {
            var done = 0, failed = 0
            var before: Int64 = 0, after: Int64 = 0
            var stopped = false
            for url in files {
                if await MainActor.run(body: { WorkoutSession.shared.isActive }) { stopped = true; break }
                let r = Self.compress(url)
                switch r {
                case .done(let b, let a): done += 1; before += b; after += a
                case .failed: failed += 1
                case .noSpace: stopped = true
                }
                if stopped { break }
                let n = done + failed
                await MainActor.run { self.progress = (n, files.count) }
            }
            let result = Outcome(files: done, before: before, after: after, failed: failed, stopped: stopped)
            let kept = Self.originalsBytes()
            await MainActor.run {
                self.originalsKept = kept
                self.running = false
                self.outcome = result
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    private enum Result { case done(Int64, Int64), failed, noSpace }

    nonisolated private static func compress(_ url: URL) -> Result {
        let fm = FileManager.default
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        // Room for the compressed copy (under half the original) and a margin, before anything is written.
        if let free = try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < size / 2 + 200_000_000 {
            return .noSpace
        }
        let dir = url.deletingLastPathComponent()
        let final = dir.appendingPathComponent(url.lastPathComponent + ".gz")
        let temp = dir.appendingPathComponent("." + url.lastPathComponent + ".gz.partial")
        do {
            if fm.fileExists(atPath: final.path) {
                // A conversion ended between its rename and putting the original away: check the copy, then finish.
                try LogCompression.verifyCompressed(final, against: url)
                try appWorks(final, original: url)
            } else {
                let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                try LogCompression.compressFile(url, to: temp)          // byte for byte against the original
                try appWorks(temp, original: url)                        // and read the way the app reads it
                if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: temp.path) }
                try fm.moveItem(at: temp, to: final)
            }
            try putAwayOriginal(url)
            let after = Int64((try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return .done(size, after)
        } catch {
            try? fm.removeItem(at: temp)
            print("📦 Could not compress \(url.lastPathComponent): \(error)")
            return .failed
        }
    }

    /// CHECK THAT THE APP CAN USE THE COMPRESSED FILE, before the original goes anywhere. A log is read through the
    /// reader Re-run and Import use (WorkoutLogReplay.forEachLine) and must give exactly the original's lines. A route
    /// is decoded as the workout screen decodes it (FlightDataStore: gunzip, JSONDecoder, ISO 8601 dates). A route over
    /// 64 MB is not decoded here - that can take a gigabyte of memory, too much for a background task - but it has
    /// already been compared byte for byte with the original the app opened before, and must still open and close as
    /// JSON.
    nonisolated private static func appWorks(_ compressed: URL, original: URL) throws {
        if original.pathExtension == "json" {
            let size = (try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size <= 64_000_000 {
                let data = try LogCompression.gunzipIfNeeded(Data(contentsOf: compressed))
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                _ = try decoder.decode(Flight.self, from: data)
            } else {
                let reader = try LogCompression.ChunkReader(compressed, compressed: true)
                var first: UInt8?, last: UInt8?
                while let c = try reader.next() {
                    if first == nil { first = c.first(where: { $0 > 0x20 }) }
                    if let l = c.last(where: { $0 > 0x20 }) { last = l }
                }
                guard first == UInt8(ascii: "{") || first == UInt8(ascii: "["),
                      last == UInt8(ascii: "}") || last == UInt8(ascii: "]") else { throw CocoaError(.fileReadCorruptFile) }
            }
        } else {
            var lines = 0
            try WorkoutLogReplay.forEachLine(compressed, compressed: true) { _ in lines += 1; return true }
            var originalLines = 0
            try WorkoutLogReplay.forEachLine(original) { _ in originalLines += 1; return true }
            guard lines == originalLines, lines > 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    /// The checked original: kept in Before compression while the owner tests, deleted in the public release.
    nonisolated private static func putAwayOriginal(_ url: URL) throws {
        let fm = FileManager.default
        guard keepOriginals else { try fm.removeItem(at: url); return }
        var target = originalsDirectory
        if url.deletingLastPathComponent().lastPathComponent == "VelocityLogs" { target.appendPathComponent("VelocityLogs") }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let dest = target.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: url, to: dest)
    }

    /// Temporary copies left by a conversion the system ended.
    nonisolated private static func removeLeftovers(in dir: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix(".") && name.hasSuffix(".gz.partial") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// "151 workout logs and 3,859 saved routes", naming only what is there.
    static func describe(logs: Int, routes: Int) -> String {
        let l = logs == 1 ? "1 workout log" : "\(logs.formatted()) workout logs"
        let r = routes == 1 ? "1 saved route" : "\(routes.formatted()) saved routes"
        return logs > 0 && routes > 0 ? "\(l) and \(r)" : (routes > 0 ? r : l)
    }

    static func megabytes(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }
}
