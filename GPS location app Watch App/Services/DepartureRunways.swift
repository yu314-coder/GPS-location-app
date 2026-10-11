import Foundation

/// THE RUNWAYS AT THE AIRPORT THE PHONE IS AT (build 124), for FlightHeading's start.
///
/// The takeoff roll's push says which way the plane left, but iOS measures it from magnetic north, and on
/// BR226 a phone lying by a power outlet read the roll 12-30° off. The runway itself does not move: the phone's
/// last GPS fix before the flight (at the gate, or the terminal) names the airport, and the roll takes the
/// direction of whichever of its runways it matches.
///
/// runways.json: OurAirports (ourairports.com, public domain), every open hard runway of 1,500 m or more at a
/// large or medium airport - 4,874 runways at 3,784 airports - as [midpoint latitude, midpoint longitude,
/// axis heading true 0-180°, length m]. Built by scratchpad make_runways.py. Loaded only when a roll begins.
///
/// The watch carries an identical copy (scripts/check_watch_engine.sh).
enum DepartureRunways {
    /// Runways whose middle lies within this of the fix: big airports span 4-5 km, terminals sit beside them.
    static let RADIUS_KM = 8.0

    private static let table: [[Double]] = {
        guard let url = Bundle.main.url(forResource: "runways", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([[Double]].self, from: data) else { return [] }
        return rows.filter { $0.count >= 3 }
    }()

    /// Axis headings (true, 0-180°) of the runways near a position; empty away from any airport.
    static func axes(nearLatitude lat: Double, longitude lon: Double) -> [Double] {
        nearby(lat, lon).map { $0[2] }
    }

    /// The elevation (m) of the airport at a position, nil away from any airport (build 125: the fifth
    /// column, OurAirports' airport elevation). What the cabin's height is measured from when the
    /// workout did not see the ground before the flight.
    static func fieldElevation(nearLatitude lat: Double, longitude lon: Double) -> Double? {
        let e = nearby(lat, lon).compactMap { $0.count >= 5 ? $0[4] : nil }.sorted()
        return e.isEmpty ? nil : e[e.count / 2]
    }

    private static func nearby(_ lat: Double, _ lon: Double) -> [[Double]] {
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90 else { return [] }
        let k = cos(lat * .pi / 180)
        return table.filter { row in
            let dLat = (row[0] - lat) * .pi / 180
            var dLon = (row[1] - lon).truncatingRemainder(dividingBy: 360)
            if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
            let km = 6371 * (dLat * dLat + (dLon * .pi / 180 * k) * (dLon * .pi / 180 * k)).squareRoot()
            return km <= RADIUS_KM
        }
    }
}
