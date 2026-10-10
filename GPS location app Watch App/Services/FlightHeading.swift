import Foundation

/// WHICH WAY THE PLANE IS GOING, FROM NOTHING A CABIN CAN DISTURB (build 114).
///
/// The compass is useless in a cabin. On BR215 (Taoyuan-Singapore, graded by ADS-B) the iPhone 16 Pro lay
/// still in a bag while the field it measured turned 23-52° and iOS's heading swung 60° in a quarter of an
/// hour; the 17 sat within centimetres of a magnet (up to 831 µT, Earth's is 45) and its heading swung 102°.
/// The route's heading in the air was typically 34° (17) and 119° (16 Pro) off the real course.
///
/// Three things the cabin does not disturb:
///   1. THE TAKEOFF ROLL'S DIRECTION. The roll is the strongest push a phone ever feels, straight along the
///      runway: the mean world-frame acceleration over its first 35 s pointed 53° and 41° on BR215's two
///      phones (runway 49°) and 228° on the August flight (GPS 230°), however the phone was carried.
///   2. THE GYROSCOPE IN A TURN. Turn by turn it matched ADS-B: -132° for -135, -40 for -46, +46 for +38.
///      But between turns iOS's rotation rate carried a steady phantom turn of about +0.08°/s, 60° in 15
///      minutes of straight flight. So the gyro's bias is learned on straight seconds (no felt turn, slow
///      rotation) and taken off.
///   3. THE FELT TURN. An airliner banks to turn, and everyone inside weighs a little more: 1/cos(bank).
///      A hand turning a phone adds nothing to that. So after the climb a second counts as a turn only when
///      the cabin feels heavier than its own recent level and the rotation is one a plane can make (under
///      4°/s; a phone picked up turns at 20-200°/s).
///
/// Through the climb every second counts (the departure turns are large and the phone usually sits still);
/// after it only felt turns do. Replayed on BR215 and the August flight: typical error 8° (17, 91% of the
/// flight within 30°), 29° (16 Pro, the climb before the bias was learned), 5° (August). No compass, no GPS.
///
/// The watch carries an identical copy (scripts/check_watch_engine.sh).
struct FlightHeading {
    static let ROLL_WINDOW: TimeInterval = 35
    private static let STRAIGHT_RATE = 0.35        // deg/s from the bias: not turning
    private static let STRAIGHT_LOAD = 0.015       // felt load within this of its level: not banked
    private static let TURN_RATE = 0.25            // deg/s (10-s mean, bias off) for a turn in cruise
    private static let TURN_LOAD = 0.012           // and the cabin this much heavier than its level
    private static let PLANE_RATE_CEILING = 4.0    // deg/s: faster is the phone moving, not the plane

    /// Degrees from north, clockwise; nil until a takeoff roll has been measured.
    private(set) var heading: Double?
    /// The takeoff roll's direction, for the log.
    private(set) var rollDirection: Double?
    /// The gyro's bias about the vertical, deg/s, learned on straight seconds.
    private(set) var bias = 0.0
    /// After the climb: only felt turns count.
    var cruising = false

    private var rollStart: Date?
    private var rollConfirmed = false
    private var rollNorth = 0.0, rollEast = 0.0, rollSamples = 0

    private var secF = 0.0, secW = 0.0, secN = 0, secT = 0.0
    private var fWindow: [Double] = [], wWindow: [Double] = []
    private var loadHistory: [Double] = []
    private var straight: [Double] = []

    /// A takeoff roll may be starting (the integration just passed 30 kt): collect its push from now.
    mutating func beginRoll(at time: Date) {
        rollStart = time; rollConfirmed = false; rollNorth = 0; rollEast = 0; rollSamples = 0
    }

    /// The roll that began at `start` reached 200 km/h within 30 s: it was a takeoff.
    mutating func confirmRoll(startedAt start: Date) {
        if rollStart == start { rollConfirmed = true }
    }

    /// The flight is over (the cabin is back on the ground): the next roll starts a new heading.
    mutating func endFlight() {
        heading = nil; rollDirection = nil; cruising = false; rollStart = nil; rollConfirmed = false
    }

    /// World-frame acceleration (m/s², north and east) during a possible roll.
    mutating func addRollAcceleration(north: Double, east: Double, at time: Date) {
        guard let start = rollStart, heading == nil, time.timeIntervalSince(start) <= Self.ROLL_WINDOW,
              north.isFinite, east.isFinite else { return }
        rollNorth += north; rollEast += east; rollSamples += 1
    }

    /// One motion sample: rotation about Core Motion's down (deg/s, + = turning right), the raw specific
    /// force |userAcceleration + gravity| (g), and the sample interval.
    mutating func ingest(rotationAboutDown w: Double, force f: Double, dt: Double, at time: Date) {
        guard dt > 0, dt < 0.5, w.isFinite, f.isFinite else { return }
        if heading == nil, rollConfirmed, let start = rollStart,
           time.timeIntervalSince(start) >= Self.ROLL_WINDOW, rollSamples > 50 {
            let d = atan2(rollEast, rollNorth) * 180 / .pi
            rollDirection = (d + 360).truncatingRemainder(dividingBy: 360)
            heading = rollDirection
        }
        secF += f; secW += w * dt; secN += 1; secT += dt
        guard secT >= 1.0 else { return }
        let f1 = secF / Double(secN), w1 = secW / secT, t1 = secT
        secF = 0; secW = 0; secN = 0; secT = 0
        fWindow = Array((fWindow + [f1]).suffix(10)); wWindow = Array((wWindow + [w1]).suffix(10))
        let fs = fWindow.reduce(0, +) / Double(fWindow.count)
        let ws = wWindow.reduce(0, +) / Double(wWindow.count)
        loadHistory.append(fs); if loadHistory.count > 600 { loadHistory.removeFirst(loadHistory.count - 600) }
        let base = Self.median(loadHistory)
        let load = base > 0 ? fs / base - 1 : 0
        if abs(ws - bias) < Self.STRAIGHT_RATE, abs(load) < Self.STRAIGHT_LOAD {
            straight.append(w1); if straight.count > 300 { straight.removeFirst(straight.count - 300) }
            if straight.count >= 30 { bias = Self.median(straight) }
        }
        guard let h = heading else { return }
        let rate = w1 - bias
        if !cruising {
            heading = Self.wrap(h + rate * t1)
        } else if abs(ws - bias) > Self.TURN_RATE, load > Self.TURN_LOAD,
                  abs(rate) <= Self.PLANE_RATE_CEILING, abs(ws - bias) <= Self.PLANE_RATE_CEILING {
            heading = Self.wrap(h + rate * t1)
        }
    }

    private static func wrap(_ d: Double) -> Double {
        let r = d.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r
    }

    private static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
