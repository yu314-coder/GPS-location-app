import Foundation
import CoreLocation

/// GPS DISTANCE FOLLOWS THE SATELLITE SPEED (build 137 on the phone; the watch since builds 135-136).
///
/// Distance was the straight line between consecutive fixes, so every wobble of a fix at a stop or a crawl counted,
/// and fixes WITHOUT a satellite speed (Wi-Fi/cell positions, speed < 0) jumped hundreds of metres while claiming
/// 20-40 m of accuracy - fixContradictsItself cannot judge those, having no speed to compare.
///
/// A fix with a speed adds at most 1.05 x the mean speed of the pair x the time + 0.3 m (Doppler does not care how
/// vague the position is). A fix without one is smoothed - the median of the last three such fixes - and refused if it
/// implies more than 30 m/s. Measured with this exact rule on every phone recording's full fix stream: 19 clean-GPS
/// recordings, typical error 6.3% -> 3.1%, worst 36% -> 9%; two weak-GPS rides on roads measured from clean rides of
/// them 153% -> 82% and 123% -> 99%. The route keeps its raw fixes; only the distance follows this anchor.
///
/// ON FOOT, A WI-FI POSITION MAY NOT OUTRUN A WALKER (build 157). Standing in a shop on 2026-11-07 (satellite fixes
/// before and after on the same spot, pressure flat), Wi-Fi positions jumped 130-415 m and back while claiming 13-22 m
/// accuracy. The gap machinery ended each short gap on such a position (a re-anchor adds nothing) and the next position
/// stepped the whole error back: +347 m on the phone, +293 m on the watch. While the person is known to be on foot
/// (see WorkoutSession.onFootForSpeedless) a fix without a satellite speed may add distance only at up to
/// onFootMaxSpeed; a faster one stays on the route but adds nothing and leaves the anchor where it was. An anchor laid
/// on such a fix by a gap end is PROVISIONAL until a plausible step leaves it: a too-fast next fix replaces it, with no
/// distance. Replayed on every phone recording (76) and watch fix log (9): only on-foot stretches change (walks at
/// trip ends, a car park and lift, the shop), no ride changes at all; 3-5 m/s give the same result.
struct GPSDistanceStepper {
    static let speedlessMaxSpeed = 30.0
    static let onFootMaxSpeed = 4.0
    private var anchor: (time: Date, lat: Double, lon: Double, speed: Double)?
    private var speedless: [(lat: Double, lon: Double)] = []
    private var anchorIsProvisional = false

    /// Start the distance from this fix (a re-anchor, a resumed workout) or from nothing. `provisional`: the fix ends a
    /// gap on foot without a satellite speed, so it may be a Wi-Fi position far from where the person is.
    mutating func reset(to location: FlightLocation? = nil, provisional: Bool = false) {
        speedless.removeAll()
        anchor = location.map { ($0.timestamp, $0.latitude, $0.longitude, $0.speed) }
        anchorIsProvisional = provisional && anchor != nil
    }

    /// What step() did with the last fix, for the log: nil = counted as usual.
    private(set) var lastHeld: (distance: Double, replaced: Bool)?

    /// The distance this real fix adds, or nil when a fix without a satellite speed implies an impossible one.
    /// `onFoot`: the person is known to be walking or standing (build 157, see above).
    mutating func step(_ location: FlightLocation, onFoot: Bool = false) -> Double? {
        lastHeld = nil
        let (lat, lon) = position(of: location)
        guard let a = anchor else {
            anchor = (location.timestamp, lat, lon, location.speed)
            return 0
        }
        let d = CLLocation(latitude: a.lat, longitude: a.lon).distance(from: CLLocation(latitude: lat, longitude: lon))
        let dt = max(location.timestamp.timeIntervalSince(a.time), 0)
        var add = d
        if location.speed >= 0 {
            let v = a.speed >= 0 ? (location.speed + a.speed) / 2 : location.speed
            add = min(d, v * dt * 1.05 + 0.3)
            anchorIsProvisional = false
        } else {
            let provisionalOnFoot = onFoot && anchorIsProvisional
            if dt > 0, d / dt > Self.speedlessMaxSpeed, !provisionalOnFoot {
                return nil
            }
            if onFoot, dt <= 0 || d / dt > Self.onFootMaxSpeed {
                if anchorIsProvisional {
                    // The gap ended on a far position: this one replaces it, and nothing is counted.
                    anchor = (location.timestamp, lat, lon, location.speed)
                    lastHeld = (d, true)
                } else {
                    lastHeld = (d, false)
                }
                return 0
            }
            anchorIsProvisional = false
        }
        anchor = (location.timestamp, lat, lon, location.speed)
        return add
    }

    /// Where a fix counts from: itself with a satellite speed; without one, the median of the last three such fixes.
    private mutating func position(of location: FlightLocation) -> (Double, Double) {
        if location.speed >= 0 {
            speedless.removeAll()
            return (location.latitude, location.longitude)
        }
        speedless.append((location.latitude, location.longitude))
        if speedless.count > 3 { speedless.removeFirst() }
        let lats = speedless.map(\.lat).sorted(), lons = speedless.map(\.lon).sorted()
        return (lats[lats.count / 2], lons[lons.count / 2])
    }

    /// A saved fix whose step the workout held or replaced (FlightLocation.distanceHeld): the same bookkeeping, and
    /// no distance, so a recalculation lands where the workout did.
    mutating func repeatHeld(_ location: FlightLocation, replaced: Bool) {
        let (lat, lon) = position(of: location)
        if replaced || anchor == nil { anchor = (location.timestamp, lat, lon, location.speed) }
        anchorIsProvisional = false
    }

    /// A saved route's distance by the same rule, for recalculations: real fixes follow their satellite speed;
    /// dead-reckoned points (isEstimated) keep the straight line between them, which is the step they were drawn
    /// with. Invalid points and jumps over 1 km are skipped, as before.
    static func total(_ locations: [FlightLocation]) -> Double {
        cumulative(locations).last?.distance ?? 0
    }

    /// total(), point by point: each valid location's time and the distance up to and including it (build 148, to
    /// time the kilometre splits of workouts saved before they were timed).
    static func cumulative(_ locations: [FlightLocation]) -> [(time: Date, distance: Double)] {
        var out: [(time: Date, distance: Double)] = []
        guard locations.count > 1 else { return out }
        var stepper = GPSDistanceStepper()
        var total = 0.0
        var previous: FlightLocation?
        for location in locations where location.isValid {
            defer { previous = location; out.append((location.timestamp, total)) }
            guard let p = previous else {
                if !location.isEstimated { _ = stepper.step(location) }
                continue
            }
            let straight = location.distance(to: p)
            if straight >= 1000 {
                stepper.reset(to: location.isEstimated ? nil : location)
                continue
            }
            if location.isEstimated || p.isEstimated {
                total += straight
                stepper.reset(to: location.isEstimated ? nil : location)
            } else if let held = location.distanceHeld {
                stepper.repeatHeld(location, replaced: held == "replaced")
            } else if let add = stepper.step(location) {
                total += add
            }
        }
        return out
    }
}
