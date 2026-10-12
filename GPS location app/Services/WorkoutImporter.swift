import Foundation
import HealthKit

/// DEVELOPER MODE: PUT A WORKOUT FROM ANOTHER PHONE ON THIS ONE (build 127).
///
/// Two kinds of file come across from the other phone (AirDrop, Files, or its Developer screen's "Share all"):
///   - its logs (velocity_events / velocity_debug / velocity_raw50hz for one recording), rebuilt by
///     WorkoutLogReplay - a flight in them drawn again with this build's flight code;
///   - a saved workout (flight_details_<id>.json from its Documents), taken as that phone saved it.
/// Either becomes a new workout here, with the type chosen for it, and optionally goes to Apple Health with exactly
/// that type. It never deletes anything unless asked to replace this phone's own workout from the same moment.
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
        /// This phone's own workout from the same moment, if there is one.
        var sameMoment: Flight?
    }

    @Published private(set) var sources: [Source] = []
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

    // MARK: - Reading

    func read(_ source: Source, rerunFlight: Bool, useLoggedGPS: Bool) {
        busy = true; progress = 0; preview = nil; cancelFlag.value = false
        let flag = cancelFlag
        status = rerunFlight ? "Reading the logs and re-running the flight…" : "Reading…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (flight, lines, notes) = try Self.build(source, rerunFlight: rerunFlight, useLoggedGPS: useLoggedGPS,
                    progress: { p in Task { @MainActor in self?.progress = p } },
                    cancelled: { flag.value })
                await MainActor.run {
                    guard let self else { return }
                    let same = FlightDataStore.shared.savedFlights.first { abs($0.startDate.timeIntervalSince(flight.startDate)) < 180 }
                    self.preview = Preview(flight: flight, lines: lines, notes: notes, sameMoment: same)
                    self.busy = false; self.status = nil
                }
            } catch {
                await MainActor.run { self?.busy = false; self?.status = error.localizedDescription }
            }
        }
    }

    func cancel() { cancelFlag.value = true }

    nonisolated private static func build(_ source: Source, rerunFlight: Bool, useLoggedGPS: Bool,
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
                        ("Distance", String(format: "%.1f km", km))], [])
        case .logs(let set):
            let r = try WorkoutLogReplay.rebuild(set, rerunFlight: rerunFlight, useLoggedGPS: useLoggedGPS,
                                                 runways: { DepartureRunways.axes(nearLatitude: $0, longitude: $1) },
                                                 progress: progress, cancelled: cancelled)
            let flight = makeFlight(r)
            let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
            let hm = DateFormatter(); hm.dateFormat = "HH:mm:ss"
            var lines: [(String, String)] = [
                ("Recorded by", [r.device, r.build.map { "build " + $0 }].compactMap { $0 }.joined(separator: ", ")),
                ("Started", fmt.string(from: r.start)),
                ("Duration", Self.duration(r.end.timeIntervalSince(r.start))),
                ("Distance", String(format: "%.1f km", (flight.metrics?.totalDistance ?? 0) / 1000)),
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
    nonisolated private static func makeFlight(_ r: WorkoutLogReplay.Result) -> Flight {
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
            locations.append(loc); previous = loc; previousInFlight = p.inFlight
        }
        let duration = max(r.end.timeIntervalSince(r.start), 0)
        metrics.calculateAverages(duration: duration)
        metrics.estimateCalories(duration: duration)
        metrics.finalizeSplits()
        metrics.sanitize()
        flight.locations = locations
        flight.metrics = metrics
        flight.notes = "Imported from " + (r.device ?? "another phone") + (r.build.map { " (build " + $0 + ")" } ?? "")
            + (r.flight != nil ? ", flight re-run with " + Bundle.appVersionDisplay : "")
        return flight
    }

    // MARK: - Saving

    func save(type: HKWorkoutActivityType, toHealth: Bool, replaceSameMoment: Bool, done: @escaping (String) -> Void) {
        guard var flight = preview?.flight else { return }
        flight.workoutType = type.rawValue
        busy = true; status = "Saving…"
        if replaceSameMoment, let old = preview?.sameMoment {
            FlightDataStore.shared.deleteFlight(old)
            if let uuid = old.workoutUUID {
                HealthKitManager.shared.fetchWorkout(uuid: uuid) { workout, _ in
                    if let workout { HealthKitManager.shared.deleteWorkout(workout) { _, _ in } }
                }
            }
        }
        FlightDataStore.shared.saveFlight(flight)
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
