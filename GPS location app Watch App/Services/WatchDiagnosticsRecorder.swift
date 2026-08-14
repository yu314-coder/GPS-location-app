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
    }

    private var rows: [Row] = []
    /// About four hours at 1 Hz. Long enough for any flight, bounded so a forgotten workout
    /// cannot exhaust a watch's memory.
    private let capacity = 15_000

    var latestGPSSpeed: Double = -1
    var latestGPSAccuracy: Double = -1
    var latestGPSLatitude: Double?
    var latestGPSLongitude: Double?

    func reset() {
        rows.removeAll()
        latestGPSSpeed = -1
        latestGPSAccuracy = -1
        latestGPSLatitude = nil
        latestGPSLongitude = nil
    }

    func record(_ row: Row) {
        rows.append(row)
        if rows.count > capacity { rows.removeFirst(rows.count - capacity) }
    }

    var count: Int { rows.count }

    private static func fmt(_ v: Double?, _ places: Int = 5) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(places)f", v)
    }

    func csv() -> String {
        var out = "time,source,reported_speed_ms,reported_speed_kmh,distance_m,heading_deg,"
        out += "compass_deg,offset_deg,step_cadence,quiet_s,learn_obs,"
        out += "gps_speed_ms,gps_accuracy_m,truth_lat,truth_lon,accel_mag_ms2,rotation_rate_rads\n"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for r in rows {
            out += iso.string(from: r.t) + ",\(r.source),"
            out += Self.fmt(r.speed) + "," + Self.fmt(r.speed * 3.6) + "," + Self.fmt(r.distance) + ","
            out += Self.fmt(r.heading) + "," + Self.fmt(r.compass) + "," + Self.fmt(r.offset) + ","
            out += Self.fmt(r.stepCadence) + "," + Self.fmt(r.quietDuration) + ","
            out += Self.fmt(Double(r.learnObservations), 0) + ","
            out += Self.fmt(r.gpsSpeed) + "," + Self.fmt(r.gpsAccuracy) + ","
            out += Self.fmt(r.truthLatitude, 7) + "," + Self.fmt(r.truthLongitude, 7) + ","
            out += Self.fmt(r.accelMagnitude) + "," + Self.fmt(r.rotationRate) + "\n"
        }
        return out
    }

    /// Hand the log to the iPhone. Named with a `watch_` prefix and the workout's start time so
    /// it sorts alongside the phone's own logs without being mistaken for one.
    func sendToPhone(workoutStart: Date) {
        guard !rows.isEmpty else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let name = "watch_velocity_debug_\(df.string(from: workoutStart)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try csv().write(to: url, atomically: true, encoding: .utf8)
            WatchConnectivityManager.shared.transferDiagnosticsLog(at: url)
            print("⌚ 📤 Queued \(rows.count)-row diagnostics log for iPhone: \(name)")
        } catch {
            print("⌚ ❌ Failed to write diagnostics log: \(error)")
        }
    }
}
