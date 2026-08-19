import Foundation
import UIKit

/// Records one row per dead-reckoning tick so a session can be examined AFTER the fact.
///
/// This exists because offline simulation kept failing to reproduce what the app actually did.
/// Synthetic signals validate whatever assumption they were built on, so a model that looked
/// accurate to under a kilometre per hour in simulation still reported half the true speed on
/// the road. The only way to close that gap is to capture the real inputs — the vibration
/// feature, the fitted coefficients, the calibration coverage, and the raw sensor values — at
/// the moment a wrong number is produced, and read them back.
///
/// Deliberately allocation-light and bounded: a fixed-capacity ring buffer, one small struct per
/// second, so a multi-hour flight cannot exhaust memory.
final class SessionDiagnosticsRecorder: ObservableObject {

    struct Row {
        let t: Date
        let source: String
        let activity: String
        let reportedSpeed: Double        // m/s, what the app displayed
        let distanceAdded: Double        // m this tick
        let heading: Double
        let compass: Double?
        let offset: Double?
        // Vibration model internals
        let feature: Double
        let p0: Double, p1: Double, p2: Double
        let minCalU: Double, maxCalU: Double
        let minCalSpeed: Double, maxCalSpeed: Double
        let calSamples: Double
        let extrapolating: Bool
        // Raw context
        /// Seconds since the previous tick. Normally ~1. A 21-minute drive contained one gap of
        /// 371 s where iOS had suspended the app, costing 2.4 km and 29% of the workout, and
        /// nothing in the log said so - it had to be recovered by differencing timestamps. A
        /// column makes the next one obvious.
        let tickInterval: Double
        /// How far this workout's signature sits from the closest one the model has learned
        /// before. Measured across six sessions: same vehicle and carry 0.54-1.70, same vehicle
        /// different carry 1.81-2.87, different vehicle 4.30-6.97. A large value means the speed
        /// being reported is an answer about a regime the model has never seen.
        let regimeDistance: Double?
        let handlingRotation: Double
        /// NO USABLE HEADING.
        ///
        /// Set when the walking axis has been refused continuously while stepping AND the device
        /// is rotating freely in the hand. On a 3-minute walk that produced a route of the right
        /// LENGTH (165 m, correct) in entirely the wrong SHAPE — ending 73 m from the start when
        /// the true route was an out-and-back returning to it - both conditions held for the
        /// whole session and nothing recorded that. The route was drawn with the same confidence
        /// as any other. This column is what distinguishes "the heading was wrong" from "the app
        /// never had one".
        let headingUnreliable: Bool
        /// Resolved walking axis and the smoothed skew vote that decides which of its two ends
        /// is forward. Recorded because that single binary choice is what turns a whole route
        /// 180°, and it was previously invisible in every log.
        let walkAxis: Double?
        let walkSkew: Double?
        /// The axis before the gate, and whether the gate refused it — so a log can show
        /// whether the gate is protecting the heading or starving it.
        let walkAxisRaw: Double?
        let walkAxisGated: Double?
        /// What the learned speed model actually knows: how many observations, the fastest it
        /// has ever been taught, and the compression correction in force.
        let learnObs: Double?
        let learnMaxKmh: Double?
        let learnSlope: Double?
        let gpsSpeed: Double?
        let gpsAccuracy: Double?
        let latitude: Double?
        let longitude: Double?
        /// Where GPS says we ACTUALLY are, recorded even in Force Velocity where GPS is
        /// excluded from the route. Without it the file holds only the dead-reckoned track and
        /// its error can be judged by eye against a map but never measured.
        let truthLatitude: Double?
        let truthLongitude: Double?
        let accelMagnitude: Double?
        let rotationRate: Double?
        let pitch: Double?, roll: Double?, yaw: Double?
        let altitude: Double?
    }

    /// ~4 hours at 1 Hz. Oldest rows are dropped rather than growing without bound.
    private let capacity = 15000
    private var rows: [Row] = []
    /// Published only as a count so views can show progress without copying the buffer.
    @Published private(set) var rowCount: Int = 0
    /// Most recent row, for the live debug readout.
    @Published private(set) var latest: Row?

    func reset() {
        try? rawFileHandle?.close()
        rawFileHandle = nil
        rawFileURL = nil
        rawSamplesWritten = 0
        pendingDeviceMotion = nil
        rows.removeAll(keepingCapacity: true)
        raw.removeAll(keepingCapacity: true)
        rawStart = nil
        rowCount = 0
        latest = nil
    }

    func record(_ row: Row) {
        rows.append(row)
        if rows.count > capacity { rows.removeFirst(rows.count - capacity) }
        rowCount = rows.count
        latest = row
    }

    var isEmpty: Bool { rows.isEmpty }

    // MARK: - Raw high-rate capture
    //
    // Three different vibration features have now been designed, shipped and failed: amplitude
    // (turned out to measure road roughness), the E|ẋ|/E|x| frequency ratio (constant on a
    // broadband signal), and a 2–18 Hz band centroid (barely moved — a real drive at 40–100 km/h
    // reported a 15–26 km/h span). Each was validated against a synthetic signal that encoded
    // the very assumption under test, so each test passed and each feature failed on the road.
    //
    // A fourth guess is not worth shipping. What is missing is the actual spectrum of this
    // phone in this car: whether a wheel-rotation peak exists above the broadband road noise at
    // all, and if so where it sits and how it moves with speed. That is answerable in one drive
    // from the raw samples, and answerable no other way. So capture them.
    //
    // 50 Hz vertical acceleration with the GPS speed at that moment. ~30 minutes at a bounded
    // 90k samples; the oldest are dropped rather than growing without limit.
    struct RawSample {
        let t: TimeInterval        // seconds since capture start
        let verticalAccel: Double  // world-frame, gravity removed, m/s²
        let gpsSpeed: Double       // m/s, negative when unknown
        // HORIZONTAL residual, world frame. Added because the walking-axis resolution — the
        // thing that decides which end of the PCA axis is "forward", and therefore whether a
        // whole route is drawn 180° out — is computed from exactly these two numbers, and with
        // only the vertical channel recorded it could not be replayed or tested offline. A
        // candidate rule can now be scored against a real walk before it is shipped.
        let northAccel: Double     // m/s², bias-removed
        let eastAccel: Double      // m/s², bias-removed
        // RAW, DEVICE FRAME, UNPROCESSED. Everything above is this app's interpretation of the
        // sensor; these are the sensor. With acceleration, gravity, rotation rate and attitude
        // recorded as reported, any part of the pipeline — bias removal, the world-frame
        // rotation, the heading — can be re-derived offline from a flight that cannot be flown
        // again. Without them a mistake in that pipeline is permanent.
        var deviceAccelX: Double = 0
        var deviceAccelY: Double = 0
        var deviceAccelZ: Double = 0
        var gravityX: Double = 0
        var gravityY: Double = 0
        var gravityZ: Double = 0
        var rotationX: Double = 0
        var rotationY: Double = 0
        var rotationZ: Double = 0
        var roll: Double = 0
        var pitch: Double = 0
        var yaw: Double = 0
        var motionHeading: Double = -1
    }
    /// Latest unprocessed motion, stamped onto the next raw sample.
    private var pendingDeviceMotion: (ax: Double, ay: Double, az: Double,
                                      gx: Double, gy: Double, gz: Double,
                                      rx: Double, ry: Double, rz: Double,
                                      roll: Double, pitch: Double, yaw: Double,
                                      motionHeading: Double)?

    func noteDeviceMotion(accelX: Double, accelY: Double, accelZ: Double,
                          gravityX: Double, gravityY: Double, gravityZ: Double,
                          rotationX: Double, rotationY: Double, rotationZ: Double,
                          roll: Double, pitch: Double, yaw: Double, motionHeading: Double) {
        pendingDeviceMotion = (accelX, accelY, accelZ, gravityX, gravityY, gravityZ,
                               rotationX, rotationY, rotationZ, roll, pitch, yaw, motionHeading)
    }
    private var raw: [RawSample] = []
    /// STREAMED TO DISK, NOT HELD IN MEMORY.
    ///
    /// This used to keep the last 90,000 samples and drop the oldest — thirty minutes at 50 Hz.
    /// For a three-hour flight that is the last half hour and nothing else, which is precisely
    /// backwards: the takeoff and climb, where the acceleration that sets the whole speed
    /// estimate happens, would be the first thing discarded. And a flight is the one recording
    /// that cannot be repeated.
    ///
    /// So samples are appended to a file as they accumulate and the buffer is emptied. Memory
    /// stays flat regardless of duration, the data survives a crash or a battery death mid-air,
    /// and nothing is thrown away.
    private let rawFlushThreshold = 2_000        // ~40 s at 50 Hz
    private var rawFileHandle: FileHandle?
    private var rawFileURL: URL?
    private var rawSamplesWritten = 0
    private var rawStart: Date?
    /// GPS speed most recently seen, stamped onto raw samples so the two can be correlated.
    var latestGPSSpeed: Double = -1
    /// Latest GPS position, kept as ground truth even when the route deliberately ignores it.
    var latestGPSLatitude: Double?
    var latestGPSLongitude: Double?
    /// Accuracy of that live fix. Recorded because the truth track is only usable where GPS was
    /// actually tracking: in a basement it freezes, and a frozen truth silently turns into a
    /// bogus reference bearing that inflates every measured heading error. On one walk that
    /// alone accounted for the difference between a 113 deg and a 48 deg p90.
    var latestGPSAccuracy: Double = -1

    func recordRaw(verticalAccel: Double, north: Double = 0, east: Double = 0, at time: Date) {
        if rawStart == nil { rawStart = time }
        guard let start = rawStart else { return }
        var sample = RawSample(t: time.timeIntervalSince(start),
                               verticalAccel: verticalAccel,
                               gpsSpeed: latestGPSSpeed,
                               northAccel: north,
                               eastAccel: east)
        if let m = pendingDeviceMotion {
            sample.deviceAccelX = m.ax; sample.deviceAccelY = m.ay; sample.deviceAccelZ = m.az
            sample.gravityX = m.gx; sample.gravityY = m.gy; sample.gravityZ = m.gz
            sample.rotationX = m.rx; sample.rotationY = m.ry; sample.rotationZ = m.rz
            sample.roll = m.roll; sample.pitch = m.pitch; sample.yaw = m.yaw
            sample.motionHeading = m.motionHeading
        }
        raw.append(sample)
        if raw.count >= rawFlushThreshold { flushRawToDisk() }
    }

    var rawCount: Int { rawSamplesWritten + raw.count }

    private static func rawHeader() -> String {
        var out = "t_seconds,vertical_accel_ms2,gps_speed_ms,north_accel_ms2,east_accel_ms2"
        out += ",dev_accel_x,dev_accel_y,dev_accel_z"
        out += ",gravity_x,gravity_y,gravity_z"
        out += ",rot_x,rot_y,rot_z"
        out += ",att_roll,att_pitch,att_yaw,motion_heading_deg\n"
        return out
    }

    /// Append what has accumulated and empty the buffer. Opens the file on first use.
    private func flushRawToDisk() {
        guard !raw.isEmpty else { return }
        if rawFileHandle == nil {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd_HHmmss"
            let stamp = df.string(from: rawStart ?? Date())
            do {
                let base = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                let dir = base.appendingPathComponent("VelocityLogs", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("velocity_raw50hz_\(stamp).csv")
                FileManager.default.createFile(atPath: url.path, contents: Self.rawHeader().data(using: .utf8))
                rawFileHandle = try FileHandle(forWritingTo: url)
                rawFileHandle?.seekToEndOfFile()
                rawFileURL = url
            } catch {
                print("❌ Could not open raw trace for streaming: \(error)")
                raw.removeAll()
                return
            }
        }
        var chunk = ""
        chunk.reserveCapacity(raw.count * 160)
        for s in raw {
            chunk += String(format: "%.3f,%.6f,%.3f,%.6f,%.6f", s.t, s.verticalAccel, s.gpsSpeed,
                            s.northAccel, s.eastAccel)
            chunk += String(format: ",%.6f,%.6f,%.6f", s.deviceAccelX, s.deviceAccelY, s.deviceAccelZ)
            chunk += String(format: ",%.6f,%.6f,%.6f", s.gravityX, s.gravityY, s.gravityZ)
            chunk += String(format: ",%.6f,%.6f,%.6f", s.rotationX, s.rotationY, s.rotationZ)
            chunk += String(format: ",%.6f,%.6f,%.6f,%.2f\n", s.roll, s.pitch, s.yaw, s.motionHeading)
        }
        if let data = chunk.data(using: .utf8) {
            rawFileHandle?.write(data)
            rawSamplesWritten += raw.count
        }
        raw.removeAll(keepingCapacity: true)
    }

    /// Close the stream and return where it landed.
    @discardableResult
    func finishRawStream() -> URL? {
        flushRawToDisk()
        try? rawFileHandle?.close()
        rawFileHandle = nil
        return rawFileURL
    }

    private func rawCSV() -> String {
        var out = "t_seconds,vertical_accel_ms2,gps_speed_ms,north_accel_ms2,east_accel_ms2\n"
        for s in raw {
            out += String(format: "%.3f,%.6f,%.3f,%.6f,%.6f\n",
                          s.t, s.verticalAccel, s.gpsSpeed, s.northAccel, s.eastAccel)
        }
        return out
    }

    // MARK: - Persistence
    //
    // The buffers live in memory and are cleared when the next workout starts, and the live
    // panel that exports them only exists while a workout is running. So a drive whose export
    // was forgotten before pressing Stop was simply gone — the one thing these logs exist to
    // prevent. Write them to disk at the end of every workout instead, keyed by start time, so
    // they can be retrieved later from the workout itself.

    /// Every saved log, newest first, for the developer screen's browser.
    static func allSavedLogs() -> [(url: URL, size: Int, modified: Date)] {
        let dir = logDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { name -> (URL, Int, Date)? in
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int,
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            return (url, size, modified)
        }
        .sorted { $0.2 > $1.2 }
        .map { (url: $0.0, size: $0.1, modified: $0.2) }
    }

    static func deleteAllSavedLogs() {
        for log in allSavedLogs() { try? FileManager.default.removeItem(at: log.url) }
    }

    private static var logDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VelocityLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func stamp(for workoutStart: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        return df.string(from: workoutStart)
    }

    /// Write both logs for a finished workout. Cheap enough to do on the main actor at stop.
    func persistToDisk(workoutStart: Date) {
        // Close the stream first: the raw trace has been written as it went, so this only has to
        // flush the tail. Nothing here re-serialises hours of samples.
        let streamed = finishRawStream()
        guard !rows.isEmpty || streamed != nil else { return }
        let s = Self.stamp(for: workoutStart)
        let dir = Self.logDirectory
        if !rows.isEmpty {
            try? csv().write(to: dir.appendingPathComponent("velocity_debug_\(s).csv"),
                             atomically: true, encoding: .utf8)
        }
        // The stream names itself from the first sample's clock; rename it to the workout's own
        // stamp so both files for a session share one name.
        if let streamed {
            let target = dir.appendingPathComponent("velocity_raw50hz_\(s).csv")
            if streamed != target {
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.moveItem(at: streamed, to: target)
            }
        }
        let minutes = Double(rawSamplesWritten) / 50.0 / 60.0
        print("💾 Velocity logs saved for \(s): \(rows.count) ticks, \(rawSamplesWritten) raw samples (\(String(format: "%.0f", minutes)) min)")
        Self.pruneOldLogs()
    }

    /// Files already saved for a given workout, newest formats first. Empty if none.
    static func savedLogs(forWorkoutStart start: Date) -> [URL] {
        let s = stamp(for: start)
        let dir = logDirectory
        return ["velocity_raw50hz_\(s).csv", "velocity_debug_\(s).csv"]
            .map { dir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Raw traces are large. Keep the twenty most recent workouts' worth and drop the rest.
    private static func pruneOldLogs() {
        let dir = logDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(40) { try? FileManager.default.removeItem(at: old) }
    }

    /// Share previously saved logs for a workout, from anywhere in the app.
    static func exportSavedLogs(forWorkoutStart start: Date, from presenter: UIViewController? = nil) {
        let files = savedLogs(forWorkoutStart: start)
        guard !files.isEmpty else { return }
        DispatchQueue.main.async {
            let vc = UIActivityViewController(activityItems: files, applicationActivities: nil)
            let host = presenter ?? topViewController()
            if let pop = vc.popoverPresentationController, let host {
                pop.sourceView = host.view
                pop.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY,
                                        width: 0, height: 0)
                pop.permittedArrowDirections = []
            }
            host?.present(vc, animated: true)
        }
    }

    /// Snapshot for the live plot: the recorded speed series, cheap to hand to a view.
    func recentSpeeds(limit: Int = 300) -> [Double] {
        Array(rows.suffix(limit).map(\.reportedSpeed))
    }

    // MARK: - Export

    /// Quote a text field if it contains anything that would break the row.
    private static func csvField(_ v: String) -> String {
        guard v.contains(",") || v.contains("\"") || v.contains("\n") else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func fmt(_ v: Double?, _ places: Int = 5) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(places)f", v)
    }

    func csv() -> String {
        var out = "time,source,activity,reported_speed_ms,reported_speed_kmh,distance_m,"
        out += "heading_deg,compass_deg,offset_deg,"
        out += "vib_feature_u,fit_p0,fit_p1,fit_p2,cal_min_u,cal_max_u,"
        out += "cal_min_speed_ms,cal_max_speed_ms,cal_samples,extrapolating,"
        out += "tick_dt_s,regime_distance,handling_rot_rads,heading_unreliable,walk_axis_deg,walk_skew_ema,walk_axis_raw_deg,walk_axis_gated,"
        out += "learn_obs,learn_max_kmh,learn_slope,"
        out += "gps_speed_ms,gps_accuracy_m,lat,lon,truth_lat,truth_lon,"
        out += "accel_mag_ms2,rotation_rate_rads,pitch_deg,roll_deg,yaw_deg,altitude_m\n"

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for r in rows {
            out += iso.string(from: r.t) + ","
            // A COMMA IN A TAG SILENTLY DESTROYS THE FILE.
            //
            // "LEARN(held, in hand)" shipped in build 146 and added a 42nd field to a 41-column
            // row, shifting every value after it. 22 rows of one drive parsed with speed in the
            // accuracy column and an activity string where a number belonged, and nothing about
            // the file announced it - it just read as absurd data. Tags are written by hand and
            // will collect punctuation again, so escape rather than rely on remembering.
            out += Self.csvField(r.source) + "," + Self.csvField(r.activity) + ","
            out += Self.fmt(r.reportedSpeed) + "," + Self.fmt(r.reportedSpeed * 3.6) + ","
            out += Self.fmt(r.distanceAdded) + ","
            out += Self.fmt(r.heading) + "," + Self.fmt(r.compass) + "," + Self.fmt(r.offset) + ","
            out += Self.fmt(r.feature) + ","
            out += Self.fmt(r.p0) + "," + Self.fmt(r.p1) + "," + Self.fmt(r.p2) + ","
            out += Self.fmt(r.minCalU) + "," + Self.fmt(r.maxCalU) + ","
            out += Self.fmt(r.minCalSpeed) + "," + Self.fmt(r.maxCalSpeed) + ","
            out += Self.fmt(r.calSamples) + ",\(r.extrapolating ? 1 : 0),"
            out += Self.fmt(r.tickInterval) + "," + (r.regimeDistance.map { Self.fmt($0) } ?? "") + "," + Self.fmt(r.handlingRotation) + ",\(r.headingUnreliable ? 1 : 0),"
            out += Self.fmt(r.walkAxis) + "," + Self.fmt(r.walkSkew) + ","
            out += Self.fmt(r.walkAxisRaw) + "," + Self.fmt(r.walkAxisGated) + ","
            out += Self.fmt(r.learnObs) + "," + Self.fmt(r.learnMaxKmh) + "," + Self.fmt(r.learnSlope) + ","
            out += Self.fmt(r.gpsSpeed) + "," + Self.fmt(r.gpsAccuracy) + ","
            out += Self.fmt(r.latitude) + "," + Self.fmt(r.longitude) + ","
            out += Self.fmt(r.truthLatitude, 7) + "," + Self.fmt(r.truthLongitude, 7) + ","
            out += Self.fmt(r.accelMagnitude) + "," + Self.fmt(r.rotationRate) + ","
            out += Self.fmt(r.pitch) + "," + Self.fmt(r.roll) + "," + Self.fmt(r.yaw) + ","
            out += Self.fmt(r.altitude) + "\n"
        }
        return out
    }

    /// Write the CSV to a temporary file and hand it to the share sheet.
    func exportCSV(from presenter: UIViewController? = nil) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = df.string(from: Date())
        var items: [Any] = []

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("velocity_debug_\(stamp).csv")
        do {
            try csv().write(to: url, atomically: true, encoding: .utf8)
            items.append(url)
        } catch {
            print("❌ diagnostics export failed: \(error)")
        }
        // The raw 50 Hz trace, which is what a spectrum can actually be computed from.
        // The raw trace lives on disk already — it was streamed there as the workout ran, so
        // share that file rather than rebuilding one from a buffer that is deliberately empty.
        if let streamed = finishRawStream() {
            items.append(streamed)
        }
        guard !items.isEmpty else { return }

        DispatchQueue.main.async {
            let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
            let host = presenter ?? Self.topViewController()
            if let pop = vc.popoverPresentationController, let host {
                pop.sourceView = host.view
                pop.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY,
                                        width: 0, height: 0)
                pop.permittedArrowDirections = []
            }
            host?.present(vc, animated: true)
        }
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
