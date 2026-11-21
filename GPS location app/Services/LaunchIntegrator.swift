import Foundation

/// Speed gained since the phone was last still, by strapdown integration of the raw motion.
///
/// WHY. In the air the cabin is smooth, and a speed model that reads vibration answers "nearly
/// standing still": replayed on the one recorded flight it counted 1.8 km of 74. But the
/// takeoff roll is the largest sustained push the phone ever feels, and it is measurable. Core
/// Motion's own attitude filter cannot keep it - it takes a steady push for a tilt and absorbs it -
/// so this uses the raw accelerometer (gravity + user acceleration) and carries the phone's
/// orientation with the gyro alone, from the last moment the phone was still.
///
/// On that flight, found with no GPS and no speed constant (the largest gain from any still
/// moment), it tracked GPS through the roll and the first climb: 265 km/h at 40 s against 266, 302
/// at 90 s against 314, 322 at 120 s against 298. After about two minutes the gyro's small errors
/// leak gravity into the integral faster than the aircraft speeds up, so the integration stops at
/// HORIZON and the speed it reached is held. The whole flight then comes to 45 km of 74.
///
/// It is not used on the ground: roads have the vibration model, which integration cannot
/// match over minutes. WorkoutSession reads it only in the air, when the air examples cannot
/// answer.
struct LaunchIntegrator {
    /// How long an integration is trusted. A sensor limit, not an aircraft speed: measured on the
    /// flight, the error stayed within about 25 km/h to two minutes and then grew quickly.
    static let HORIZON: TimeInterval = 120
    /// Still = over the last STILL_WINDOW seconds, mean rotation under STILL_ROTATION and the
    /// accelerometer magnitude steady to within STILL_FORCE_SD.
    static let STILL_WINDOW: TimeInterval = 3.0
    static let STILL_ROTATION = 0.05        // rad/s
    static let STILL_FORCE_SD = 0.05        // m/s²
    /// A still phone only means a stopped vehicle if the integration says it has slowed down:
    /// at steady speed the phone feels nothing, exactly as at rest. Below this (m/s, about the
    /// integration's own error over its horizon) a still phone may restart the integration.
    static let REANCHOR_BELOW = 3.0

    // NO ALLOCATION PER SAMPLE (build 160). This runs 50 times a second for the whole workout. It used to build several
    // three-element arrays per sample, keep its 3 s window as an array of tuples holding another array, and shift that
    // window with removeFirst on every sample. The window is now a ring buffer of plain values and the vectors are
    // tuples; every sum and product is done in the same order as before, so the results are bit for bit the same
    // (checked against the previous code on recorded 50 Hz traces).
    private struct Sample { var dt: Double; var f0: Double; var f1: Double; var f2: Double; var fm: Double; var w: Double }
    private var ring: ContiguousArray<Sample> = []
    private var head = 0
    private var windowCount: Int { ring.count - head }
    private var windowTime = 0.0
    private var gRef: (Double, Double, Double)?
    private var q = (1.0, 0.0, 0.0, 0.0)                  // current device frame -> anchor frame
    private var v = (0.0, 0.0, 0.0)
    private var sinceAnchor = 0.0
    /// Horizontal speed (m/s) reached since the last still moment, frozen at HORIZON; nil until
    /// the phone has been still once.
    private(set) var speed: Double?
    /// For FlightSpeedEngines: which anchor this is (it changes on every re-anchor), the direction of
    /// gravity in the phone at it (unit), and the seconds since it, counted on past HORIZON.
    private(set) var anchorCount = 0
    private(set) var anchorGravity: [Double]?
    private(set) var anchorAge = 0.0
    /// The integration has reached its horizon and is holding what it reached.
    var isHolding: Bool { gRef != nil && sinceAnchor >= Self.HORIZON }

    mutating func reset() { self = LaunchIntegrator() }

    /// One device-motion sample: user acceleration and gravity in g, rotation rate in rad/s.
    /// `airborne` (the barometric flight phase) forbids restarting: a smooth climb or cruise feels
    /// exactly like standing still, and restarting there would throw the takeoff away.
    mutating func ingest(userAcceleration a: [Double], gravity g: [Double], rotation w: [Double],
                         dt: Double, airborne: Bool) {
        guard dt > 0, dt < 0.5, a.count == 3, g.count == 3, w.count == 3 else { return }
        let f0 = (a[0] + g[0]) * 9.80665, f1 = (a[1] + g[1]) * 9.80665, f2 = (a[2] + g[2]) * 9.80665
        let fm = (f0 * f0 + f1 * f1 + f2 * f2).squareRoot()
        let wm = (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).squareRoot()
        ring.append(Sample(dt: dt, f0: f0, f1: f1, f2: f2, fm: fm, w: wm)); windowTime += dt
        while windowTime > Self.STILL_WINDOW, head < ring.count {
            windowTime -= ring[head].dt; head += 1
        }
        if head > 512, head * 2 > ring.count { ring.removeFirst(head); head = 0 }
        let mayRestart = !airborne && (gRef == nil || (speed ?? 0) < Self.REANCHOR_BELOW
                                       || sinceAnchor >= Self.HORIZON)
        if mayRestart, isStill() {
            // Re-anchor on every still sample, so the integration starts from the LAST still moment.
            let n = Double(windowCount)
            var s0 = 0.0, s1 = 0.0, s2 = 0.0
            for i in head..<ring.count { s0 = s0 + ring[i].f0 }
            for i in head..<ring.count { s1 = s1 + ring[i].f1 }
            for i in head..<ring.count { s2 = s2 + ring[i].f2 }
            let g = (s0 / n, s1 / n, s2 / n)
            gRef = g
            q = (1, 0, 0, 0); v = (0, 0, 0); sinceAnchor = 0; speed = 0
            anchorCount += 1; anchorAge = 0
            let gn = max((g.0 * g.0 + g.1 * g.1 + g.2 * g.2).squareRoot(), 1e-9)
            anchorGravity = [g.0 / gn, g.1 / gn, g.2 / gn]
            return
        }
        if gRef != nil { anchorAge += dt }
        guard let gRef, sinceAnchor < Self.HORIZON else { return }
        let r = rotate((f0, f1, f2), by: q)
        v.0 += (r.0 - gRef.0) * dt
        v.1 += (r.1 - gRef.1) * dt
        v.2 += (r.2 - gRef.2) * dt
        sinceAnchor += dt
        // Carry the orientation with the gyro.
        let ang0 = w[0] * dt, ang1 = w[1] * dt, ang2 = w[2] * dt
        let th = (ang0 * ang0 + ang1 * ang1 + ang2 * ang2).squareRoot()
        if th > 1e-12 {
            let s = sin(th / 2) / th
            q = multiply(q, (cos(th / 2), ang0 * s, ang1 * s, ang2 * s))
            let norm = (q.0 * q.0 + q.1 * q.1 + q.2 * q.2 + q.3 * q.3).squareRoot()
            q = (q.0 / norm, q.1 / norm, q.2 / norm, q.3 / norm)
        }
        let gn = (gRef.0 * gRef.0 + gRef.1 * gRef.1 + gRef.2 * gRef.2).squareRoot()
        let up = (gRef.0 / gn, gRef.1 / gn, gRef.2 / gn)
        let along = v.0 * up.0 + v.1 * up.1 + v.2 * up.2
        let h = (v.0 - along * up.0, v.1 - along * up.1, v.2 - along * up.2)
        speed = (h.0 * h.0 + h.1 * h.1 + h.2 * h.2).squareRoot()
    }

    private func isStill() -> Bool {
        guard windowTime >= Self.STILL_WINDOW * 0.95, windowCount >= 10 else { return false }
        let n = Double(windowCount)
        var sw = 0.0
        for i in head..<ring.count { sw = sw + ring[i].w }
        let meanW = sw / n
        guard meanW < Self.STILL_ROTATION else { return false }
        var sf = 0.0
        for i in head..<ring.count { sf = sf + ring[i].fm }
        let meanF = sf / n
        var sv = 0.0
        for i in head..<ring.count { sv = sv + (ring[i].fm - meanF) * (ring[i].fm - meanF) }
        let varF = sv / n
        return varF.squareRoot() < Self.STILL_FORCE_SD
    }

    private func multiply(_ a: (Double, Double, Double, Double), _ b: (Double, Double, Double, Double)) -> (Double, Double, Double, Double) {
        (a.0 * b.0 - a.1 * b.1 - a.2 * b.2 - a.3 * b.3,
         a.0 * b.1 + a.1 * b.0 + a.2 * b.3 - a.3 * b.2,
         a.0 * b.2 - a.1 * b.3 + a.2 * b.0 + a.3 * b.1,
         a.0 * b.3 + a.1 * b.2 - a.2 * b.1 + a.3 * b.0)
    }

    private func rotate(_ x: (Double, Double, Double), by q: (Double, Double, Double, Double)) -> (Double, Double, Double) {
        let (w, a, b, c) = q
        return ((1 - 2 * (b * b + c * c)) * x.0 + 2 * (a * b - w * c) * x.1 + 2 * (a * c + w * b) * x.2,
                2 * (a * b + w * c) * x.0 + (1 - 2 * (a * a + c * c)) * x.1 + 2 * (b * c - w * a) * x.2,
                2 * (a * c - w * b) * x.0 + 2 * (b * c + w * a) * x.1 + (1 - 2 * (a * a + b * b)) * x.2)
    }
}
