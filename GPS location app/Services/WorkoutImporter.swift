import Foundation
import HealthKit

/// DEVELOPER MODE: PUT A WORKOUT FROM ANOTHER PHONE ON THIS ONE (build 127).
///
/// Two kinds of file come across from the other phone (AirDrop, Files, or its Developer screen's "Share all"):
///   - its logs (velocity_events / velocity_debug / velocity_raw50hz for one recording), rebuilt by
///     WorkoutLogReplay - a flight in them drawn again with this build's flight code;
///   - a saved workout (flight_details_<id>.json from its Documents), taken as that phone saved it.
/// Either becomes a new workout here, with the type chosen for it, and optionally goes to Apple Health with exactly
/// that type. It never deletes or replaces anything (build 132): it is saved beside the workouts it overlaps.
@MainActor
final class WorkoutImporter: ObservableObject {

    enum Source: Identifiable, Equatable {
        case logs(WorkoutLogReplay.LogSet)
        case saved(URL)
        var id: String {
            switch self {
            case .logs(let s): return "logs-" + s.stamp
            case .saved(let u): return "saved-" + u.lastPathComponent
            }
        }
        static func == (a: Source, b: Source) -> Bool { a.id == b.id }
    }

    struct Preview {
        var flight: Flight
        var lines: [(String, String)]
        var notes: [String]
        /// This phone's saved workouts whose time overlaps the rebuilt one (build 129; was: started within 3 min).
        var overlapping: [Flight]
        /// Rebuilt from this phone's own logs (build 128).
        var ownRecording = false
    }

    /// What a recording covers, for its row: distance and time, so its average speed (build 129).
    struct Summary: Equatable {
        /// nil: no route could be drawn from the logs.
        var km: Double?
        var start: Date
        var seconds: TimeInterval
        /// Taken from the workout saved on this phone, not drawn from the logs.
        var saved: Bool
        var kmh: Double? { km.flatMap { seconds > 0 ? $0 / (seconds / 3600) : nil } }
    }

    @Published private(set) var sources: [Source] = []
    /// This phone's own recordings (build 128), read where they are: no copying, no picker.
    @Published private(set) var ownSources: [Source] = []
    /// Stamps of the recordings whose workout is saved on this phone.
    @Published private(set) var savedStamps: Set<String> = []
    /// The folder has been listed at least once.
    @Published private(set) var ownLoaded = false
    /// Row summaries by source id, drawn one recording at a time as rows appear.
    @Published private(set) var summaries: [String: Summary] = [:]
    private var summaryQueue: [Source] = []
    private var summarizing = false
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status: String?
    @Published private(set) var preview: Preview?
    /// Read on the reading thread, set from the screen.
    private final class Flag: @unchecked Sendable { private let lock = NSLock(); private var v = false
        var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } } }
    private let cancelFlag = Flag()

    /// The chosen files are copied here first: the picker's access to them ends, and a raw log is read for seconds.
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutImport", isDirectory: true)

    // MARK: - Files

    func receive(_ urls: [URL]) {
        busy = true; status = "Copying the files…"; preview = nil
        let folder = self.folder
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.removeItem(at: folder)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var copied = 0
            func wanted(_ name: String) -> Bool {
                (name.hasPrefix("velocity_") && name.hasSuffix(".csv")) || (name.hasPrefix("flight_details_") && name.hasSuffix(".json"))
            }
            func copy(_ u: URL) {
                guard wanted(u.lastPathComponent) else { return }
                let dest = folder.appendingPathComponent(u.lastPathComponent)
                try? fm.removeItem(at: dest)
                if (try? fm.copyItem(at: u, to: dest)) != nil { copied += 1 }
            }
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                    if let e = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for case let f as URL in e { copy(f) }
                    }
                } else { copy(u) }
            }
            let found = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let (logs, saved) = WorkoutLogReplay.scan(found)
            await MainActor.run {
                self.sources = logs.map { .logs($0) } + saved.map { .saved($0) }
                self.busy = false
                self.status = self.sources.isEmpty
                    ? (copied == 0 ? "None of these files is a workout's log or a saved workout." : "No complete recording among these files.")
                    : nil
            }
        }
    }

    // MARK: - This phone

    /// THE SAME PHONE (build 128). A workout recorded here already has its logs in Documents/VelocityLogs and its
    /// saved workout beside them, so re-running it needs no AirDrop and no Files: list the recordings, newest
    /// first, and mark those whose workout is still saved.
    func loadOwnRecordings() {
        Task.detached(priority: .userInitiated) {
            let dir = SessionDiagnosticsRecorder.velocityLogDirectory
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let logs = WorkoutLogReplay.scan(files).logs
            await MainActor.run {
                self.ownSources = logs.map { .logs($0) }
                self.savedStamps = Set(logs.compactMap { self.savedWorkout(forStamp: $0.stamp) != nil ? $0.stamp : nil })
                // A saved workout may have changed: its row is summed again.
                self.summaries = self.summaries.filter { !$0.value.saved }
                self.ownLoaded = true
            }
        }
    }

    func isOwn(_ source: Source) -> Bool { ownSources.contains(source) }

    /// The workout saved on this phone for one of its own recordings: the one it was recorded as (same stamp), or
    /// one whose time holds the moment it began (a re-run saved by build 127-128 could start minutes early). With
    /// re-runs kept beside it (build 130), the original comes first.
    private func savedWorkout(forStamp stamp: String) -> Flight? {
        let saved = FlightDataStore.shared.savedFlights
            .sorted { ($0.notes?.hasPrefix("Re-run with") == true ? 1 : 0) < ($1.notes?.hasPrefix("Re-run with") == true ? 1 : 0) }
        if let same = saved.first(where: { SessionDiagnosticsRecorder.logStamp(for: $0.startDate) == stamp }) { return same }
        guard let began = SessionDiagnosticsRecorder.date(fromLogStamp: stamp) else { return nil }
        return saved.first { $0.startDate <= began.addingTimeInterval(60) && Self.end(of: $0) > began }
    }

    private static func end(of f: Flight) -> Date {
        f.endDate ?? f.startDate.addingTimeInterval(max(f.metrics?.duration ?? 0, 0))
    }

    /// This phone's saved workouts that overlap a stretch of time.
    private static func overlapping(_ start: Date, _ end: Date) -> [Flight] {
        FlightDataStore.shared.savedFlights
            .filter { $0.startDate < end && Self.end(of: $0) > start }
            .sorted { $0.startDate < $1.startDate }
    }

    /// How many saved workouts share time with a recording whose row has been summed (0 until then).
    func overlapCount(_ source: Source) -> Int {
        guard let s = summaries[source.id], s.seconds > 0 else { return 0 }
        return Self.overlapping(s.start, s.start.addingTimeInterval(s.seconds)).count
    }

    // MARK: - Row summaries

    /// A row's distance, time and average speed: the saved workout's own figures when this phone has it, otherwise
    /// the route drawn from the logs as recorded (no flight re-run, so it costs a second or two, not a minute).
    func summarize(_ source: Source) {
        guard summaries[source.id] == nil, !summaryQueue.contains(source) else { return }
        if isOwn(source), case .logs(let set) = source, let saved = savedWorkout(forStamp: set.stamp) {
            summaries[source.id] = Summary(km: saved.totalDistance / 1000, start: saved.startDate,
                                           seconds: Self.end(of: saved).timeIntervalSince(saved.startDate), saved: true)
            return
        }
        guard case .logs = source else { return }
        summaryQueue.append(source)
        nextSummary()
    }

    private func nextSummary() {
        guard !summarizing, !summaryQueue.isEmpty else { return }
        summarizing = true
        let source = summaryQueue.removeFirst()
        Task.detached(priority: .utility) { [weak self] in
            var summary = Summary(km: nil, start: .distantPast, seconds: 0, saved: false)
            if case .logs(let set) = source,
               let r = try? WorkoutLogReplay.rebuild(set, rerunFlight: false, runways: { _, _ in [] }) {
                let f = Self.makeFlight(r, own: false)
                summary = Summary(km: (f.metrics?.totalDistance ?? 0) / 1000, start: r.start,
                                  seconds: max(r.end.timeIntervalSince(r.start), 0), saved: false)
            }
            await MainActor.run {
                guard let self else { return }
                self.summaries[source.id] = summary
                self.summarizing = false
                self.nextSummary()
            }
        }
    }

    // MARK: - Reading

    func read(_ source: Source, rerunFlight: Bool, useLoggedGPS: Bool) {
        let own = isOwn(source)
        busy = true; progress = 0; preview = nil; cancelFlag.value = false
        let flag = cancelFlag
        status = rerunFlight ? "Reading the logs and re-running the flight…" : "Reading…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (flight, lines, notes) = try Self.build(source, own: own, rerunFlight: rerunFlight, useLoggedGPS: useLoggedGPS,
                    progress: { p in Task { @MainActor in self?.progress = p } },
                    cancelled: { flag.value })
                await MainActor.run {
                    guard let self else { return }
                    var rebuilt = flight
                    // This phone's own recording: the workout it was recorded as, whatever its times now.
                    var original: Flight?
                    if own, case .logs(let set) = source { original = self.savedWorkout(forStamp: set.stamp) }
                    if let original {
                        // Keep what the owner set on the original: its name, places and effort. Its start too, when it
                        // is the same moment (so its logs still match it); never an earlier one, which a re-run from
                        // build 127-128 could carry from a cached fix.
                        if abs(original.startDate.timeIntervalSince(rebuilt.startDate)) < 60 { rebuilt.startDate = original.startDate }
                        rebuilt.origin = original.origin; rebuilt.destination = original.destination; rebuilt.effort = original.effort
                    }
                    // Everything saved here that shares any of its time: two workouts over the same stretch would count
                    // it twice, here and in Apple Health.
                    var overlapping = Self.overlapping(rebuilt.startDate, Self.end(of: rebuilt))
                    if let original, !overlapping.contains(where: { $0.id == original.id }) {
                        overlapping.insert(original, at: 0)
                    }
                    self.preview = Preview(flight: rebuilt, lines: lines, notes: notes, overlapping: overlapping, ownRecording: own)
                    self.busy = false; self.status = nil
                }
            } catch {
                await MainActor.run { self?.busy = false; self?.status = error.localizedDescription }
            }
        }
    }

    func cancel() { cancelFlag.value = true }

    nonisolated private static func build(_ source: Source, own: Bool, rerunFlight: Bool, useLoggedGPS: Bool,
                                          progress: @escaping (Double) -> Void, cancelled: @escaping () -> Bool) throws
        -> (Flight, [(String, String)], [String]) {
        switch source {
        case .saved(let url):
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let theirs = try decoder.decode(Flight.self, from: Data(contentsOf: url))
            var f = Flight(id: UUID(), startDate: theirs.startDate)
            f.endDate = theirs.endDate; f.locations = theirs.locations; f.metrics = theirs.metrics
            f.origin = theirs.origin; f.destination = theirs.destination; f.effort = theirs.effort
            f.workoutType = theirs.workoutType
            f.notes = ([theirs.notes].compactMap { $0 } + ["Imported from another phone's saved workout"]).joined(separator: "\n")
            let km = (theirs.metrics?.totalDistance ?? 0) / 1000
            return (f, [("Source", "A saved workout"), ("Points", "\(theirs.locations.count)"),
                        ("Distance", String(format: "%.1f km", km)),
                        ("Average speed", String(format: "%.1f km/h", (theirs.metrics?.averageSpeed ?? 0) * 3.6))], [])
        case .logs(let set):
            let r = try WorkoutLogReplay.rebuild(set, rerunFlight: rerunFlight, useLoggedGPS: useLoggedGPS,
                                                 runways: { DepartureRunways.axes(nearLatitude: $0, longitude: $1) },
                                                 progress: progress, cancelled: cancelled)
            let flight = makeFlight(r, own: own)
            let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
            let hm = DateFormatter(); hm.dateFormat = "HH:mm:ss"
            var lines: [(String, String)] = [
                ("Recorded by", [r.device, r.build.map { "build " + $0 }].compactMap { $0 }.joined(separator: ", ")),
                ("Started", fmt.string(from: r.start)),
                ("Duration", Self.duration(r.end.timeIntervalSince(r.start))),
                ("Distance", String(format: "%.1f km", (flight.metrics?.totalDistance ?? 0) / 1000)),
                ("Average speed", String(format: "%.1f km/h", (flight.metrics?.averageSpeed ?? 0) * 3.6)),
                ("As the phone drew it", String(format: "%.1f km dead-reckoned", r.recordedDeadReckonedKm)),
                ("Points", "\(r.points.count) (\(r.points.filter { !$0.estimated }.count) from GPS)")]
            if let f = r.flight {
                lines.append(("Takeoff roll", hm.string(from: f.roll)))
                if let l = f.landed { lines.append(("Landing", hm.string(from: l))) }
                lines.append(("In the air", String(format: "%.0f km, re-run with this build", f.kilometres)))
                if let p = f.measuredPush {
                    let used = f.rollDirection.map { abs(($0 - p + 540).truncatingRemainder(dividingBy: 360) - 180) < 0.5 ? "kept" : String(format: "runway %.0f°", $0) } ?? "–"
                    lines.append(("Takeoff push", String(format: "%.0f°, %@", p, used)))
                }
                lines.append(("Turns from the field", "\(f.fieldTurns)"))
            }
            return (flight, lines, r.notes)
        }
    }

    nonisolated private static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60); return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    /// The rebuilt route as this app's own workout: its points, and metrics added up the way a live workout's are.
    nonisolated private static func makeFlight(_ r: WorkoutLogReplay.Result, own: Bool) -> Flight {
        var flight = Flight(id: UUID(), startDate: r.start)
        flight.endDate = r.end
        flight.workoutType = r.workoutTypeRaw
        var metrics = FlightMetrics()
        var locations: [FlightLocation] = []
        locations.reserveCapacity(r.points.count)
        var previous: FlightLocation?
        var previousInFlight = false
        for p in r.points {
            let loc = FlightLocation(id: UUID(), timestamp: p.time, latitude: p.latitude, longitude: p.longitude,
                                     altitude: p.altitude, horizontalAccuracy: p.horizontalAccuracy,
                                     verticalAccuracy: p.estimated ? max(p.horizontalAccuracy, 25) : 10,
                                     speed: p.speed, course: p.course, pressure: nil, satelliteCount: nil,
                                     signalStrength: p.estimated ? 20 : nil, isFiltered: false, isValid: true,
                                     isEstimated: p.estimated)
            let maxBefore = metrics.maxSpeed
            // A flight's typical height never counts as elevation (build 115), nor does the step back to the ground.
            metrics.updateWithLocation(loc, previousLocation: previous, elapsedTime: p.time.timeIntervalSince(r.start),
                                       countElevation: !p.inFlight && !previousInFlight)
            if p.estimated {
                // As live: the drawn speed is the speed, never a geometric spike.
                metrics.currentSpeed = p.speed; metrics.smoothedSpeed = p.speed
                metrics.maxSpeed = max(maxBefore, p.speed)
            }
            // Kilometre splits as the live workout adds them (WorkoutSession, after each point): without this a
            // re-run had one "split" the length of the whole workout.
            metrics.updateSplits(startDate: r.start)
            locations.append(loc); previous = loc; previousInFlight = p.inFlight
        }
        let duration = max(r.end.timeIntervalSince(r.start), 0)
        metrics.calculateAverages(duration: duration)
        metrics.estimateCalories(duration: duration)
        metrics.finalizeSplits()
        metrics.sanitize()
        flight.locations = locations
        flight.metrics = metrics
        flight.notes = own
            ? "Re-run with " + Bundle.appVersionDisplay + " from this phone's recording" + (r.build.map { " (recorded by build " + $0 + ")" } ?? "")
                + (r.flight != nil ? ", flight re-run" : "")
            : "Imported from " + (r.device ?? "another phone") + (r.build.map { " (build " + $0 + ")" } ?? "")
                + (r.flight != nil ? ", flight re-run with " + Bundle.appVersionDisplay : "")
        return flight
    }

    // MARK: - Saving

    /// Saves the preview as a new workout, beside the workouts it overlaps: nothing is deleted (build 132).
    func save(type: HKWorkoutActivityType, toHealth: Bool, done: @escaping (String) -> Void) {
        guard var flight = preview?.flight else { return }
        flight.workoutType = type.rawValue
        busy = true; status = "Saving…"
        FlightDataStore.shared.saveFlight(flight)
        // The list now has another saved workout behind some rows: summed again.
        summaries = [:]
        loadOwnRecordings()
        guard toHealth else {
            busy = false; status = nil; preview = nil
            done("Saved on this phone."); return
        }
        let saved = flight
        HealthKitManager.shared.saveWorkout(flight: saved, locations: saved.locations, metrics: saved.metrics ?? FlightMetrics(),
                                            exactType: true) { [weak self] ok, error, workout in
            DispatchQueue.main.async {
                if let workout { FlightDataStore.shared.updateWorkoutUUID(for: saved.id, workoutUUID: workout.uuid) }
                self?.busy = false; self?.status = nil; self?.preview = nil
                done(ok ? "Saved on this phone and in Apple Health." : "Saved on this phone. Apple Health: \(error?.localizedDescription ?? "not saved").")
            }
        }
    }
}
