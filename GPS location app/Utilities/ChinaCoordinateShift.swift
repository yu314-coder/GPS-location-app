import Foundation
import CoreLocation

/// Converts WGS-84 coordinates to GCJ-02 for DISPLAY on Apple's basemap inside mainland China.
///
/// Every coordinate this app records, stores and exports is WGS-84 — that is what GPS and
/// HealthKit produce, and it is what GPX and CSV must contain. But inside mainland China Apple's
/// basemap is drawn in GCJ-02, a deliberately offset system, and MapKit does NOT convert for you.
/// Plotting a true position there puts it a few hundred metres from the road it was recorded on.
///
/// That is why the same workout looked correct in Fitness and wrong here: Apple's own apps apply
/// this shift before drawing. It affected watch-recorded workouts identically, which is what
/// showed the fault was in the rendering rather than the recording.
///
/// Display only. Nothing stored, exported, or used for distance may pass through this — the
/// route is WGS-84 and must stay WGS-84 everywhere except the last step before MapKit draws it.
enum ChinaCoordinateShift {

    private static let a = 6_378_245.0                 // Krasovsky 1940 semi-major axis
    private static let ee = 0.006_693_421_622_965_943  // eccentricity squared

    /// The offset applies to mainland China only. Hong Kong, Macau and Taiwan are drawn in
    /// WGS-84, so shifting there would introduce the very error this removes.
    static func requiresShift(latitude: Double, longitude: Double) -> Bool {
        guard longitude > 73.66, longitude < 135.05, latitude > 3.86, latitude < 53.55 else {
            return false
        }
        // Hong Kong / Macau
        if latitude > 21.98, latitude < 22.60, longitude > 113.40, longitude < 114.50 { return false }
        // Taiwan
        if latitude > 21.80, latitude < 25.40, longitude > 119.30, longitude < 122.10 { return false }
        return true
    }

    static func toGCJ02(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard requiresShift(latitude: c.latitude, longitude: c.longitude) else { return c }
        let x = c.longitude - 105.0
        let y = c.latitude - 35.0
        var dLat = transformLatitude(x: x, y: y)
        var dLon = transformLongitude(x: x, y: y)
        let radLat = c.latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}

extension CLLocationCoordinate2D {
    /// This coordinate placed where Apple's basemap expects it. A no-op outside mainland China.
    /// Use ONLY when handing coordinates to MapKit for drawing.
    var forAppleBasemap: CLLocationCoordinate2D { ChinaCoordinateShift.toGCJ02(self) }
}

extension Array where Element == CLLocationCoordinate2D {
    var forAppleBasemap: [CLLocationCoordinate2D] { map { $0.forAppleBasemap } }
}
