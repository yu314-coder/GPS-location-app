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
/// bundled; DepartureRunways). Within 40° of one of its two directions, that direction is the start (or within
/// 60° when no other runway direction comes within 30° more: build 127).
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
/// THE TURN CHECKED BY THE MAGNETOMETER (build 126). Core Motion's rotation rate is bias-corrected, and iOS
/// learns that bias whenever the device seems still. A phone lying still on an airliner IS still, apart from a
/// smooth turn at 1-2°/s - and iOS took part of each turn for bias. On BR226 the 17 (lying by a power outlet)
/// read a median 64% of the nine turns ADS-B saw (94° of the 209° approach orbit) and then read it back the
/// other way at up to 0.5°/s once the plane was straight - a "payback" that looks like a gentle turn; the
/// 16 Pro, in use, read 98%. The magnetometer is not fooled: the horizontal field, in the phone's own frame,
/// turned with the plane (the 17: 1.04 of each turn, 3° typical error against the gyro's 22°). It is useless
/// as a compass in a cabin, but over the minute or two of a turn, with the phone still and the field steady,
/// it measures how far the phone turned. So every rotation episode is also followed in the field, about a
/// device axis laid level, and when the field stayed steady (strength within 30%, horizontal part 15 µT
/// or more, the phone not handled):
///   - a felt turn takes the field's angle when the field turned further the same way, by 8° or more (the learning
///     only ever shortens a turn), or 10° or more the OTHER way (the gyro was paying an earlier turn back);
///   - a rotation the rules did not accept (no bank felt, too soon after a turn the other way) counts as the
///     field's angle when the gyro and the field both turned 8° or more the same way. On the 17 that was a real
///     15° right turn hidden in the payback of the departure turn; smaller field turns are left out, since a
///     phone near a magnet showed the field drifting 5-8° with no turn at all;
///   - a turn ended by a hand is checked up to the last second the phone was still, and after a touch the field
///     is followed again from the first still second.
/// And a tilt counts as the phone moving only when the gyro turned the phone that far: the 17's gravity estimate
/// jumped 10° in one second as the plane rolled into the orbit, with the phone turning 2.6°/s.
/// Replayed on the six recordings: the 17's last fifteen minutes before touchdown 136° -> 23° typical error, the
/// iPad 83° -> 55°, the mean of the six 26.5° -> 19.9°, the route ends (ADS-B speed) 5,699 -> 4,271 km in all.
/// The 16 Pro on BR226 lost a lucky cancellation (95 -> 137 km) although each turn it changed matched ADS-B.
///
/// Replayed on BR226 (three devices), BR215 (two) and the August flight against ADS-B or GPS, with ADS-B's own
/// speed so only the heading differs: route ends 16 Pro 894 -> 95 km, 17 2,523 -> 168 km (BR226), 16 Pro
/// 871 -> 626 km (BR215), August 7° -> 5° typical. The BR215 17 went 183 -> 590 km: build 114 had counted a
/// phone being handled as a 15° turn that happened to cancel a turn missed while iOS paused the app.
///
/// The watch carries an identical copy (scripts/check_watch_engine.sh).
struct FlightHeading {
    static let ROLL_WINDOW: TimeInterval = 35
    private static let RUNWAY_SNAP = 40.0          // deg: the push within this of a runway direction takes it,
    private static let RUNWAY_SNAP_CLEAR = 60.0    // or within this when every other direction is at least
    private static let RUNWAY_CLEAR = 30.0         // this much further away (build 127)
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
    private static let TILT_SHARE = 0.5            // a tilt is the phone moving only if the gyro turned it this share of it
    private static let MAG_HORIZONTAL = 15.0       // µT: the field's horizontal part must be at least this...
    private static let MAG_STEADY = 0.30           // ...and its strength within this of its mean over the turn
    private static let MAG_MARGIN = 3.0            // deg the field must turn beyond a felt turn's gyro to be taken
    private static let MAG_OPPOSITE = 10.0         // deg the field must turn against a felt turn's gyro
    private static let MAG_UNFELT = 8.0            // deg both must turn for a rotation the rules did not accept

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
    /// The last turn the magnetometer lengthened: (gyro's degrees, field's degrees), for the log.
    private(set) var lastMagneticTurn: (gyro: Double, field: Double, at: Date)?

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

    // The magnetic field: this second's sum, the last unhandled second's horizontal field (phone frame), and the
    // field followed through the episode under way about a phone axis that lies near level.
    private var secB = [0.0, 0.0, 0.0], secBN = 0
    private var lastFieldH: [Double]?, lastFieldStrength = 0.0
    private var magRef: [Double]?, magAngle = 0.0, magTurn = 0.0, magMin = 0.0, magMax = 0.0, magSum = 0.0, magN = 0

    /// A takeoff roll may be starting (the integration just passed 30 kt): collect its push from now.
    ///
    /// ON THE GROUND, A NEW ROLL STARTS THE HEADING AFRESH (build 127). The heading is set once, 35 s into a confirmed
    /// roll, and held until the cabin lands. Replayed on BR226, the iPhone 17's takeoff integration ran away while
    /// the phone was being handled at the gate - 6.6 m/s faster every second, from a tilt it took for a push - and
    /// passed 30 kt and 200 km/h within 30 s: a "roll" half an hour before the real one. Its push (92°) became the
    /// heading, and the real roll down runway 20C was never measured. Live, the same phone's integration crept up
    /// more slowly and missed the 30-s test, so build 123 got away with it. A roll that begins while the cabin is
    /// still on the ground now drops any heading held from before; in the air nothing changes.
    mutating func beginRoll(at time: Date, cabinAirborne: Bool) {
        if !cabinAirborne, heading != nil { endFlight() }
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
    /// (gravity, any length), the calibrated magnetic field in the device's frame (µT; nil when there is none)
    /// and the sample interval.
    mutating func ingest(rotationAboutDown w: Double, force f: Double, rotationMagnitude wt: Double,
                         down g: (Double, Double, Double), field b: (Double, Double, Double)? = nil,
                         dt: Double, at time: Date) {
        guard dt > 0, dt < 0.5, w.isFinite, f.isFinite, wt.isFinite else { return }
        if heading == nil, rollConfirmed, let start = rollStart,
           time.timeIntervalSince(start) >= Self.ROLL_WINDOW, rollSamples > 50 {
            let measured = Self.wrap(atan2(rollEast, rollNorth) * 180 / .pi)
            measuredRollDirection = measured
            var used = measured
            // Build 127: also within 60° when no other runway direction is within 30° more. Replayed, the 17's
            // push read 244° down runway 20C (203°) - 41° off, by an outlet and timed from 2 s before the roll, while
            // the plane was still lining up - and Changi's runways are all parallel, so nothing else was close.
            let directions = departureRunways.flatMap { [Self.wrap($0), Self.wrap($0 + 180)] }
                .sorted { abs(Self.diff($0, measured)) < abs(Self.diff($1, measured)) }
            if let best = directions.first {
                let off = abs(Self.diff(best, measured))
                let next = directions.dropFirst().first { abs(Self.diff($0, best)) > 5 }
                let clear = next.map { abs(Self.diff($0, measured)) - off >= Self.RUNWAY_CLEAR } ?? true
                if off <= Self.RUNWAY_SNAP || (off <= Self.RUNWAY_SNAP_CLEAR && clear) { used = best }
            }
            rollDirection = used
            heading = used
        }
        secF += f; secW += w * dt; secN += 1; secT += dt
        secRotation.append(wt); secDown[0] += g.0; secDown[1] += g.1; secDown[2] += g.2
        if let b, b.0.isFinite, b.1.isFinite, b.2.isFinite { secB[0] += b.0; secB[1] += b.1; secB[2] += b.2; secBN += 1 }
        guard secT >= 1.0 else { return }
        let f1 = secF / Double(secN), w1 = secW / secT, t1 = secT, rotation = Self.median(secRotation)
        let turned = secRotation.reduce(0, +) / Double(max(secRotation.count, 1)) * t1
        let gn = (secDown[0] * secDown[0] + secDown[1] * secDown[1] + secDown[2] * secDown[2]).squareRoot()
        let down = gn > 0 ? secDown.map { $0 / gn } : [0, 0, 1]
        let tilt = lastDown.map { acos(max(-1, min(1, $0[0] * down[0] + $0[1] * down[1] + $0[2] * down[2]))) * 180 / .pi } ?? 0
        lastDown = down
        secF = 0; secW = 0; secN = 0; secT = 0; secRotation.removeAll(keepingCapacity: true); secDown = [0, 0, 0]
        // This second's field: its strength and its horizontal part, in the device's frame.
        var fieldH: [Double]? = nil, fieldStrength = 0.0
        if secBN > 0 {
            let bm = secB.map { $0 / Double(secBN) }
            fieldStrength = (bm[0] * bm[0] + bm[1] * bm[1] + bm[2] * bm[2]).squareRoot()
            let along = bm[0] * down[0] + bm[1] * down[1] + bm[2] * down[2]
            let hv = (0..<3).map { bm[$0] - along * down[$0] }
            if (hv[0] * hv[0] + hv[1] * hv[1] + hv[2] * hv[2]).squareRoot() >= Self.MAG_HORIZONTAL { fieldH = hv }
        }
        secB = [0, 0, 0]; secBN = 0
        fWindow = Array((fWindow + [f1]).suffix(10)); wWindow = Array((wWindow + [w1]).suffix(10))
        let fs = fWindow.reduce(0, +) / Double(fWindow.count)
        let ws = wWindow.reduce(0, +) / Double(wWindow.count)
        let base = Self.median(loadHistory)
        let load = base > 0 ? fs / base - 1 : 0
        let n1 = base > 0 ? f1 / base : 1

        // The phone moving in a hand or a bag: nothing about this second is the plane's.
        if rotation > Self.HANDLED_ROTATION || (tilt > Self.HANDLED_TILT && turned >= Self.TILT_SHARE * tilt) { lastHandled = time }
        if let h = lastHandled, time.timeIntervalSince(h) <= Self.HANDLED_PAD {
            if episodeOn, episodeAccepted, episodeFelt, var hh = heading { checkAgainstField(&hh, at: time); heading = hh }
            magRef = nil; lastFieldH = nil
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

        let previousField = lastFieldH, previousStrength = lastFieldStrength
        lastFieldH = fieldH; lastFieldStrength = fieldStrength
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
            // Follow the field from the second before the turn, about the device axis nearest level.
            magRef = nil
            // (After a touch there is no still second before: the field is followed from this one.)
            if let ph = previousField ?? fieldH {
                let ps = previousField != nil ? previousStrength : fieldStrength
                let axes: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
                let axis = axes.min { abs(zip($0, down).map(*).reduce(0, +)) < abs(zip($1, down).map(*).reduce(0, +)) }!
                magRef = axis; magAngle = Self.fieldAngle(ph, ref: axis, down: down); magTurn = 0
                magMin = ps; magMax = ps; magSum = ps; magN = 1
            }
        }
        if let ref = magRef {
            if let fh = fieldH {
                let a = Self.fieldAngle(fh, ref: ref, down: down)
                magTurn -= Self.diff(a, magAngle); magAngle = a       // the field turns the other way in the phone
                magMin = min(magMin, fieldStrength); magMax = max(magMax, fieldStrength); magSum += fieldStrength; magN += 1
            } else { magRef = nil }
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
            if episodeAccepted, episodeFelt { checkAgainstField(&h, at: time) }
            if !episodeAccepted, fieldSteady, abs(episodeSum) >= Self.MAG_UNFELT, episodeSum * episodeSign > 0,
               magTurn * episodeSign > 0, abs(magTurn) >= Self.MAG_UNFELT {
                h = Self.wrap(h + magTurn); lastMagneticTurn = (0, magTurn, time)
            }
            magRef = nil
            endEpisode(kept: episodeAccepted, at: time)
        }
        heading = h
    }

    /// Whether the field followed through this episode stayed usable: still referenced, its strength steady.
    private var fieldSteady: Bool {
        guard magRef != nil, magN > 1 else { return false }
        return (magMax - magMin) / (magSum / Double(magN)) <= Self.MAG_STEADY
    }

    /// A felt turn against the field: the field's angle replaces the gyro's when it turned further the same way, or
    /// clearly the other way.
    private mutating func checkAgainstField(_ h: inout Double, at time: Date) {
        guard fieldSteady else { magRef = nil; return }
        let further = magTurn * episodeSign > 0 && abs(magTurn) > abs(episodeApplied) + Self.MAG_MARGIN
            && abs(magTurn) >= Self.MAG_UNFELT && abs(magTurn) <= 2.5 * abs(episodeApplied) + 20
        let against = magTurn * episodeSign < 0 && abs(magTurn) >= Self.MAG_OPPOSITE
        if further || against {
            h = Self.wrap(h + magTurn - episodeApplied)
            lastMagneticTurn = (episodeApplied, magTurn, time)
            episodeApplied = magTurn
        }
        magRef = nil
    }

    /// The horizontal field's direction in the device's frame (deg) from a device axis laid level, positive in
    /// the sense of a rotation about `down`. The device turning right turns the field left relative to it.
    private static func fieldAngle(_ hv: [Double], ref: [Double], down: [Double]) -> Double {
        let along = ref[0] * down[0] + ref[1] * down[1] + ref[2] * down[2]
        let r = (0..<3).map { ref[$0] - along * down[$0] }
        let cx = [r[1] * hv[2] - r[2] * hv[1], r[2] * hv[0] - r[0] * hv[2], r[0] * hv[1] - r[1] * hv[0]]
        let y = cx[0] * down[0] + cx[1] * down[1] + cx[2] * down[2]
        let x = r[0] * hv[0] + r[1] * hv[1] + r[2] * hv[2]
        return atan2(y, x) * 180 / .pi
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
