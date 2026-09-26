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

    private var window: [(dt: Double, f: [Double], fm: Double, w: Double)] = []
    private var windowTime = 0.0
    private var gRef: [Double]?
    private var q = [1.0, 0.0, 0.0, 0.0]                  // current device frame -> anchor frame
    private var v = [0.0, 0.0, 0.0]
    private var sinceAnchor = 0.0
    /// Horizontal speed (m/s) reached since the last still moment, frozen at HORIZON; nil until
    /// the phone has been still once.
    private(set) var speed: Double?

    mutating func reset() { self = LaunchIntegrator() }

    /// One device-motion sample: user acceleration and gravity in g, rotation rate in rad/s.
    /// `airborne` (the barometric flight phase) forbids restarting: a smooth climb or cruise feels
    /// exactly like standing still, and restarting there would throw the takeoff away.
    mutating func ingest(userAcceleration a: [Double], gravity g: [Double], rotation w: [Double],
                         dt: Double, airborne: Bool) {
        guard dt > 0, dt < 0.5, a.count == 3, g.count == 3, w.count == 3 else { return }
        let f = (0..<3).map { (a[$0] + g[$0]) * 9.80665 }
        let fm = (f[0] * f[0] + f[1] * f[1] + f[2] * f[2]).squareRoot()
        let wm = (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).squareRoot()
        window.append((dt, f, fm, wm)); windowTime += dt
        while windowTime > Self.STILL_WINDOW, let first = window.first {
            windowTime -= first.dt; window.removeFirst()
        }
        let mayRestart = !airborne && (gRef == nil || (speed ?? 0) < Self.REANCHOR_BELOW
                                       || sinceAnchor >= Self.HORIZON)
        if mayRestart, isStill() {
            // Re-anchor on every still sample, so the integration starts from the LAST still moment.
            let n = Double(window.count)
            gRef = (0..<3).map { i in window.reduce(0) { $0 + $1.f[i] } / n }
            q = [1, 0, 0, 0]; v = [0, 0, 0]; sinceAnchor = 0; speed = 0
            return
        }
        guard let gRef, sinceAnchor < Self.HORIZON else { return }
        let r = rotate(f, by: q)
        for i in 0..<3 { v[i] += (r[i] - gRef[i]) * dt }
        sinceAnchor += dt
        // Carry the orientation with the gyro.
        let ang = w.map { $0 * dt }
        let th = (ang[0] * ang[0] + ang[1] * ang[1] + ang[2] * ang[2]).squareRoot()
        if th > 1e-12 {
            let s = sin(th / 2) / th
            q = multiply(q, [cos(th / 2), ang[0] * s, ang[1] * s, ang[2] * s])
            let norm = (q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]).squareRoot()
            q = q.map { $0 / norm }
        }
        let gn = (gRef[0] * gRef[0] + gRef[1] * gRef[1] + gRef[2] * gRef[2]).squareRoot()
        let up = gRef.map { $0 / gn }
        let along = v[0] * up[0] + v[1] * up[1] + v[2] * up[2]
        let h = (0..<3).map { v[$0] - along * up[$0] }
        speed = (h[0] * h[0] + h[1] * h[1] + h[2] * h[2]).squareRoot()
    }

    private func isStill() -> Bool {
        guard windowTime >= Self.STILL_WINDOW * 0.95, window.count >= 10 else { return false }
        let n = Double(window.count)
        let meanW = window.reduce(0) { $0 + $1.w } / n
        guard meanW < Self.STILL_ROTATION else { return false }
        let meanF = window.reduce(0) { $0 + $1.fm } / n
        let varF = window.reduce(0) { $0 + ($1.fm - meanF) * ($1.fm - meanF) } / n
        return varF.squareRoot() < Self.STILL_FORCE_SD
    }

    private func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
         a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
         a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
         a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0]]
    }

    private func rotate(_ x: [Double], by q: [Double]) -> [Double] {
        let (w, a, b, c) = (q[0], q[1], q[2], q[3])
        return [(1 - 2 * (b * b + c * c)) * x[0] + 2 * (a * b - w * c) * x[1] + 2 * (a * c + w * b) * x[2],
                2 * (a * b + w * c) * x[0] + (1 - 2 * (a * a + c * c)) * x[1] + 2 * (b * c - w * a) * x[2],
                2 * (a * c - w * b) * x[0] + 2 * (b * c + w * a) * x[1] + (1 - 2 * (a * a + b * b)) * x[2]]
    }
}
