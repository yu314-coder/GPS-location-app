import Foundation

/// DEVELOPER MODE: A WORKOUT REBUILT FROM ITS LOGS (build 127).
///
/// Every recording leaves its logs in Documents/VelocityLogs: velocity_events (every GPS fix before any
/// filtering, every barometer reading, the device, build and workout type), velocity_debug (one row per
/// dead-reckoning tick: the distance and direction the app drew) and velocity_raw50hz (the motion the phone
/// felt, 50 times a second, with the magnetic field). Copied from another phone they are enough to put that
/// workout on this one - and, for a flight, to draw it again with THIS build's flight code. That is the point:
/// BR226 was recorded by build 123, whose direction sent the iPhone 17 hundreds of kilometres off; the same
/// sensors through build 126 stay on the airway.
///
/// What is re-run, for the flight only: the takeoff roll (LaunchIntegrator, 30 kt then 200 km/h within 30 s),
/// the direction (FlightHeading: the runway at the last fix, turn episodes, the field check), the cabin as a
/// clock (FlightPhaseEstimator: airborne, descent, landing) and the speed (the measured takeoff, then
/// FlightProfile with the takeoff carried) - the same calls WorkoutSession makes, in the same order. On the
/// ground the route is what the phone drew: its GPS fixes, and its dead-reckoned steps between them. The
/// ground speed engines are not re-run: they answer from the recording phone's own store of examples.
///
/// Foundation only, so a command-line harness on the Mac runs it against the same logs.
enum WorkoutLogReplay {

    // MARK: - The files

    /// One recording's logs, found by the stamp in their names (yyyy-MM-dd_HHmmss of the workout's start).
    struct LogSet: Identifiable {
        let stamp: String
        var debug: URL?
        var events: URL?
        /// The raw motion: the main file, then _part2, _part3... (a relaunch starts a new part).
        var raw: [URL] = []
        var bytes: Int64 = 0
        var id: String { stamp }
        /// A flight can be drawn again only from the raw motion and the events (barometer, fixes, clocks).
        var canRerunFlight: Bool { events != nil && !raw.isEmpty }
    }

    /// The logs and saved workouts among the chosen files; folders are searched.
    static func scan(_ urls: [URL]) -> (logs: [LogSet], saved: [URL]) {
        let fm = FileManager.default
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                    for case let f as URL in e { files.append(f) }
                }
            } else {
                files.append(u)
            }
        }
        var sets: [String: LogSet] = [:]
        var parts: [String: [(Int, URL)]] = [:]
        var saved: [URL] = []
        for f in files {
            let name = f.lastPathComponent
            if name.hasPrefix("flight_details_"), name.hasSuffix(".json") { saved.append(f); continue }
            guard let (kind, stamp, part) = parseName(name) else { continue }
            var s = sets[stamp] ?? LogSet(stamp: stamp)
            switch kind {
            case "debug": s.debug = f
            case "events": s.events = f
            default: parts[stamp, default: []].append((part, f))
            }
            s.bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            sets[stamp] = s
        }
        for (stamp, p) in parts { sets[stamp]?.raw = p.sorted { $0.0 < $1.0 }.map { $0.1 } }
        return (sets.values.filter { $0.debug != nil || $0.events != nil }.sorted { $0.stamp > $1.stamp }, saved)
    }

    /// velocity_<kind>_<stamp>[_partN].csv -> (kind, stamp, part); the watch's logs are not this phone's workout.
    static func parseName(_ name: String) -> (String, String, Int)? {
        guard name.hasPrefix("velocity_"), name.hasSuffix(".csv") else { return nil }
        var rest = String(name.dropFirst("velocity_".count).dropLast(4))
        guard let us = rest.firstIndex(of: "_") else { return nil }
        let kind = String(rest[..<us])
        guard ["debug", "events", "raw50hz"].contains(kind) else { return nil }
        rest = String(rest[rest.index(after: us)...])
        var part = 1
        if let r = rest.range(of: "_part"), let n = Int(rest[r.upperBound...]) { part = n; rest = String(rest[..<r.lowerBound]) }
        guard rest.count == 17 else { return nil }                     // yyyy-MM-dd_HHmmss
        return (kind, rest, part)
    }

    // MARK: - The result

    struct Point {
        var time: Date
        var latitude: Double
        var longitude: Double
        var altitude: Double
        var horizontalAccuracy: Double
        /// m/s, as the app showed it: the fix's own speed, the dead-reckoned tick's, or the flight's.
        var speed: Double
        var course: Double
        var estimated: Bool
        var inFlight: Bool
    }

    struct FlightFound {
        var roll: Date
        var airborne: Date?
        var descent: Date?
        var landed: Date?
        /// The takeoff push as measured, and the direction used (the runway's when it matched).
        var measuredPush: Double?
        var rollDirection: Double?
        var runways: [Double]
        /// Turns whose angle the magnetometer gave (build 126).
        var fieldTurns: Int
        var kilometres: Double
    }

    struct Result {
        var points: [Point]
        var start: Date
        var end: Date
        var device: String?
        var build: String?
        var workoutTypeRaw: UInt?
        var flight: FlightFound?
        var rerun: Bool
        /// The distance the phone itself drew (its dead-reckoned ticks), for comparison.
        var recordedDeadReckonedKm: Double
        var notes: [String]
    }

    enum ReplayError: LocalizedError {
        case noLogs, noPosition
        var errorDescription: String? {
            switch self {
            case .noLogs: return "No velocity_events or velocity_debug file for this recording."
            case .noPosition: return "The logs hold no GPS fix to start the route from."
            }
        }
    }

    // MARK: - Reading

    /// Lines of a text file, read a megabyte at a time (a four-hour raw log is about 200 MB).
    static func forEachLine(_ url: URL, _ body: (Substring) throws -> Bool) throws {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var carry = Data()
        while true {
            let chunk = try h.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            carry.append(chunk)
            var start = carry.startIndex
            while let nl = carry[start...].firstIndex(of: 0x0A) {
                var end = nl
                if end > start, carry[carry.index(before: end)] == 0x0D { end = carry.index(before: end) }
                if try !body(Substring(String(decoding: carry[start..<end], as: UTF8.self))) { return }
                start = carry.index(after: nl)
            }
            carry = Data(carry[start...])
        }
        if !carry.isEmpty { _ = try body(Substring(String(decoding: carry, as: UTF8.self))) }
    }

    struct Fix { var t: TimeInterval; var lat: Double; var lon: Double; var alt: Double; var hAcc: Double; var speed: Double; var course: Double }
    struct Baro { var t: TimeInterval; var rel: Double }
    struct Tick { var t: TimeInterval; var distance: Double; var heading: Double; var speed: Double }

    struct Events {
        var fixes: [Fix] = []
        var baro: [Baro] = []
        var rawStart: [String: TimeInterval] = [:]
        var first: TimeInterval?
        var last: TimeInterval?
        var stop: TimeInterval?
        var device: String?
        var build: String?
        var workoutType: UInt?
        var velocityModeAtStart = false
        var velocityMode: [(TimeInterval, Bool)] = []
        var forcedFlight = false
    }

    static func readEvents(_ url: URL) throws -> Events {
        var ev = Events()
        var col: [String: Int] = [:]
        try forEachLine(url) { line in
            if col.isEmpty {
                for (i, c) in line.split(separator: ",").enumerated() { col[String(c)] = i }
                return true
            }
            // The detail (last) may be quoted and hold commas.
            let f = line.split(separator: ",", maxSplits: 13, omittingEmptySubsequences: false)
            guard f.count >= 14, let t = Double(f[col["unix_s"] ?? 1]) else { return true }
            let kind = f[col["kind"] ?? 2]
            var detail = String(f[13]); if detail.hasPrefix("\""), detail.hasSuffix("\""), detail.count >= 2 { detail = String(detail.dropFirst().dropLast()) }
            ev.first = min(ev.first ?? t, t); ev.last = max(ev.last ?? t, t)
            let num = { (k: String) -> Double? in col[k].flatMap { Double(f[$0]) } }
            switch kind {
            case "gps":
                if let la = num("lat"), let lo = num("lon"), la.isFinite, lo.isFinite, abs(la) <= 90 {
                    ev.fixes.append(Fix(t: t, lat: la, lon: lo, alt: num("alt_m") ?? 0, hAcc: num("h_acc_m") ?? 9999,
                                        speed: num("speed_ms") ?? -1, course: num("course_deg") ?? -1))
                }
            case "baro":
                if let r = num("rel_alt_m"), r.isFinite { ev.baro.append(Baro(t: t, rel: r)) }
            case "raw_start": ev.rawStart[detail] = t
            case "stop": ev.stop = t
            case "velocity_mode": ev.velocityMode.append((t, detail == "on"))
            case "flight_forced": ev.forcedFlight = true
            case "session":
                for part in detail.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if part.hasPrefix("app ") { ev.build = String(part.dropFirst(4)) }
                    else if part.hasPrefix("device ") { ev.device = String(part.dropFirst(7)) }
                    else if part.hasPrefix("workout type "), let n = UInt(part.dropFirst(13)) { ev.workoutType = n }
                    else if part.hasPrefix("velocity mode ") { ev.velocityModeAtStart = part.hasSuffix("on") }
                }
            default: break
            }
            return true
        }
        ev.fixes.sort { $0.t < $1.t }; ev.baro.sort { $0.t < $1.t }; ev.velocityMode.sort { $0.0 < $1.0 }
        return ev
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func readTicks(_ url: URL) throws -> [Tick] {
        var ticks: [Tick] = []
        var col: [String: Int] = [:]
        try forEachLine(url) { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            if col.isEmpty { for (i, c) in f.enumerated() { col[String(c)] = i }; return true }
            guard let ti = col["time"], ti < f.count,
                  let date = iso.date(from: String(f[ti])) ?? isoPlain.date(from: String(f[ti])) else { return true }
            let num = { (k: String) -> Double in col[k].flatMap { $0 < f.count ? Double(f[$0]) : nil } ?? 0 }
            ticks.append(Tick(t: date.timeIntervalSince1970, distance: num("distance_m"), heading: num("heading_deg"),
                              speed: num("reported_speed_kmh") / 3.6))
            return true
        }
        return ticks.sorted { $0.t < $1.t }
    }

    // MARK: - The flight, re-run on the raw motion

    struct FlightRun {
        var roll: TimeInterval?
        var airborne: TimeInterval?
        var descent: TimeInterval?
        var landed: TimeInterval?
        var handover: (sinceRoll: Double, kmh: Double)?
        /// Once a second: the measured takeoff while it integrates, and FlightHeading's heading.
        var launch: [(TimeInterval, Double)] = []
        var headings: [(TimeInterval, Double)] = []
        var measuredPush: Double?
        var rollDirection: Double?
        var runways: [Double] = []
        var fieldTurns = 0
        var lastSample: TimeInterval?
        /// Every takeoff roll confirmed in the motion log, and the push each one measured.
        var rollsFound: [(TimeInterval, Double?)] = []
    }

    // WorkoutSession's own thresholds (ROLL_START_SPEED, ROLL_CONFIRM_SPEED, ROLL_CONFIRM_WITHIN, TAKEOFF_CONFIRM_WITHIN).
    static let ROLL_START_SPEED = 15.43
    static let ROLL_CONFIRM_SPEED = 55.6
    static let ROLL_CONFIRM_WITHIN: TimeInterval = 30
    static let TAKEOFF_CONFIRM_WITHIN: TimeInterval = 240

    /// Every confirmed takeoff roll, with what its integration measured.
    private struct Roll {
        var t: TimeInterval
        var anchor: Int
        var handover: (sinceRoll: Double, kmh: Double)?
        var launch: [(TimeInterval, Double)] = []
        var push: Double?
        var direction: Double?
        var runways: [Double]
    }
    /// Every stretch the cabin read as airborne.
    private struct Episode { var start: TimeInterval; var end: TimeInterval?; var climbConfirmed = false; var descent: TimeInterval? }

    static func runFlight(_ set: LogSet, events ev: Events, runways: (Double, Double) -> [Double],
                          progress: (Double) -> Void, cancelled: () -> Bool) throws -> (FlightRun, [String]) {
        var notes: [String] = []
        var li = LaunchIntegrator()
        var fh = FlightHeading()
        let phase = FlightPhaseEstimator()
        var rolls: [Roll] = []
        var episodes: [Episode] = []
        var headings: [(TimeInterval, Double)] = []
        var fieldTurnTimes: [TimeInterval] = []
        var rollCandidateAt: TimeInterval?, rollCandidateAnchor = -1
        var candidateLaunch: [(TimeInterval, Double)] = []      // the integration since a candidate roll began
        var takeoffRollAt: TimeInterval?
        var bi = 0, gi = 0
        var lastFix: Fix?
        var lastT: TimeInterval?, lastSample: TimeInterval?
        var lastSecond = -Double.infinity
        var lastMagAt: Date?
        let totalBytes = max(set.raw.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }, 1)
        var readBytes: Int64 = 0, reported = 0.0

        // WorkoutSession's airborne bookkeeping: a landing ends the flight's heading.
        func ingestBaro(_ b: Baro) {
            phase.ingest(relativeAltitude: b.rel, at: Date(timeIntervalSince1970: b.t))
            if phase.isAirborne {
                if episodes.last.map({ $0.end != nil }) ?? true { episodes.append(Episode(start: b.t)) }
                if phase.climbConfirmed { episodes[episodes.count - 1].climbConfirmed = true }
                if episodes[episodes.count - 1].descent == nil, let d = phase.descentStartedAt {
                    episodes[episodes.count - 1].descent = d.timeIntervalSince1970
                }
            } else if let last = episodes.last, last.end == nil {
                episodes[episodes.count - 1].end = b.t
                fh.endFlight()
            }
        }

        for (k, url) in set.raw.enumerated() {
            let name = url.lastPathComponent
            guard let t0 = ev.rawStart[name] ?? (k == 0 ? ev.first : nil) else {
                notes.append("\(name): no start time in the events, left out"); continue
            }
            var col: [String: Int] = [:]
            try forEachLine(url) { line in
                readBytes += Int64(line.utf8.count + 1)
                if col.isEmpty { for (i, c) in line.split(separator: ",").enumerated() { col[String(c)] = i }; return true }
                let f = line.split(separator: ",", omittingEmptySubsequences: false)
                func v(_ k: String) -> Double { guard let i = col[k], i < f.count else { return .nan }; return Double(f[i]) ?? .nan }
                let ts = v("t_seconds"); guard ts.isFinite else { return true }
                let t = t0 + ts
                while bi < ev.baro.count, ev.baro[bi].t <= t { ingestBaro(ev.baro[bi]); bi += 1 }
                while gi < ev.fixes.count, ev.fixes[gi].t <= t { lastFix = ev.fixes[gi]; gi += 1 }
                let ua = [v("dev_accel_x"), v("dev_accel_y"), v("dev_accel_z")]
                let g = [v("gravity_x"), v("gravity_y"), v("gravity_z")]
                let w = [v("rot_x"), v("rot_y"), v("rot_z")]
                let north = v("north_accel_ms2"), east = v("east_accel_ms2")
                guard (ua + g + w).allSatisfy({ $0.isFinite }) else { return true }
                let date = Date(timeIntervalSince1970: t)
                let dt = lastT.map { min(max(t - $0, 0), 0.2) } ?? 0
                lastT = t; lastSample = t
                // WorkoutSession.onRawMotionSample, in its order.
                let underway = takeoffRollAt.map { !phase.isAirborne && t - $0 < TAKEOFF_CONFIRM_WITHIN } ?? false
                li.ingest(userAcceleration: ua, gravity: g, rotation: w, dt: dt, airborne: phase.isAirborne || underway)
                // noteTakeoffRoll
                if li.anchorCount != rollCandidateAnchor { rollCandidateAnchor = li.anchorCount; rollCandidateAt = nil }
                if let speed = li.speed {
                    if speed < ROLL_START_SPEED {
                        rollCandidateAt = nil; candidateLaunch.removeAll(keepingCapacity: true)
                    } else if rollCandidateAt == nil {
                        rollCandidateAt = t; candidateLaunch = [(t, speed)]
                        fh.beginRoll(at: date, cabinAirborne: phase.isAirborne)
                        if let fix = lastFix, fix.hAcc >= 0, fix.hAcc <= 3000, t - fix.t < 6 * 3600 {
                            fh.departureRunways = runways(fix.lat, fix.lon)
                        } else { fh.departureRunways = [] }
                    }
                    if let s = rollCandidateAt, speed >= ROLL_CONFIRM_SPEED, takeoffRollAt != s, t - s <= ROLL_CONFIRM_WITHIN {
                        takeoffRollAt = s
                        rolls.append(Roll(t: s, anchor: li.anchorCount, launch: candidateLaunch, runways: fh.departureRunways))
                        fh.confirmRoll(startedAt: Date(timeIntervalSince1970: s))
                    }
                }
                if var r = rolls.last, r.anchor == li.anchorCount {
                    // The handover: the first moment the integration of this roll holds what it reached.
                    if r.handover == nil, li.isHolding, let held = li.speed, held > 0 { r.handover = (t - r.t, held * 3.6) }
                    if t - lastSecond >= 1, let speed = li.speed, speed > 0, !li.isHolding { r.launch.append((t, speed)) }
                    rolls[rolls.count - 1] = r
                }
                fh.addRollAcceleration(north: north, east: east, at: date)
                let gm = (g[0] * g[0] + g[1] * g[1] + g[2] * g[2]).squareRoot()
                if gm > 0.5 {
                    let fx = ua[0] + g[0], fy = ua[1] + g[1], fz = ua[2] + g[2]
                    let mx = v("mag_x_ut"), my = v("mag_y_ut"), mz = v("mag_z_ut"), macc = v("mag_accuracy")
                    let field: (Double, Double, Double)? = (mx.isFinite && my.isFinite && mz.isFinite && macc.isFinite && macc >= 0) ? (mx, my, mz) : nil
                    fh.ingest(rotationAboutDown: (w[0] * g[0] + w[1] * g[1] + w[2] * g[2]) / gm * 180 / .pi,
                              force: (fx * fx + fy * fy + fz * fz).squareRoot(),
                              rotationMagnitude: (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).squareRoot() * 180 / .pi,
                              down: (g[0], g[1], g[2]), field: field, dt: dt, at: date)
                }
                if let p = fh.measuredRollDirection, var r = rolls.last, r.push == nil, r.anchor == li.anchorCount || r.t <= t {
                    r.push = p; r.direction = fh.rollDirection; rolls[rolls.count - 1] = r
                }
                if let m = fh.lastMagneticTurn, m.at != lastMagAt { lastMagAt = m.at; fieldTurnTimes.append(t) }
                if t - lastSecond >= 1 {
                    lastSecond = t
                    if rollCandidateAt != nil, takeoffRollAt != rollCandidateAt, let speed = li.speed { candidateLaunch.append((t, speed)) }
                    if let h = fh.heading { headings.append((t, h)) }
                    let p = Double(readBytes) / Double(totalBytes)
                    if p - reported >= 0.01 { reported = p; progress(min(p, 1)) }
                }
                return !cancelled()
            }
        }
        // The cabin goes on after the motion log ends (a log cut short still lands).
        while bi < ev.baro.count { ingestBaro(ev.baro[bi]); bi += 1 }

        // WorkoutSession.flightRollStart: the flight is the first airborne stretch with a roll found in the 15 minutes
        // before it, or - with no roll - one whose climb confirmed a flight, timed from two minutes before it.
        var run = FlightRun(); run.lastSample = lastSample
        run.rollsFound = rolls.map { ($0.t, $0.push) }
        for e in episodes {
            if let r = rolls.last(where: { $0.t <= e.start && e.start - $0.t < 15 * 60 }) {
                run.roll = r.t; run.handover = r.handover; run.launch = r.launch
                run.measuredPush = r.push; run.rollDirection = r.direction; run.runways = r.runways
            } else if e.climbConfirmed {
                run.roll = e.start - 120
                notes.append("No takeoff roll in the motion log: timed from the cabin's climb")
            } else { continue }
            run.airborne = e.start; run.descent = e.descent; run.landed = e.end
            break
        }
        if let r = run.roll {
            let end = run.landed ?? lastSample ?? .infinity
            run.headings = headings.filter { $0.0 >= r && $0.0 <= end }
            run.fieldTurns = fieldTurnTimes.filter { $0 >= r && $0 <= end }.count
            if episodes.filter({ $0.climbConfirmed }).count > 1 { notes.append("More than one flight in the logs: the first is re-run") }
        } else if !rolls.isEmpty {
            notes.append("A takeoff roll but no flight in the cabin's pressure: not drawn as a flight")
        }
        return (run, notes)
    }

    // MARK: - The route

    /// `useLoggedGPS`: in Force Velocity the app draws the route without GPS and logs the fixes only as an answer
    /// key; by default they are left out here too, as the phone drew it. The first fix always starts the route.
    static func rebuild(_ set: LogSet, rerunFlight: Bool, useLoggedGPS: Bool = false, runways: @escaping (Double, Double) -> [Double],
                        progress: @escaping (Double) -> Void = { _ in }, cancelled: @escaping () -> Bool = { false }) throws -> Result {
        guard set.events != nil || set.debug != nil else { throw ReplayError.noLogs }
        let ev = try set.events.map(readEvents) ?? Events()
        let ticks = try set.debug.map(readTicks) ?? []
        var notes: [String] = []
        if ev.forcedFlight { notes.append("The flight button was used; the re-run finds the flight from the sensors instead") }

        var run: FlightRun?
        if rerunFlight, set.canRerunFlight {
            let (r, n) = try runFlight(set, events: ev, runways: runways, progress: progress, cancelled: cancelled)
            notes += n
            if r.roll != nil { run = r } else { notes.append("No flight found in the logs: the route is as recorded") }
        }
        let roll = run?.roll
        let flightEnd = run.map { $0.landed ?? $0.lastSample ?? ev.last ?? 0 }
        func inFlight(_ t: TimeInterval) -> Bool { guard let r = roll, let e = flightEnd else { return false }; return t >= r && t <= e }
        func velocityOn(_ t: TimeInterval) -> Bool {
            var on = ev.velocityModeAtStart
            for (vt, v) in ev.velocityMode where vt <= t { on = v }
            return on
        }
        // The flight's speed (m/s) and direction at a moment, as WorkoutSession's airSpeed draws them.
        let handoverAt = run.flatMap { r in r.handover.map { (r.roll ?? 0) + $0.sinceRoll } } ?? .infinity
        func launchSpeed(_ t: TimeInterval) -> Double? {
            guard let L = run?.launch, !L.isEmpty, t < handoverAt else { return nil }
            var lo = 0, hi = L.count - 1
            while lo < hi { let m = (lo + hi + 1) / 2; if L[m].0 <= t { lo = m } else { hi = m - 1 } }
            return abs(L[lo].0 - t) <= 2 ? L[lo].1 : nil
        }
        func airSpeed(_ t: TimeInterval) -> Double {
            if let l = launchSpeed(t) { return l }
            guard let r = roll else { return 0 }
            let d = run?.descent.flatMap { t >= $0 ? t - $0 : nil }
            return FlightProfile.speedKmh(sinceRoll: t - r, sinceDescent: d,
                                          handoverSinceRoll: run?.handover?.sinceRoll, handoverKmh: run?.handover?.kmh) / 3.6
        }
        func heading(_ t: TimeInterval) -> Double? {
            guard let H = run?.headings, !H.isEmpty else { return run?.rollDirection }
            if t <= H[0].0 { return H[0].1 }
            var lo = 0, hi = H.count - 1
            while lo < hi { let m = (lo + hi + 1) / 2; if H[m].0 <= t { lo = m } else { hi = m - 1 } }
            return H[lo].1
        }

        // Everything that moves the route, in time order.
        enum Step { case fix(Fix), tick(Tick), air(TimeInterval) }
        var steps: [(TimeInterval, Int, Step)] = []
        for f in ev.fixes where f.hAcc >= 0 && f.hAcc <= 50 { steps.append((f.t, 0, .fix(f))) }
        for k in ticks { steps.append((k.t, 1, .tick(k))) }
        if let r = roll, let e = flightEnd {
            var t = r.rounded(.down)
            while t <= e { steps.append((t, 2, .air(t))); t += 1 }
        }
        steps.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }

        // The start: the first good fix; dead-reckoned ticks before it are laid down from it, as the app does.
        let anchor = ev.fixes.first(where: { $0.hAcc >= 0 && $0.hAcc <= 100 }) ?? ev.fixes.first(where: { $0.hAcc >= 0 && $0.hAcc <= 3000 })
        guard let first = anchor else { throw ReplayError.noPosition }
        var points: [Point] = []
        var lat = first.lat, lon = first.lon, lastPointT = first.t
        var anchorAcc = max(first.hAcc, 5), sinceFix = 0.0
        var lastGoodFix = -Double.infinity
        var baseAlt = first.alt
        var recordedKm = 0.0
        points.append(Point(time: Date(timeIntervalSince1970: first.t), latitude: lat, longitude: lon, altitude: first.alt,
                            horizontalAccuracy: first.hAcc, speed: max(first.speed, 0), course: max(first.course, 0),
                            estimated: false, inFlight: false))
        func step(_ t: TimeInterval, distance: Double, heading h: Double, speed: Double, air: Bool) {
            let since = max(t - lastPointT, 0)
            let limit = max(2 * max(speed, 0) * min(max(since, 1), 10), 200)
            let d = min(max(distance, 0), limit)
            guard d > 0 else { return }
            (lat, lon) = project(lat, lon, d, h)
            let acc = min(anchorAcc + 0.10 * sinceFix, 250)
            sinceFix += d
            var alt = baseAlt
            if air, let r = roll {
                let dsc = run?.descent.flatMap { t >= $0 ? t - $0 : nil }
                alt = baseAlt + FlightProfile.altitudeMeters(sinceRoll: t - r, sinceDescent: dsc)
            }
            points.append(Point(time: Date(timeIntervalSince1970: t), latitude: lat, longitude: lon, altitude: alt,
                                horizontalAccuracy: acc, speed: air ? speed : d / max(since, 0.5), course: h,
                                estimated: true, inFlight: air))
            lastPointT = t
        }
        let total = Double(max(steps.count, 1))
        for (i, (t, _, s)) in steps.enumerated() {
            if i % 5000 == 0 { progress(run == nil ? Double(i) / total : 1) }
            switch s {
            case .fix(let f):
                guard f.t > first.t else { continue }
                // A fix counts only where the phone was using GPS (Force Velocity off), unless asked for the answer key.
                if velocityOn(f.t), !useLoggedGPS { continue }
                lat = f.lat; lon = f.lon; anchorAcc = max(f.hAcc, 5); sinceFix = 0; lastGoodFix = f.t
                if !inFlight(f.t) { baseAlt = f.alt }
                points.append(Point(time: Date(timeIntervalSince1970: f.t), latitude: f.lat, longitude: f.lon, altitude: f.alt,
                                    horizontalAccuracy: f.hAcc, speed: max(f.speed, 0), course: max(f.course, 0),
                                    estimated: false, inFlight: inFlight(f.t)))
                lastPointT = f.t
            case .tick(let k):
                recordedKm += k.distance / 1000
                if inFlight(k.t) || k.t - lastGoodFix < 3 || k.t < first.t { continue }
                step(k.t, distance: k.distance, heading: k.heading, speed: k.speed, air: false)
            case .air(let t):
                if t - lastGoodFix < 3 { continue }
                let v = airSpeed(t)
                guard let h = heading(t) else { continue }
                step(t, distance: v, heading: h, speed: v, air: true)
            }
        }
        // Ticks recorded before the first fix (a workout begun without GPS) are laid down after it, as the app does.
        let early = ticks.filter { $0.t < first.t && !inFlight($0.t) }
        if !early.isEmpty { notes.append("\(early.count) dead-reckoned ticks before the first fix are left out") }

        var found: FlightFound?
        if let r = run, let rt = r.roll {
            let km = zip(points.dropFirst(), points).reduce(0.0) { acc, p in
                p.0.inFlight ? acc + haversine(p.1.latitude, p.1.longitude, p.0.latitude, p.0.longitude) : acc } / 1000
            found = FlightFound(roll: Date(timeIntervalSince1970: rt), airborne: r.airborne.map { Date(timeIntervalSince1970: $0) },
                                descent: r.descent.map { Date(timeIntervalSince1970: $0) }, landed: r.landed.map { Date(timeIntervalSince1970: $0) },
                                measuredPush: r.measuredPush, rollDirection: r.rollDirection, runways: r.runways,
                                fieldTurns: r.fieldTurns, kilometres: km)
        }
        let start = [ev.first, ticks.first?.t, first.t].compactMap { $0 }.min() ?? first.t
        let end = max([ev.stop, ev.last, ticks.last?.t, points.last?.time.timeIntervalSince1970].compactMap { $0 }.max() ?? start, start)
        progress(1)
        return Result(points: points, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
                      device: ev.device, build: ev.build, workoutTypeRaw: ev.workoutType, flight: found,
                      rerun: run != nil, recordedDeadReckonedKm: recordedKm, notes: notes)
    }

    // MARK: - Geometry

    static func project(_ lat: Double, _ lon: Double, _ distance: Double, _ bearing: Double) -> (Double, Double) {
        let R = 6_371_000.0, la = lat * .pi / 180, lo = lon * .pi / 180, b = bearing * .pi / 180, d = distance / R
        let la2 = asin(sin(la) * cos(d) + cos(la) * sin(d) * cos(b))
        let lo2 = lo + atan2(sin(b) * sin(d) * cos(la), cos(d) - sin(la) * sin(la2))
        return (la2 * 180 / .pi, ((lo2 * 180 / .pi) + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    static func haversine(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = Double.pi / 180, a = sin((la2 - la1) * r / 2), b = sin((lo2 - lo1) * r / 2)
        return 2 * 6_371_000 * asin(min(1, (a * a + cos(la1 * r) * cos(la2 * r) * b * b).squareRoot()))
    }
}
