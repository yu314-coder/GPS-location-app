import Foundation
import UIKit
import BackgroundTasks

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
    private enum ContinuedState { case none, waiting, started, fellBack }
    private var continuedState = ContinuedState.none
    /// Share of the bytes done (build 162): moves within a large file.
    @Published var percent = 0
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

    /// REVERT (build 161): put every kept original back where it was and remove its compressed copy, so the app reads
    /// the original again. A compressed copy that changed after the conversion (a saved route edited since, its date no
    /// longer the original's) is newer than the original: that one is left compressed and its original stays here.
    func restoreOriginals() {
        let logs = logDirectory
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var restored = 0, kept = 0
            let docs = Self.originalsDirectory.deletingLastPathComponent()
            for (folder, dest) in [(Self.originalsDirectory.appendingPathComponent("VelocityLogs"), logs),
                                   (Self.originalsDirectory, docs)] {
                for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                    guard url.pathExtension == "csv" || url.pathExtension == "json" else { continue }
                    let target = dest.appendingPathComponent(url.lastPathComponent)
                    let compressed = dest.appendingPathComponent(url.lastPathComponent + ".gz")
                    let originalDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    let copyDate = try? compressed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    if let c = copyDate, let o = originalDate, c.timeIntervalSince(o) > 1 { kept += 1; continue }
                    guard !fm.fileExists(atPath: target.path) else { kept += 1; continue }
                    do {
                        try fm.moveItem(at: url, to: target)
                        try? fm.removeItem(at: compressed)
                        restored += 1
                    } catch { kept += 1 }
                }
            }
            let left = Self.originalsBytes()
            await MainActor.run {
                self.originalsKept = left
                self.restoreResult = (restored, kept)
                // Restored on purpose: the launch offer to compress them again waits a week (Settings still offers it).
                UserDefaults.standard.set(Date(), forKey: Self.askedKey)
                self.refreshPending()
            }
        }
    }
    @Published var restoreResult: (restored: Int, kept: Int)?

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
    static let keepOriginals = false   // public build: direct swap (owner, 2026-11-22); true in test builds
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

    // MARK: - Running (build 161)
    //
    // FASTER: files are converted by up to four workers at once, largest first so the big traces do not all finish last,
    // and the read-back check is one pass: the compressed copy is read through the app's own reader (ChunkReader, what
    // Re-run and Import read logs with) and compared byte for byte with the original - which also guarantees the same
    // lines, so the separate line count of build 160 (two more full reads, a String per line) is gone. Routes are still
    // decoded as the workout screen decodes them.
    // IN THE BACKGROUND: on iOS 26 and later the work runs as a BGContinuedProcessingTask - started from the app, it
    // keeps running after you leave it, and iOS shows its progress in a live activity (Lock Screen / Dynamic Island) whose
    // subtitle the app updates ("41 of 151 files · 1.2 GB freed"). If iOS declines it, or on older systems, it runs as
    // before while the app is open (and briefly after). A workout starting, low storage, or iOS ending the task stops it
    // between files; nothing half-done is kept, and the rest is offered again.
    nonisolated static let taskIdentifierPrefix = "euleryu.gps.compress"
    nonisolated(unsafe) private static var pendingFiles: [URL] = []

    /// Nothing to do at launch: a continued-processing handler is registered for its own concrete identifier just before
    /// the request is submitted (start(_:)). Apple blocks a single handler for the "prefix.*" pattern (DTS, Apple
    /// Developer Forums thread 799126), and continued-processing registrations are exempt from the at-launch rule.
    nonisolated static func registerBackgroundTask() {}

    /// The plain files waiting to be compressed, for the Settings row (shown only when there are some).
    @Published var pending: (count: Int, bytes: Int64) = (0, 0)
    func refreshPending() {
        let dir = logDirectory
        Task.detached(priority: .utility) {
            let logs = Self.plainLogs(in: dir)
            let b = logs.reduce(Int64(0)) { $0 + $1.1 }
            await MainActor.run { self.pending = (logs.count, b) }
        }
    }

    /// The Settings row: the same offer as at launch, for whatever is still plain.
    func offerNow() {
        let dir = logDirectory
        Task.detached(priority: .utility) {
            let logs = Self.plainLogs(in: dir)
            guard !logs.isEmpty else { return }
            let bytes = logs.reduce(Int64(0)) { $0 + $1.1 }
            let estimate = logs.reduce(Int64(0)) { $0 + ($1.0.pathExtension == "json" ? $1.1 * 15 / 100 : $1.1 * 38 / 100) }
            let routes = logs.filter { $0.0.pathExtension == "json" }.count
            await MainActor.run { self.offer = Offer(files: logs.map { $0.0 }, bytes: bytes, estimate: estimate, routes: routes) }
        }
    }

    func start(_ offer: Offer) {
        self.offer = nil
        guard !running else { return }
        running = true
        progress = (0, offer.files.count)
        percent = 0
        UserDefaults.standard.removeObject(forKey: Self.askedKey)
        if #available(iOS 26.0, *) {
            Self.pendingFiles = offer.files
            let identifier = Self.taskIdentifierPrefix + "." + UUID().uuidString.prefix(8)
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor in LogCompactor.shared.runContinued(task) }
            }
            guard registered else { runInApp(offer.files); return }
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: "Compressing stored data",
                subtitle: "0 of \(offer.files.count) files")
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
                // runContinued(_:) does the work - unless iOS has not started it 20 s later, then the app does
                // (build 162); a task that starts after that ends at once, so the two never run together.
                continuedState = .waiting
                let files = offer.files
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    guard self.continuedState == .waiting else { return }
                    NSLog("📦 background task did not start within 20 s; running in the app")
                    self.continuedState = .fellBack
                    self.runInApp(files)
                }
                return
            } catch {
                NSLog("📦 background task not accepted: %@", error.localizedDescription)
            }
        }
        runInApp(offer.files)
    }

    /// Without the background task: as before, while the app is open, plus the short time iOS gives after leaving it.
    private func runInApp(_ files: [URL]) {
        NSLog("📦 compression running in the app (no background task)")
        var task = UIBackgroundTaskIdentifier.invalid
        let stop = StopFlag()
        task = UIApplication.shared.beginBackgroundTask(withName: "Compress logs") {
            stop.set(); UIApplication.shared.endBackgroundTask(task); task = .invalid
        }
        Task.detached(priority: .utility) {
            let total = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let result = Self.runAll(files, stop: stop) { done, count, bytesDone, _ in
                let pct = Int(Double(bytesDone) / Double(max(total, 1)) * 100)
                Task { @MainActor in self.progress = (done, count); self.percent = pct }
            }
            await self.finish(result)
            await MainActor.run { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        }
    }

    @available(iOS 26.0, *)
    private func runContinued(_ task: BGContinuedProcessingTask) {
        guard continuedState == .waiting else {
            NSLog("📦 background task started late; the app is already compressing")
            task.setTaskCompleted(success: false); return
        }
        continuedState = .started
        NSLog("📦 compression running as a background task (%@)", task.identifier)
        var files = Self.pendingFiles
        Self.pendingFiles = []
        if files.isEmpty { files = Self.plainLogs(in: logDirectory).map { $0.0 } }   // e.g. relaunched by the system
        running = true
        progress = (0, files.count)
        let stop = StopFlag(), expired = StopFlag()
        task.expirationHandler = {
            NSLog("📦 background compression task expired by iOS")
            expired.set(); stop.set()
        }
        let totalBytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        task.progress.totalUnitCount = max(totalBytes, 1)
        task.progress.completedUnitCount = 0
        Task.detached(priority: .utility) {
            let result = Self.runAll(files, stop: stop) { done, total, bytesDone, freed in
                task.progress.completedUnitCount = bytesDone
                let pct = Int(Double(bytesDone) / Double(max(totalBytes, 1)) * 100)
                task.updateTitle("Compressing stored data",
                                 subtitle: "\(done) of \(total) files · \(pct)% · \(Self.megabytes(freed)) freed")
                Task { @MainActor in self.progress = (done, total); self.percent = pct }
            }
            task.setTaskCompleted(success: !result.stopped)
            // iOS ended the background task while the app is open: carry on here instead of stopping (build 162).
            if expired.isSet, await MainActor.run(body: { UIApplication.shared.applicationState == .active }) {
                let rest = Self.plainLogs(in: await self.logDirectory).map { $0.0 }
                if !rest.isEmpty {
                    NSLog("📦 continuing in the app with %d files", rest.count)
                    await MainActor.run { self.runInApp(rest) }
                    return
                }
            }
            await self.finish(result)
        }
    }

    private func finish(_ result: Outcome) async {
        let kept = Self.originalsBytes()
        await MainActor.run {
            self.continuedState = .none
            self.originalsKept = kept
            self.running = false
            self.outcome = result
            self.refreshPending()
        }
    }

    /// Thread-safe stop request (iOS expiring the task, a workout starting).
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Convert `files` with parallel workers; `report(done, total, bytesDone, bytesFreed)` after each file.
    nonisolated private static func runAll(_ files: [URL], stop: StopFlag,
                                           report: @escaping (Int, Int, Int64, Int64) -> Void) -> Outcome {
        let sized = files.map { ($0, Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
            .sorted { $0.1 > $1.1 }
        let workers = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = workers
        queue.qualityOfService = .utility
        let lock = NSLock()
        var done = 0, failed = 0, finished = 0
        var before: Int64 = 0, after: Int64 = 0, bytesDone: Int64 = 0
        var stopped = false
        var lastReport = Date.distantPast
        for (url, size) in sized {
            queue.addOperation {
                lock.lock(); let skip = stopped; lock.unlock()
                if skip || stop.isSet { lock.lock(); stopped = true; lock.unlock(); return }
                if DispatchQueue.main.sync(execute: { WorkoutSession.shared.isActive }) {
                    lock.lock(); stopped = true; lock.unlock(); return
                }
                var counted: Int64 = 0
                let r = compress(url) { chunk in
                    // Progress every megabyte (build 162): iOS ends a continued-processing task that looks stalled,
                    // and with the largest files first a whole-file report could be a minute away.
                    lock.lock()
                    counted += chunk; bytesDone += chunk
                    let now = Date()
                    let due = now.timeIntervalSince(lastReport) >= 0.5
                    if due { lastReport = now }
                    let snapshot = (finished, bytesDone, before - after)
                    lock.unlock()
                    if due { report(snapshot.0, sized.count, snapshot.1, snapshot.2) }
                }
                lock.lock()
                switch r {
                case .done(let b, let a): done += 1; before += b; after += a
                case .failed: failed += 1
                case .noSpace: stopped = true
                }
                finished += 1; bytesDone += max(0, size - counted)
                let snapshot = (finished, bytesDone, before - after)
                lock.unlock()
                report(snapshot.0, sized.count, snapshot.1, snapshot.2)
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return Outcome(files: done, before: before, after: after, failed: failed, stopped: stopped || stop.isSet)
    }

    private enum Result { case done(Int64, Int64), failed, noSpace }

    nonisolated private static func compress(_ url: URL, progress: ((Int64) -> Void)? = nil) -> Result {
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
                try LogCompression.compressFile(url, to: temp, progress: progress)   // byte for byte against the original
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
    nonisolated private static let decodeGate = DispatchSemaphore(value: 1)
    nonisolated private static func appWorks(_ compressed: URL, original: URL) throws {
        if original.pathExtension == "json" {
            let size = (try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size <= 64_000_000 {
                // One route decode at a time across the workers (build 161): a large route can take hundreds of MB
                // decoded, and four at once could get the app ended for memory in the background.
                decodeGate.wait(); defer { decodeGate.signal() }
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
        }
        // A log: compressFile has already read the copy back through ChunkReader - the reader Re-run and Import use - and
        // matched the original byte for byte, so it gives the same lines (build 161: no separate count).
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

    nonisolated static func megabytes(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }
}
