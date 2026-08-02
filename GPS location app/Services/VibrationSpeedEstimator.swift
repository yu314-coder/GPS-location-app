import Foundation

/// Estimates speed from the VIBRATION SIGNATURE of the ride instead of integrating acceleration.
///
/// Rationale (CarSpeedNet, arXiv 2401.07468): classical inertial speed estimation fails in a
/// vehicle because "small biases accumulate rapidly, orientation uncertainty contaminates
/// projected acceleration, and integration amplifies noise over time". A constant bias is
/// indistinguishable from real sustained acceleration, so no amount of DENOISING removes it —
/// low-pass, wavelet and Kalman filters all pass DC through, and integrating it yields an error
/// that grows linearly with time (0.05 m/s² is still 11 km/h per minute).
///
/// That paper's fix is to stop integrating: road and engine vibration scale with speed, so speed
/// can be read from the vibration signature directly, with no accumulation and therefore no
/// drift. They learn the mapping with a neural network trained offline; this is the same idea
/// fitted ONLINE, per vehicle and per phone placement, from GPS while GPS is available — then
/// used when it is not.
final class VibrationSpeedEstimator {

    // Rolling vibration feature -----------------------------------------------------------
    private var magnitudeMean: Double = 0          // slow mean of |a|, removes the DC part
    private var vibrationEnergy: Double = 0        // smoothed |‖a‖ − mean|, the feature
    private var initialised = false
    /// Seconds of data ingested this workout. The feature is an EMA seeded at zero, so early
    /// readings are a startup transient rather than a measurement.
    private var ingestElapsed: TimeInterval = 0
    private let FEATURE_WARMUP_SECONDS = 5.0

    /// The feature is O(0.1). Raising it to O(1) before forming the regression's power sums
    /// keeps Σu⁴ from underflowing into the noise and makes the conditioning test meaningful.
    private let SCALE = 10.0

    // THE FIT ------------------------------------------------------------------------------
    //
    // speed = p0 + p1·u + p2·u²    (u = SCALE · vibrationEnergy)
    //
    // Fitted by ordinary least squares over GPS-labelled samples, INCLUDING stopped ones.
    //
    // Why an intercept rather than an anchored line through a measured rest floor: the floor
    // could not be measured reliably. It was taken as a running minimum of the feature, which
    // in a car that never fully stops while recording is the QUIETEST DRIVING MOMENT, not rest.
    // Everything above such a floor is a small fraction of the real signal, so speed under-read
    // badly (16 km/h at a true 40–80), and anything quieter than it went negative and clamped to
    // zero (a slow basement crawl reading 0). Anchoring on a quantity we cannot measure was the
    // mistake; the zero crossing is far better learned from data, and stopped-at-a-light samples
    // — which the old `speed > 2.0` gate discarded — pin it directly and are plentiful in city
    // driving.
    //
    // Why quadratic rather than linear: the response SATURATES. Measured steady state —
    //     0 km/h 0.037 | 18 0.103 | 36 0.157 | 54 0.196 | 72 0.225 | 90 0.247
    // the increments shrink at every step, because the feature is a rectified norm whose
    // deviation grows sub-linearly once the oscillation exceeds the DC level. One straight line
    // through a concave curve must over-read at the bottom and under-read at the top; through
    // those extremes it gives 6.9 where truth is 5 and 22 where truth is 25. Scaled up that is
    // the long-standing "37 km/h when the car is doing 100". Two parameters bend with the
    // saturation while staying inspectable and closed-form — CarSpeedNet needs a network only
    // because it must generalise across vehicles offline, whereas this is fitted per vehicle
    // and per placement online.
    private var n = 0.0
    private var sumU = 0.0, sumU2 = 0.0, sumU3 = 0.0, sumU4 = 0.0
    private var sumS = 0.0, sumUS = 0.0, sumU2S = 0.0
    private var minSeenU = Double.greatestFiniteMagnitude
    private var maxSeenU = -Double.greatestFiniteMagnitude
    private var minSeenSpeed = Double.greatestFiniteMagnitude
    private var maxSeenSpeed = -Double.greatestFiniteMagnitude
    /// Samples taken while essentially stopped. Capped as a fraction of the total so that a long
    /// wait at a light cannot drown out the moving data and flatten the curve.
    private var nZeroish = 0.0

    private var p0: Double?
    private var p1: Double = 0
    private var p2: Double = 0
    private var fitIsFullyEvidenced = false

    /// Enough evidence to trust the full fit: a decent sample count across a real speed spread.
    private let MIN_SAMPLES = 60.0
    private let MIN_SPEED_SPREAD = 6.0   // m/s between the slowest and fastest calibration point
    // PROVISIONAL fit, used only until the full bar is met, and deliberately LINEAR: a dozen
    // samples over a narrow range cannot condition a curve, and an ill-fitted quadratic can bend
    // the wrong way entirely. A rough line is not accurate, but it is bounded and monotonic in
    // speed — whereas the alternative while waiting is raw double-integration, which is
    // unbounded and was observed reporting 252 km/h and fabricating 7.6 km of route in 8
    // minutes. Wrong by 30% beats wrong by an order of magnitude.
    private let PROVISIONAL_SAMPLES = 12.0
    private let PROVISIONAL_SPEED_SPREAD = 2.5

    var isCalibrated: Bool { p0 != nil }
    /// Distinguishes the provisional fit from the fully-evidenced one, for the status line.
    var isProvisional: Bool { p0 != nil && !fitIsFullyEvidenced }

    // PERSISTENCE ------------------------------------------------------------------------
    //
    // The model used to be wiped at every workout start, so each drive had to re-earn 60
    // GPS-calibrated samples spanning 6 m/s BEFORE producing anything — and a trip that
    // enables Force Velocity and then loses GPS never gets that chance, which is precisely the
    // case this feature exists for. The mapping is a property of the VEHICLE AND PHONE
    // PLACEMENT, not of a single workout, so it is carried across trips.
    //
    // v4: the model is now an intercept-bearing quadratic in the scaled feature. Everything
    // stored by earlier builds is unusable — v2 and v3 both encode a rest baseline that was
    // either pinned at zero by a startup-transient bug or captured mid-drive.
    private static let keyP0 = "VibrationSpeedEstimator.p0.v4"
    private static let keyP1 = "VibrationSpeedEstimator.p1.v4"
    private static let keyP2 = "VibrationSpeedEstimator.p2.v4"
    private static let keyMaxU = "VibrationSpeedEstimator.maxU.v4"
    private static let allKeys = [keyP0, keyP1, keyP2, keyMaxU]

    /// Start a workout: clear the per-trip signal state but KEEP a previously learned model.
    func reset() {
        magnitudeMean = 0; vibrationEnergy = 0; initialised = false; ingestElapsed = 0
        n = 0; nZeroish = 0
        sumU = 0; sumU2 = 0; sumU3 = 0; sumU4 = 0
        sumS = 0; sumUS = 0; sumU2S = 0
        minSeenU = .greatestFiniteMagnitude; maxSeenU = -.greatestFiniteMagnitude
        minSeenSpeed = .greatestFiniteMagnitude; maxSeenSpeed = -.greatestFiniteMagnitude

        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.keyP0) != nil {
            p0 = defaults.double(forKey: Self.keyP0)
            p1 = defaults.double(forKey: Self.keyP1)
            p2 = defaults.double(forKey: Self.keyP2)
            maxSeenU = defaults.double(forKey: Self.keyMaxU)
            fitIsFullyEvidenced = true
        } else {
            p0 = nil; p1 = 0; p2 = 0
            fitIsFullyEvidenced = false
        }
    }

    /// Discard the stored model — for when the phone moves to a different vehicle or mount.
    func forgetLearnedModel() {
        for key in Self.allKeys { UserDefaults.standard.removeObject(forKey: key) }
        p0 = nil; p1 = 0; p2 = 0; fitIsFullyEvidenced = false
    }

    private func persistIfFullyEvidenced() {
        guard fitIsFullyEvidenced, let p0 else { return }
        let defaults = UserDefaults.standard
        defaults.set(p0, forKey: Self.keyP0)
        defaults.set(p1, forKey: Self.keyP1)
        defaults.set(p2, forKey: Self.keyP2)
        defaults.set(maxSeenU, forKey: Self.keyMaxU)
    }

    /// The device is confirmed stationary, so this vibration reading corresponds to zero speed.
    /// Fed in as an ordinary calibration sample: it pins the low end of the curve, which is the
    /// part that decides whether a stopped vehicle reads zero.
    func observeAtRest() {
        addSample(speed: 0)
    }

    /// Feed one raw device-frame acceleration sample (m/s², gravity already removed).
    func ingest(ax: Double, ay: Double, az: Double, dt: TimeInterval) {
        guard dt > 0 else { return }
        ingestElapsed += dt
        let magnitude = sqrt(ax*ax + ay*ay + az*az)
        if !initialised { magnitudeMean = magnitude; initialised = true }
        // The mean exists ONLY to strip the DC offset (sensor bias, gravity residual), so it
        // must be far SLOWER than any real speed change. At 2 s it chased the signal: when the
        // car accelerated and vibration rose, the mean caught up within a couple of seconds and
        // cancelled the very increase being measured, so the feature responded only
        // transiently — the reported ~10 s sluggishness. At 30 s it is a true baseline and
        // speed-driven changes survive.
        magnitudeMean += (magnitude - magnitudeMean) * min(dt / (30.0 + dt), 1.0)
        let deviation = abs(magnitude - magnitudeMean)
        // Short enough to track acceleration, long enough to average the vibration waveform
        // itself (road noise is tens of Hz, so 0.5 s spans many cycles).
        vibrationEnergy += (deviation - vibrationEnergy) * min(dt / (0.5 + dt), 1.0)
    }

    /// Teach the model with a trustworthy GPS speed sample. `horizontalAccuracy` in metres;
    /// pass a very large number if unknown (rejected below rather than trusted by default).
    func calibrate(withGPSSpeed speed: Double, horizontalAccuracy: Double) {
        // A poor fix's speed field is frequently a multipath/urban-canyon spike unrelated to
        // real motion. Feeding that in poisoned the fit: a walk produced spurious ~20 km/h
        // "calibration" points that were pure GPS noise, yielding a model that reported
        // vibration-derived speed while the phone sat still.
        guard horizontalAccuracy >= 0, horizontalAccuracy < 20.0 else { return }
        guard speed >= 0 else { return }
        addSample(speed: speed)
    }

    private func addSample(speed: Double) {
        // Before warm-up the feature is still climbing out of its zero seed, so it describes the
        // filter's initial condition rather than the ride.
        guard initialised, ingestElapsed >= FEATURE_WARMUP_SECONDS, vibrationEnergy > 1e-4 else { return }

        // Stopped samples are what pin the zero end, but a long wait at a light would otherwise
        // pile up thousands of them and flatten the curve toward a constant.
        let isZeroish = speed < 1.0
        if isZeroish, nZeroish >= 10, nZeroish >= 0.4 * n { return }

        let u = vibrationEnergy * SCALE
        n += 1
        if isZeroish { nZeroish += 1 }
        sumU += u; sumU2 += u*u; sumU3 += u*u*u; sumU4 += u*u*u*u
        sumS += speed; sumUS += u*speed; sumU2S += u*u*speed
        minSeenU = Swift.min(minSeenU, u); maxSeenU = Swift.max(maxSeenU, u)
        minSeenSpeed = Swift.min(minSeenSpeed, speed); maxSeenSpeed = Swift.max(maxSeenSpeed, speed)

        let spread = maxSeenSpeed - minSeenSpeed
        let fullyEvidenced = n >= MIN_SAMPLES && spread >= MIN_SPEED_SPREAD
        let provisional = n >= PROVISIONAL_SAMPLES && spread >= PROVISIONAL_SPEED_SPREAD
        guard fullyEvidenced || provisional else { return }

        if fullyEvidenced, solveQuadratic() {
            fitIsFullyEvidenced = true
            persistIfFullyEvidenced()
            return
        }
        if solveLinear() {
            // A linear fit only ever counts as provisional: it cannot represent the saturation,
            // so it must not be persisted as though it were the finished model.
            fitIsFullyEvidenced = false
        }
    }

    /// speed = p0 + p1·u + p2·u², by the 3x3 normal equations. Returns false if the system is
    /// ill-conditioned or the result is not a sane, increasing curve.
    private func solveQuadratic() -> Bool {
        let a11 = n,     a12 = sumU,  a13 = sumU2
        let a21 = sumU,  a22 = sumU2, a23 = sumU3
        let a31 = sumU2, a32 = sumU3, a33 = sumU4
        let b1 = sumS,   b2 = sumUS,  b3 = sumU2S

        let det = a11 * (a22*a33 - a23*a32)
                - a12 * (a21*a33 - a23*a31)
                + a13 * (a21*a32 - a22*a31)
        // Scale-aware conditioning test: compare against the magnitude of the diagonal, so this
        // means "the points are spread enough to identify a curve", not "the numbers are big".
        guard abs(det) > 1e-9 * Swift.max(a11 * a22 * a33, 1e-9) else { return false }

        let d0 = b1 * (a22*a33 - a23*a32)
               - a12 * (b2*a33 - a23*b3)
               + a13 * (b2*a32 - a22*b3)
        let d1 = a11 * (b2*a33 - a23*b3)
               - b1 * (a21*a33 - a23*a31)
               + a13 * (a21*b3 - b2*a31)
        let d2 = a11 * (a22*b3 - b2*a32)
               - a12 * (a21*b3 - b2*a31)
               + b1 * (a21*a32 - a22*a31)

        let c0 = d0 / det, c1 = d1 / det, c2 = d2 / det
        // Must be INCREASING across the whole observed range — a fit that turns over would
        // report falling speed as vibration rises — and must not claim meaningful speed at the
        // quietest thing it ever saw.
        guard c1 + 2 * c2 * minSeenU > 0, c1 + 2 * c2 * maxSeenU > 0 else { return false }
        guard c0 + c1 * minSeenU + c2 * minSeenU * minSeenU < 8.0 else { return false }
        p0 = c0; p1 = c1; p2 = c2
        return true
    }

    /// speed = p0 + p1·u, by the 2x2 normal equations. The provisional model.
    private func solveLinear() -> Bool {
        let det = n * sumU2 - sumU * sumU
        guard abs(det) > 1e-9 * Swift.max(n * sumU2, 1e-9) else { return false }
        let c0 = (sumS * sumU2 - sumUS * sumU) / det
        let c1 = (n * sumUS - sumU * sumS) / det
        guard c1 > 0 else { return false }
        guard c0 + c1 * minSeenU < 8.0 else { return false }
        p0 = c0; p1 = c1; p2 = 0
        return true
    }

    /// Speed from vibration alone, or nil while uncalibrated. No integration, so no drift.
    func estimatedSpeed() -> Double? {
        guard let p0 else { return nil }
        let u = vibrationEnergy * SCALE
        if u <= maxSeenU || maxSeenU <= 0 {
            return Swift.max(0, p0 + p1 * u + p2 * u * u)
        }
        // ABOVE the calibrated range, continue along the TANGENT at the top of that range rather
        // than letting u² run away. The curve is only evidence about speeds actually observed,
        // and this mode exists to be used beyond where GPS could calibrate it (an aircraft
        // cruises far above anything a ground calibration ever saw). A straight continuation is
        // the conservative reading of the same evidence.
        let top = p0 + p1 * maxSeenU + p2 * maxSeenU * maxSeenU
        let tangent = Swift.max(p1 * 0.25, p1 + 2 * p2 * maxSeenU)
        return Swift.max(0, top + tangent * (u - maxSeenU))
    }
}
