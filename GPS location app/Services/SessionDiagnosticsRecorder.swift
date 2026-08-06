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
        let handlingRotation: Double
        let gpsSpeed: Double?
        let gpsAccuracy: Double?
        let latitude: Double?
        let longitude: Double?
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
    }
    private var raw: [RawSample] = []
    private let rawCapacity = 90_000
    private var rawStart: Date?
    /// GPS speed most recently seen, stamped onto raw samples so the two can be correlated.
    var latestGPSSpeed: Double = -1

    func recordRaw(verticalAccel: Double, at time: Date) {
        if rawStart == nil { rawStart = time }
        guard let start = rawStart else { return }
        raw.append(RawSample(t: time.timeIntervalSince(start),
                             verticalAccel: verticalAccel,
                             gpsSpeed: latestGPSSpeed))
        if raw.count > rawCapacity { raw.removeFirst(raw.count - rawCapacity) }
    }

    var rawCount: Int { raw.count }

    private func rawCSV() -> String {
        var out = "t_seconds,vertical_accel_ms2,gps_speed_ms\n"
        for s in raw {
            out += String(format: "%.3f,%.6f,%.3f\n", s.t, s.verticalAccel, s.gpsSpeed)
        }
        return out
    }

    /// Snapshot for the live plot: the recorded speed series, cheap to hand to a view.
    func recentSpeeds(limit: Int = 300) -> [Double] {
        Array(rows.suffix(limit).map(\.reportedSpeed))
    }

    // MARK: - Export

    private static func fmt(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.5f", v)
    }

    func csv() -> String {
        var out = "time,source,activity,reported_speed_ms,reported_speed_kmh,distance_m,"
        out += "heading_deg,compass_deg,offset_deg,"
        out += "vib_feature_u,fit_p0,fit_p1,fit_p2,cal_min_u,cal_max_u,"
        out += "cal_min_speed_ms,cal_max_speed_ms,cal_samples,extrapolating,"
        out += "handling_rot_rads,gps_speed_ms,gps_accuracy_m,lat,lon,"
        out += "accel_mag_ms2,rotation_rate_rads,pitch_deg,roll_deg,yaw_deg,altitude_m\n"

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for r in rows {
            out += iso.string(from: r.t) + ","
            out += "\(r.source),\(r.activity),"
            out += Self.fmt(r.reportedSpeed) + "," + Self.fmt(r.reportedSpeed * 3.6) + ","
            out += Self.fmt(r.distanceAdded) + ","
            out += Self.fmt(r.heading) + "," + Self.fmt(r.compass) + "," + Self.fmt(r.offset) + ","
            out += Self.fmt(r.feature) + ","
            out += Self.fmt(r.p0) + "," + Self.fmt(r.p1) + "," + Self.fmt(r.p2) + ","
            out += Self.fmt(r.minCalU) + "," + Self.fmt(r.maxCalU) + ","
            out += Self.fmt(r.minCalSpeed) + "," + Self.fmt(r.maxCalSpeed) + ","
            out += Self.fmt(r.calSamples) + ",\(r.extrapolating ? 1 : 0),"
            out += Self.fmt(r.handlingRotation) + ","
            out += Self.fmt(r.gpsSpeed) + "," + Self.fmt(r.gpsAccuracy) + ","
            out += Self.fmt(r.latitude) + "," + Self.fmt(r.longitude) + ","
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
        if !raw.isEmpty {
            let rawURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("velocity_raw50hz_\(stamp).csv")
            if (try? rawCSV().write(to: rawURL, atomically: true, encoding: .utf8)) != nil {
                items.append(rawURL)
            }
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

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
