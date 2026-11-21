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

    private static let askedKey = "logCompressionDeclinedAt"
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
            await MainActor.run {
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
        guard !fm.fileExists(atPath: final.path) else { return .failed }
        do {
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try LogCompression.compressFile(url, to: temp)
            if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: temp.path) }
            try fm.moveItem(at: temp, to: final)
            try fm.removeItem(at: url)
            let after = Int64((try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return .done(size, after)
        } catch {
            try? fm.removeItem(at: temp)
            print("📦 Could not compress \(url.lastPathComponent): \(error)")
            return .failed
        }
    }

    /// Temporary copies left by a conversion the system ended.
    nonisolated private static func removeLeftovers(in dir: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(".") && name.hasSuffix(".gz.partial") {
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
