import Foundation

/// Records one row per dead-reckoning tick on the WATCH, and hands the CSV to the iPhone when
/// the workout ends.
///
/// The iPhone has had this since the beginning, and every problem solved in this app was solved
/// by reading one of its logs — the compass offset running to −268°, the pedometer being used to
/// measure a car, the speed model saturating at 45 km/h. None of that was visible from a map.
/// The watch had no equivalent, so its dead reckoning could only ever be argued about.
///
/// watchOS cannot present a share sheet or a Files browser worth using, so the CSV is not
/// exported here: it is transferred to the iPhone, which already collects these logs and already
/// knows how to share them. From the user's side a watch workout simply produces one more file
/// in the same list, named so it cannot be confused with the phone's own.
///
/// WRITTEN TO THE WATCH'S DISK AS IT GROWS (build 82). The rows were held in memory, capped at
/// about four hours, and sent at Stop: a longer flight lost its start, and a workout the watch
/// ended without a Stop - a crash, a flat battery - lost everything. The file now lives in
/// Documents/WatchLogs until the iPhone confirms it has a copy, and any file that never reached
/// the iPhone is sent again at the next launch and after the next workout. A row is written every
/// second of the workout, with GPS as well as without, so the wrist's engines can be scored
/// against GPS later.
final class WatchDiagnosticsRecorder {

    struct Row {
        let t: Date
        let source: String
        let speed: Double
        let distance: Double
        let heading: Double
        let compass: Double?
        let offset: Double?
        let stepCadence: Double
        let quietDuration: Double
        let learnObservations: Int
        let gpsSpeed: Double?
        let gpsAccuracy: Double?
        let truthLatitude: Double?
        let truthLongitude: Double?
        let accelMagnitude: Double
        let rotationRate: Double
        /// Both speed engines this second, whichever drove (build 79): the network's answer and
        /// familiarity (1.0 or less answers), the store's answer and its ground examples, and the
        /// 11-number vibration fingerprint both read - so a wrist recording can later be scored
        /// engine against engine against GPS, which the watch logs could not show before.
        var networkSpeed: Double? = nil
        var networkFamiliarity: Double? = nil
        var storeSpeed: Double? = nil
        var storeGroundExamples: Int = 0
        var features: [Double]? = nil
        /// Walking and vehicle state (build 82), to check the watch against the iPhone's method:
        /// steps the accelerometer counted and the pedometer's count this workout, the pedometer's
        /// distance since the gap began, the echo check's refractory, whether a vehicle was current,
        /// and the speed the iPhone relayed from its workout or GPS.
        var imuSteps: Int? = nil
        var pedometerSteps: Int? = nil
        var pedometerGapDistance: Double? = nil
        var stepRefractory: Double? = nil
        var vehicleContext: Bool? = nil
        var relayedSpeed: Double? = nil
        /// Barometer (build 82): altitude change since the start of the workout, and pressure.
        var relativeAltitude: Double? = nil
        var pressure: Double? = nil
    }

    private var stream: CSVStream?
    private var workoutStart: Date?
    private(set) var count = 0
    var latestRelativeAltitude: Double?
    var latestPressure: Double?

    var latestGPSSpeed: Double = -1
    var latestGPSAccuracy: Double = -1
    var latestGPSLatitude: Double?
    var latestGPSLongitude: Double?

    func reset(workoutStart: Date) {
        stream?.close()
        stream = nil
        count = 0
        self.workoutStart = workoutStart
        latestRelativeAltitude = nil
        latestPressure = nil
        latestGPSSpeed = -1
        latestGPSAccuracy = -1
        latestGPSLatitude = nil
        latestGPSLongitude = nil
    }

    func record(_ row: Row) {
        guard let workoutStart else { return }
        if stream == nil {
            stream = CSVStream(url: Self.fileURL(for: workoutStart), header: Self.header, flushEvery: 30)
        }
        stream?.append(Self.line(row))
        count += 1
    }

    /// Put buffered rows on disk now (the app is going inactive).
    func flush() { stream?.flush() }

    private static func fmt(_ v: Double?, _ places: Int = 5) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(places)f", v)
    }

    static let header: String = {
        var out = "time,source,reported_speed_ms,reported_speed_kmh,distance_m,heading_deg,"
        out += "compass_deg,offset_deg,step_cadence,quiet_s,learn_obs,"
        out += "gps_speed_ms,gps_accuracy_m,truth_lat,truth_lon,accel_mag_ms2,rotation_rate_rads,"
        // Appended at the end so every existing column keeps its position.
        out += "net_speed_ms,net_familiarity,store_speed_ms,store_ground_obs,"
        out += (0..<11).map { "f\($0)" }.joined(separator: ",") + ","
        out += "imu_steps,pedometer_steps,pedometer_gap_m,step_refractory_s,vehicle_ctx,relay_speed_ms,"
        out += "rel_alt_m,pressure_kpa\n"
        return out
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func line(_ r: Row) -> String {
        var out = isoFormatter.string(from: r.t) + ",\(r.source),"
        out += fmt(r.speed) + "," + fmt(r.speed * 3.6) + "," + fmt(r.distance) + ","
        out += fmt(r.heading) + "," + fmt(r.compass) + "," + fmt(r.offset) + ","
        out += fmt(r.stepCadence) + "," + fmt(r.quietDuration) + ","
        out += fmt(Double(r.learnObservations), 0) + ","
        out += fmt(r.gpsSpeed) + "," + fmt(r.gpsAccuracy) + ","
        out += fmt(r.truthLatitude, 7) + "," + fmt(r.truthLongitude, 7) + ","
        out += fmt(r.accelMagnitude) + "," + fmt(r.rotationRate) + ","
        out += fmt(r.networkSpeed) + "," + fmt(r.networkFamiliarity, 3) + ","
        out += fmt(r.storeSpeed) + ",\(r.storeGroundExamples),"
        out += (0..<11).map { i in fmt(r.features.flatMap { $0.count == 11 ? $0[i] : nil }, 4) }.joined(separator: ",") + ","
        out += fmt(r.imuSteps.map(Double.init), 0) + "," + fmt(r.pedometerSteps.map(Double.init), 0) + ","
        out += fmt(r.pedometerGapDistance, 1) + "," + fmt(r.stepRefractory, 3) + ","
        out += (r.vehicleContext.map { $0 ? "1" : "0" } ?? "") + "," + fmt(r.relayedSpeed) + ","
        out += fmt(r.relativeAltitude, 2) + "," + fmt(r.pressure, 4) + "\n"
        return out
    }

    // MARK: - Files and delivery

    static var logDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("WatchLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Named with a `watch_` prefix and the workout's start time so it sorts alongside the phone's
    /// own logs without being mistaken for one.
    private static func fileURL(for workoutStart: Date) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        return logDirectory.appendingPathComponent("watch_velocity_debug_\(df.string(from: workoutStart)).csv")
    }

    /// The workout has ended: close its file and hand it to the iPhone, with any earlier file that
    /// never got there.
    func finishAndSend() {
        let url = stream?.url
        stream?.close()
        stream = nil
        workoutStart = nil
        if let url, FileManager.default.fileExists(atPath: url.path) {
            WatchConnectivityManager.shared.transferDiagnosticsLog(at: url)
            print("⌚ 📤 Queued \(count)-row diagnostics log for iPhone: \(url.lastPathComponent)")
        }
        Self.sendUnsentLogs(excluding: url, untouchedFor: 0)
    }

    /// Send every log still on the watch that is not already on its way. A file stays here until
    /// the iPhone confirms it (WatchConnectivityManager deletes it then), so a file found here was
    /// either cut short by the app ending or never delivered. `untouchedFor` skips a file written to
    /// in the last few seconds, which belongs to a workout still running.
    static func sendUnsentLogs(excluding current: URL? = nil, untouchedFor: TimeInterval) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let inFlight = Set(WatchConnectivityManager.shared.outstandingDiagnosticsLogNames())
        for file in files where file.pathExtension == "csv" {
            if file.lastPathComponent == current?.lastPathComponent || inFlight.contains(file.lastPathComponent) { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(modified) >= untouchedFor else { continue }
            WatchConnectivityManager.shared.transferDiagnosticsLog(at: file)
            print("⌚ 📤 Re-sending diagnostics log that never reached the iPhone: \(file.lastPathComponent)")
        }
    }
}
