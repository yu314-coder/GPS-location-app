import Foundation

/// WHICH WAY THE PLANE IS GOING, FROM NOTHING A CABIN CAN DISTURB (build 114; reworked in build 124).
///
/// The compass is useless in a cabin. On BR215 (Taoyuan-Singapore, graded by ADS-B) the iPhone 16 Pro lay
/// still in a bag while the field it measured turned 23-52° and iOS's heading swung 60° in a quarter of an
/// hour; the 17 sat within centimetres of a magnet (up to 831 µT, Earth's is 45) and its heading swung 102°.
///
/// THE START: THE TAKEOFF ROLL. The roll is the strongest push a phone ever feels, straight along the runway:
/// the mean world-frame acceleration over its first 35 s. But "world frame" means iOS's magnetic north, and on
/// BR226 (Singapore-Taoyuan) the same push read 194° on the 16 Pro, 203° on the iPad and 215° on the 17 (the
/// app's own window: 233°) - the 17 lay by a power outlet. So the push is matched to the departure runway
/// when one is known: the runways of the airport at the phone's last GPS fix (OurAirports, public domain,
/// bundled; DepartureRunways). Within 40° of one of its two directions, that direction is the start.
///
/// THEN THE GYROSCOPE ABOUT DOWN, IN TURN EPISODES. BR226 showed three things the build 114 rules missed:
///   1. GENTLE TURNS NOBODY FEELS. At 900 km/h a 10° course change at 0.2°/s banks 5°: 0.4% heavier, far below
///      what the cabin can tell from turbulence. The gyro shows it plainly (0.2°/s against ±0.02 straight).
///      So a rotation episode counts when it is felt (the cabin heavier than its own level), or when it is
///      unfelt but steady (0.12°/s for 15 s) and the gyro was quiet the minute before.
///   2. GYRO DRIFT. After the departure turn the 17's rotation rate ran +0.1-0.25°/s for ten minutes and the
///      iPad's +0.5°/s for seven, with the plane straight and nothing felt; after each big left turn on the
///      approach the 17 swung back +0.5°/s while the 16 Pro and the iPad read zero. So an unfelt rotation that
///      lasts more than two minutes is drift: it is taken back off and learned as the gyro's bias. And for five
///      minutes after a felt turn, a rotation the other way needs a real bank (3% heavier) to count.
///   3. THE PHONE IN A HAND. A bag search turned the 16 Pro at 10-560°/s and tilted it up to 38° in a second;
///      an airliner turns at under 3°/s and tilts the cabin under 3° a second. A second whose median rotation
///      is over 3.5°/s, or whose tilt changed over 5°, is the phone moving: none of it is the plane's.
/// And a felt second is scaled by the felt load: a banked turn is measured about the tilted floor (cos bank),
/// which left the 777's 25° approach turns 9% short.
///
/// Replayed on BR226 (three devices), BR215 (two) and the August flight against ADS-B or GPS, with ADS-B's own
/// speed so only the heading differs: route ends 16 Pro 894 -> 95 km, 17 2,523 -> 168 km (BR226), 16 Pro
/// 871 -> 626 km (BR215), August 7° -> 5° typical. The BR215 17 went 183 -> 590 km: build 114 had counted a
/// phone being handled as a 15° turn that happened to cancel a turn missed while iOS paused the app.
///
/// The watch carries an identical copy (scripts/check_watch_engine.sh).
struct FlightHeading {
    static let ROLL_WINDOW: TimeInterval = 35
    private static let RUNWAY_SNAP = 40.0          // deg: the push within this of a runway direction takes it
    private static let TURN_RATE = 0.25            // deg/s (10-s mean, bias off) for a felt turn
    private static let TURN_LOAD = 0.012           // and the cabin this much heavier than its level
    private static let PAYBACK_SECONDS = 300.0     // after a felt turn, the opposite way needs...
    private static let PAYBACK_LOAD = 0.03         // ...this much load
    private static let EPISODE_RATE = 0.08         // deg/s (10-s mean, bias off): something is turning
    private static let GENTLE_RATE = 0.12          // deg/s mean an unfelt turn needs...
    private static let GENTLE_SECONDS = 15.0       // ...held this long
    private static let QUIET_RATE = 0.04           // ...after a minute this quiet (mean |rate|)
    private static let DRIFT_SECONDS = 120.0       // an unfelt rotation longer than this is the gyro drifting
    private static let END_SECONDS = 4.0           // seconds below EPISODE_RATE that end an episode
    private static let STRAIGHT_RATE = 0.35        // deg/s from the bias: a straight second, for the bias
    private static let STRAIGHT_LOAD = 0.015       // felt load within this of its level: not banked
    private static let BIAS_SECONDS = 300          // the bias is the median of this many straight seconds
    private static let HANDLED_ROTATION = 3.5      // deg/s: a second's median rotation over this is a hand
    private static let HANDLED_TILT = 5.0          // deg: or the phone's down moved this much in a second
    private static let HANDLED_PAD = 2.0           // s either side

    /// Degrees from north, clockwise; nil until a takeoff roll has been measured.
    private(set) var heading: Double?
    /// The takeoff roll's direction as used (the runway's, when it matched).
    private(set) var rollDirection: Double?
    /// The roll's push as measured, for the log.
    private(set) var measuredRollDirection: Double?
    /// The gyro's bias about the vertical, deg/s, learned on straight seconds.
    private(set) var bias = 0.0
    /// Axis headings (true, 0-180) of the runways at the airport the phone was last fixed at.
    var departureRunways: [Double] = []

    private var rollStart: Date?
    private var rollConfirmed = false
    private var rollNorth = 0.0, rollEast = 0.0, rollSamples = 0

    private var secF = 0.0, secW = 0.0, secN = 0, secT = 0.0
    private var secRotation: [Double] = [], secDown = [0.0, 0.0, 0.0], lastDown: [Double]?
    private var fWindow: [Double] = [], wWindow: [Double] = []
    private var loadHistory: [Double] = []
    private var straight: [Double] = []
    private var recent: [Double] = []              // |rate - bias| of the last 60 unhandled seconds
    private var lastHandled: Date?
    private var lastFeltEnd: Date?, lastFeltSign = 0.0

    // The rotation episode under way.
    private var episodeOn = false, episodeSign = 0.0, episodeAccepted = false, episodeFelt = false, episodeQuietBefore = true
    private var episodePending = 0.0, episodeApplied = 0.0, episodeBelow = 0.0, episodeSum = 0.0, episodeDuration = 0.0
    private var episodeRates: [Double] = []

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
        heading = nil; rollDirection = nil; measuredRollDirection = nil; rollStart = nil; rollConfirmed = false
        episodeOn = false
    }

    /// The plane's heading as another device measured it - the iPhone's, relayed while it flies (build 125). Taken
    /// only by a device that has not measured a takeoff roll of its own, every time it arrives, so if the relay
    /// stops this device's own gyroscope carries on from the latest one. Before, a watch whose takeoff came from
    /// the iPhone had no heading of its own and fell back to its compass, which a cabin ruins.
    mutating func adopt(heading h: Double) {
        guard h.isFinite, measuredRollDirection == nil else { return }
        heading = Self.wrap(h)
        episodeOn = false
    }

    /// World-frame acceleration (m/s², north and east) during a possible roll.
    mutating func addRollAcceleration(north: Double, east: Double, at time: Date) {
        guard let start = rollStart, heading == nil, time.timeIntervalSince(start) <= Self.ROLL_WINDOW,
              north.isFinite, east.isFinite else { return }
        rollNorth += north; rollEast += east; rollSamples += 1
    }

    /// One motion sample: rotation about Core Motion's down (deg/s, + = turning right), the raw specific
    /// force |userAcceleration + gravity| (g), the whole rotation rate's size (deg/s), Core Motion's down
    /// (gravity, any length) and the sample interval.
    mutating func ingest(rotationAboutDown w: Double, force f: Double, rotationMagnitude wt: Double,
                         down g: (Double, Double, Double), dt: Double, at time: Date) {
        guard dt > 0, dt < 0.5, w.isFinite, f.isFinite, wt.isFinite else { return }
        if heading == nil, rollConfirmed, let start = rollStart,
           time.timeIntervalSince(start) >= Self.ROLL_WINDOW, rollSamples > 50 {
            let measured = Self.wrap(atan2(rollEast, rollNorth) * 180 / .pi)
            measuredRollDirection = measured
            var used = measured
            let directions = departureRunways.flatMap { [Self.wrap($0), Self.wrap($0 + 180)] }
            if let best = directions.min(by: { abs(Self.diff($0, measured)) < abs(Self.diff($1, measured)) }),
               abs(Self.diff(best, measured)) <= Self.RUNWAY_SNAP {
                used = best
            }
            rollDirection = used
            heading = used
        }
        secF += f; secW += w * dt; secN += 1; secT += dt
        secRotation.append(wt); secDown[0] += g.0; secDown[1] += g.1; secDown[2] += g.2
        guard secT >= 1.0 else { return }
        let f1 = secF / Double(secN), w1 = secW / secT, t1 = secT, rotation = Self.median(secRotation)
        let gn = (secDown[0] * secDown[0] + secDown[1] * secDown[1] + secDown[2] * secDown[2]).squareRoot()
        let down = gn > 0 ? secDown.map { $0 / gn } : [0, 0, 1]
        let tilt = lastDown.map { acos(max(-1, min(1, $0[0] * down[0] + $0[1] * down[1] + $0[2] * down[2]))) * 180 / .pi } ?? 0
        lastDown = down
        secF = 0; secW = 0; secN = 0; secT = 0; secRotation.removeAll(keepingCapacity: true); secDown = [0, 0, 0]
        fWindow = Array((fWindow + [f1]).suffix(10)); wWindow = Array((wWindow + [w1]).suffix(10))
        let fs = fWindow.reduce(0, +) / Double(fWindow.count)
        let ws = wWindow.reduce(0, +) / Double(wWindow.count)
        let base = Self.median(loadHistory)
        let load = base > 0 ? fs / base - 1 : 0
        let n1 = base > 0 ? f1 / base : 1

        // The phone moving in a hand or a bag: nothing about this second is the plane's.
        if rotation > Self.HANDLED_ROTATION || tilt > Self.HANDLED_TILT { lastHandled = time }
        if let h = lastHandled, time.timeIntervalSince(h) <= Self.HANDLED_PAD {
            if episodeOn, !episodeAccepted { episodeOn = false }
            if episodeOn, episodeAccepted { endEpisode(kept: true, at: time) }
            return
        }
        loadHistory.append(fs); if loadHistory.count > 600 { loadHistory.removeFirst(loadHistory.count - 600) }

        let r1 = w1 - bias, rs = ws - bias
        let quietBefore = recent.isEmpty || recent.reduce(0, +) / Double(recent.count) < Self.QUIET_RATE
        recent.append(abs(rs)); if recent.count > 60 { recent.removeFirst(recent.count - 60) }
        // A felt second is measured about the banked floor: scale it back by the load (1/cos bank).
        let k = load > Self.TURN_LOAD ? max(1, min(n1, 1.5)) : 1.0

        guard var h = heading else { learn(w1, load: load, rs: rs); return }

        let sign = rs > 0 ? 1.0 : -1.0
        let afterTurn = lastFeltEnd.map { time.timeIntervalSince($0) <= Self.PAYBACK_SECONDS } ?? false
        let payback = afterTurn && sign == -lastFeltSign
        let felt = abs(rs) > Self.TURN_RATE && load > (payback ? Self.PAYBACK_LOAD : Self.TURN_LOAD)
        if !episodeOn {
            guard abs(rs) > Self.EPISODE_RATE else { learn(w1, load: load, rs: rs); return }
            episodeOn = true; episodeSign = sign; episodeAccepted = false; episodeFelt = false
            episodeQuietBefore = quietBefore
            episodePending = 0; episodeApplied = 0; episodeBelow = 0; episodeSum = 0; episodeDuration = 0
            episodeRates.removeAll(keepingCapacity: true)
        }
        if abs(rs) > Self.EPISODE_RATE, sign == episodeSign { episodeBelow = 0 } else { episodeBelow += t1 }
        episodeRates.append(w1); episodeDuration += t1; episodeSum += r1 * t1
        if felt { episodeFelt = true }
        let step = r1 * t1 * k
        if episodeAccepted { h = Self.wrap(h + step); episodeApplied += step } else { episodePending += step }
        if !episodeAccepted, episodeFelt || (episodeQuietBefore && episodeDuration >= Self.GENTLE_SECONDS
                                               && abs(episodeSum / episodeDuration) >= Self.GENTLE_RATE) {
            episodeAccepted = true; h = Self.wrap(h + episodePending); episodeApplied += episodePending; episodePending = 0
        }
        if !episodeFelt, episodeDuration > Self.DRIFT_SECONDS {
            // Too long to be a turn nobody felt: the gyro drifting. Take it back and learn it as the bias.
            h = Self.wrap(h - episodeApplied)
            let drift = Self.median(episodeRates)
            for _ in 0..<min(episodeRates.count, Self.BIAS_SECONDS) { straight.append(drift) }
            trimStraight(); bias = Self.median(straight)
            episodeOn = false
        } else if episodeBelow >= Self.END_SECONDS {
            endEpisode(kept: episodeAccepted, at: time)
        }
        heading = h
    }

    private mutating func endEpisode(kept: Bool, at time: Date) {
        if episodeFelt { lastFeltEnd = time; lastFeltSign = episodeSign }
        if !kept {
            for x in episodeRates where abs(x - bias) < Self.STRAIGHT_RATE { straight.append(x) }
            trimStraight(); if straight.count >= 30 { bias = Self.median(straight) }
        }
        episodeOn = false
    }

    /// A second that is not part of a turn teaches the gyro's bias, if it is straight and level.
    private mutating func learn(_ w1: Double, load: Double, rs: Double) {
        guard abs(load) < Self.STRAIGHT_LOAD, abs(rs) < Self.STRAIGHT_RATE else { return }
        straight.append(w1); trimStraight()
        if straight.count >= 30 { bias = Self.median(straight) }
    }

    private mutating func trimStraight() {
        if straight.count > Self.BIAS_SECONDS { straight.removeFirst(straight.count - Self.BIAS_SECONDS) }
    }

    private static func diff(_ a: Double, _ b: Double) -> Double {
        (a - b + 540).truncatingRemainder(dividingBy: 360) - 180
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
