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
    // Low-frequency part of each AXIS (DC bias + driving dynamics). Held per-axis, because the
    // high-pass has to happen BEFORE the magnitude is taken — see ingest().
    private var lowFreqX: Double = 0
    private var lowFreqY: Double = 0
    private var lowFreqZ: Double = 0
    // SECOND stage of the high-pass. One pole is not enough: it attenuates only in proportion
    // to f/fc, so 0.25 Hz braking against a 3.2 Hz corner still passes ~8% of its amplitude —
    // and braking is an order of magnitude larger than road vibration, so that residue was
    // comparable to the entire signal being measured (0.094 leaked against 0.141 of real
    // vibration). Two poles attenuate as (f/fc)², cutting the same leak to 0.007 while leaving
    // 14 Hz tyre noise essentially untouched.
    private var lowFreq2X: Double = 0
    private var lowFreq2Y: Double = 0
    private var lowFreq2Z: Double = 0
    private var vibrationEnergy: Double = 0        // the feature: dominant vibration FREQUENCY, Hz
    /// Previous high-passed vertical sample, for the derivative.
    private var prevHighPassed: Double = 0
    /// Smoothed |x| and |dx/dt| of the high-passed vertical signal. Their ratio is a frequency
    /// and, crucially, is INDEPENDENT OF AMPLITUDE — it cancels in the division.
    private var ampEMA: Double = 0
    private var derivEMA: Double = 0
    /// Below this the high-passed signal is sensor noise rather than road vibration, and a
    /// frequency computed from noise is meaningless (it tends toward Nyquist, which would read
    /// as enormous speed while parked). Treated as zero instead.
    /// Set low on purpose. This is the one constant here chosen by reasoning rather than
    /// measurement, and at 0.02 it was high enough to silence a quiet car: the feature read zero
    /// while moving, which reported zero speed and — because a zero sample was also being
    /// discarded by the fit — prevented calibration from ever starting. 0.003 is close to the
    /// accelerometer's own noise after a two-pole high-pass, so it still catches a parked car
    /// without swallowing a smooth-riding one.
    private let VIBRATION_NOISE_FLOOR = 0.003
    private var initialised = false
    /// High-pass corner. An EMA tracks everything below 1/(2πτ) ≈ 3.2 Hz, so subtracting it
    /// leaves only what is above that. See ingest() for why this matters so much.
    private let LOWFREQ_TAU = 0.05
    /// Seconds of data ingested this workout. The feature is an EMA seeded at zero, so early
    /// readings are a startup transient rather than a measurement.
    private var ingestElapsed: TimeInterval = 0
    private let FEATURE_WARMUP_SECONDS = 5.0

    /// The feature is O(0.1). Raising it to O(1) before forming the regression's power sums
    /// keeps Σu⁴ from underflowing into the noise and makes the conditioning test meaningful.
    private let SCALE = 1.0   // the feature is now a frequency in Hz, already O(1–20)

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
    // Lowered from 60 samples / 6 m/s. A real drive showed why: the model stayed on the
    // PROVISIONAL fit for the whole trip, and that fit is deliberately linear. Minute-by-minute
    // the reported speed then sat pinned at 44–58 km/h from minute 4 to minute 15 while the car
    // was doing 100–110, whereas the slow early minutes varied freely (14–45). Compressing
    // everything above ~50 into ~50 is precisely what a straight line does to a saturating
    // feature once it is used past the range it was taught. Two parameters are what represent
    // that curve, so the bar to earn them must be reachable within one ordinary drive.
    private let MIN_SAMPLES = 30.0
    private let MIN_SPEED_SPREAD = 4.0   // m/s between the slowest and fastest calibration point
    // PROVISIONAL fit, used only until the full bar is met, and deliberately LINEAR: a dozen
    // samples over a narrow range cannot condition a curve, and an ill-fitted quadratic can bend
    // the wrong way entirely. A rough line is not accurate, but it is bounded and monotonic in
    // speed — whereas the alternative while waiting is raw double-integration, which is
    // unbounded and was observed reporting 252 km/h and fabricating 7.6 km of route in 8
    // minutes. Wrong by 30% beats wrong by an order of magnitude.
    private let PROVISIONAL_SAMPLES = 12.0
    private let PROVISIONAL_SPEED_SPREAD = 2.5

    /// Everything needed to explain a reported speed after the fact. Offline simulation has
    /// repeatedly failed to reproduce the speeds seen in the field, so the model's own inputs
    /// and coefficients are recorded per tick and exported rather than inferred.
    struct Diagnostics {
        let feature: Double          // u, the scaled vibration energy driving the estimate
        let p0: Double, p1: Double, p2: Double
        let minCalibratedU: Double, maxCalibratedU: Double
        let minCalibratedSpeed: Double, maxCalibratedSpeed: Double
        let samples: Double, zeroSamples: Double
        let isExtrapolating: Bool    // reading above anything GPS ever labelled
    }

    var diagnostics: Diagnostics {
        let u = vibrationEnergy * SCALE
        return Diagnostics(
            feature: u,
            p0: p0 ?? .nan, p1: p1, p2: p2,
            minCalibratedU: minSeenU == .greatestFiniteMagnitude ? .nan : minSeenU,
            maxCalibratedU: maxSeenU <= 0 ? .nan : maxSeenU,
            minCalibratedSpeed: minSeenSpeed == .greatestFiniteMagnitude ? .nan : minSeenSpeed,
            maxCalibratedSpeed: maxSeenSpeed < 0 ? .nan : maxSeenSpeed,
            samples: n, zeroSamples: nZeroish,
            isExtrapolating: maxSeenU > 0 && u > maxSeenU
        )
    }

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
    private static let keyP0 = "VibrationSpeedEstimator.p0.v9"
    private static let keyP1 = "VibrationSpeedEstimator.p1.v9"
    private static let keyP2 = "VibrationSpeedEstimator.p2.v9"
    private static let keyMaxU = "VibrationSpeedEstimator.maxU.v9"
    private static let allKeys = [keyP0, keyP1, keyP2, keyMaxU]

    /// Start a workout: clear the per-trip signal state but KEEP a previously learned model.
    func reset() {
        lowFreqX = 0; lowFreqY = 0; lowFreqZ = 0; lowFreq2X = 0; lowFreq2Y = 0; lowFreq2Z = 0; vibrationEnergy = 0; prevHighPassed = 0; ampEMA = 0; derivEMA = 0; initialised = false; ingestElapsed = 0
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
        if !initialised { lowFreqX = ax; lowFreqY = ay; lowFreqZ = az; lowFreq2X = 0; lowFreq2Y = 0; lowFreq2Z = 0; initialised = true }

        // HIGH-PASS, and this is the whole ballgame.
        //
        // This used to subtract a 30-SECOND mean, which passes everything above ~0.005 Hz —
        // and that includes accelerating, braking and cornering, at 0.1–1 Hz and 0.5–3 m/s².
        // Genuine road and engine vibration is 10–50 Hz at 0.05–0.5 m/s², an order of magnitude
        // SMALLER. So the "vibration" feature was really measuring how the car was being
        // DRIVEN, not how fast it was going. Measured on a realistic synthetic signal:
        //
        //                       smooth        heavy traffic
        //     29 km/h            0.0954          0.3956      <- 4.1x from driving style alone
        //    101 km/h            0.1473          0.3998
        //                        ^^^^^^ only 1.5x from a 3.5x speed change
        //
        // In traffic it was effectively BLIND to speed: 0.3956 at 29 km/h against 0.3998 at
        // 101 km/h, a 1% difference across the entire range. Calibrate in city traffic, then
        // drive a smooth road, and the feature collapses — which is precisely the long-running
        // complaint that a real 40 km/h reads 11, a real 100 reads 37, while stop-and-go at
        // 20–30 once read 261.
        //
        // A 3.2 Hz corner separates the two cleanly: driving dynamics sit an order of magnitude
        // below it, tyre and engine vibration an order of magnitude above. After this the same
        // test gives 2.0x across the speed range and only 1.2x from driving style — speed is
        // now the dominant term rather than the minor one.
        // PER-AXIS, before any magnitude is taken. ‖a‖ is a rectification, so a large
        // low-frequency swing (hard braking) folds into broadband content that no high-pass
        // applied AFTER the norm can remove — filtering the magnitude still left a 21 km/h
        // under-read when the fit was calibrated in traffic and then used on a smooth road.
        let alpha = min(dt / (LOWFREQ_TAU + dt), 1.0)
        lowFreqX += (ax - lowFreqX) * alpha
        lowFreqY += (ay - lowFreqY) * alpha
        lowFreqZ += (az - lowFreqZ) * alpha
        let h1x = ax - lowFreqX, h1y = ay - lowFreqY, h1z = az - lowFreqZ
        // Second pole, applied to the output of the first.
        lowFreq2X += (h1x - lowFreq2X) * alpha
        lowFreq2Y += (h1y - lowFreq2Y) * alpha
        lowFreq2Z += (h1z - lowFreq2Z) * alpha
        let hz = h1z - lowFreq2Z

        // VERTICAL ONLY — not the three-axis magnitude.
        //
        // The inputs are WORLD-frame (north, east, up), and the device→world rotation is
        // orthonormal, so ‖a‖ is mathematically invariant to how the phone is pointed. In
        // practice the reading still depended on orientation, and the reason is gravity.
        //
        // Core Motion removes gravity using its attitude estimate. Vibration shakes the phone
        // ANGULARLY as well as linearly, so that estimate jitters, and a tilt error of δθ spills
        // 9.81·sin(δθ) of gravity into the HORIZONTAL axes — just 0.01 rad gives 0.098 m/s²,
        // comparable to the entire road-vibration signal being measured. That error is
        // first-order in δθ and depends on how the phone is seated, so the horizontal components
        // carry an orientation-dependent artefact that has nothing to do with speed.
        //
        // The vertical axis is second-order insensitive to the same jitter (cos δθ ≈ 1 − δθ²/2),
        // and it is where road vibration mostly lives anyway, since suspension travel is
        // vertical. Using it alone makes the feature indifferent to which way the phone faces,
        // which is exactly the reported failure.
        // FREQUENCY, NOT AMPLITUDE. This is the substantive change.
        //
        // Amplitude was measured and found not to carry the speed. On a real drive the model was
        // fully calibrated — 342 samples, a quadratic fit, GPS-labelled up to 116 km/h, and not
        // extrapolating — and still reported 35 km/h at a true 100. A well-conditioned fit
        // cannot be wrong by 3x INSIDE its own range unless the input does not determine the
        // output. The exported data agreed: acceleration magnitude averaged 0.5–1.5 m/s² at a
        // reported 17–28 km/h and 1.0–1.4 at a reported 36–44, i.e. flat. Vibration amplitude is
        // set by how rough the road is, and road roughness varies more than speed does.
        //
        // Frequency does not have that problem. Tyre and suspension excitation is driven by
        // wheel rotation, f = v / 2πr, so a 0.32 m wheel gives ~4.8 Hz at 35 km/h and ~13.8 Hz
        // at 100 km/h — proportional to speed by construction, well inside the 50 Hz sampling,
        // and indifferent to how hard the road is shaking the phone.
        //
        // Estimated without an FFT: for a narrowband signal, E|ẋ| / E|x| ≈ 2πf. Amplitude
        // appears in both terms and cancels, which is exactly the property amplitude-based
        // sensing lacked.
        let derivative = (hz - prevHighPassed) / dt
        prevHighPassed = hz
        let smooth = min(dt / (0.5 + dt), 1.0)
        ampEMA += (abs(hz) - ampEMA) * smooth
        derivEMA += (abs(derivative) - derivEMA) * smooth
        // Below the noise floor there is no vibration to measure a frequency of, and noise would
        // read near Nyquist — a parked car reporting a huge speed. Report zero and let the fit's
        // intercept handle rest.
        let highPassed = ampEMA > VIBRATION_NOISE_FLOOR
            ? derivEMA / (2 * Double.pi * ampEMA)
            : 0.0
        // Long enough to average the vibration waveform itself (many cycles at 10+ Hz), short
        // enough to still track a real change of speed promptly.
        vibrationEnergy += (highPassed - vibrationEnergy) * min(dt / (0.5 + dt), 1.0)
    }

    /// Teach the model with a trustworthy GPS speed sample. `horizontalAccuracy` in metres;
    /// pass a very large number if unknown (rejected below rather than trusted by default).
    func calibrate(withGPSSpeed speed: Double, horizontalAccuracy: Double) {
        // A poor fix's speed field is frequently a multipath/urban-canyon spike unrelated to
        // real motion. Feeding that in poisoned the fit: a walk produced spurious ~20 km/h
        // "calibration" points that were pure GPS noise, yielding a model that reported
        // vibration-derived speed while the phone sat still.
        // Raised from 20 m. The point of this gate is to keep multipath spikes out of the fit,
        // and 20 m was strict enough to discard most of a real drive: ordinary motorway GPS runs
        // 5–15 m but drifts past 20 through interchanges, cuttings and under gantries — exactly
        // the fast stretches whose absence left the model taught only at city speeds and forced
        // to extrapolate everywhere else. 35 m still excludes the urban-canyon garbage.
        guard horizontalAccuracy >= 0, horizontalAccuracy < 35.0 else { return }
        guard speed >= 0 else { return }
        addSample(speed: speed)
    }

    private func addSample(speed: Double) {
        // Before warm-up the feature is still climbing out of its zero seed, so it describes the
        // filter's initial condition rather than the ride.
        // A ZERO FEATURE IS A VALID OBSERVATION, and rejecting it deadlocked the model.
        //
        // The feature used to be an amplitude, where zero meant "nothing measured yet", so a
        // zero was worth discarding. It is now a frequency, and zero is what the noise floor
        // deliberately reports when the vehicle is at rest — exactly the samples that pin the
        // intercept. Worse, if the floor was ever too high for a quiet car the feature read zero
        // WHILE MOVING, every sample was then thrown away here, calibration could never begin,
        // and with raw integration gone the speed stayed at zero for the whole trip with no way
        // out. Let the value through and let the fit judge it.
        guard initialised, ingestElapsed >= FEATURE_WARMUP_SECONDS else { return }

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
