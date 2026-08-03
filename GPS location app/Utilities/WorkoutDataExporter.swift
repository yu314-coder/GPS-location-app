import Foundation
import UIKit

/// Exports one saved workout as CSV, including everything the sensors recorded per point.
///
/// GPX already exists but is a route format: it carries position, elevation and time and has
/// nowhere to put acceleration, attitude, rotation or the derived headings. Those are exactly
/// the fields needed to work out why a recorded speed or direction was wrong after the fact,
/// and they are already stored on every point, so this exposes them rather than adding new
/// recording.
enum WorkoutDataExporter {

    static func csv(for flight: Flight) -> String {
        var out = "index,time,latitude,longitude,altitude_m,"
        out += "gps_speed_ms,gps_speed_kmh,course_deg,horizontal_accuracy_m,vertical_accuracy_m,"
        out += "is_estimated,"
        out += "motion_accel_ms2,forward_accel_ms2,lateral_accel_ms2,"
        out += "device_heading_deg,compass_heading_deg,movement_direction_deg,"
        out += "pitch_deg,roll_deg,yaw_deg,rotation_rate_rads,"
        out += "vertical_speed_ms,relative_altitude_m\n"

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for (i, p) in flight.locations.enumerated() {
            out += "\(i),\(iso.string(from: p.timestamp)),"
            out += f(p.latitude, 7) + "," + f(p.longitude, 7) + "," + f(p.altitude) + ","
            out += f(p.speed) + "," + f(p.speed * 3.6) + ","
            out += f(p.course) + "," + f(p.horizontalAccuracy) + "," + f(p.verticalAccuracy) + ","
            out += "\(p.isEstimated ? 1 : 0),"
            out += f(p.motionAcceleration) + "," + f(p.forwardAcceleration) + "," + f(p.lateralAcceleration) + ","
            out += f(p.deviceHeading) + "," + f(p.compassHeading) + "," + f(p.movementDirection) + ","
            out += f(p.pitch) + "," + f(p.roll) + "," + f(p.yaw) + "," + f(p.rotationRate) + ","
            out += f(p.verticalSpeed) + "," + f(p.relativeAltitude) + "\n"
        }
        return out
    }

    private static func f(_ v: Double?, _ places: Int = 4) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(places)f", v)
    }

    /// Write the CSV to a temp file and present the share sheet.
    static func export(flight: Flight, from presenter: UIViewController? = nil) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "workout_\(df.string(from: flight.startDate))_data.csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try csv(for: flight).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("❌ workout data export failed: \(error)")
            return
        }
        present(items: [url], from: presenter)
    }

    /// Share both the route (GPX, opens in other apps) and the full sensor data (CSV).
    static func exportAll(flight: Flight, from presenter: UIViewController? = nil) {
        var items: [Any] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "workout_\(df.string(from: flight.startDate))_data.csv"
        let csvURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if (try? csv(for: flight).write(to: csvURL, atomically: true, encoding: .utf8)) != nil {
            items.append(csvURL)
        }
        if let gpx = GPXExporter.exportToGPX(flight: flight) { items.append(gpx) }
        guard !items.isEmpty else { return }
        present(items: items, from: presenter)
    }

    private static func present(items: [Any], from presenter: UIViewController?) {
        DispatchQueue.main.async {
            let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
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

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
