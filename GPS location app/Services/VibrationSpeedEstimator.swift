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
///
/// Deliberately simple and inspectable: vibration energy versus speed is monotonic and close to
/// linear over normal road speeds, so a least-squares line is fitted rather than a black box.
/// The estimate is only offered once the fit is backed by enough samples spanning a real speed
/// range, so it never guesses from a single operating point.
final class VibrationSpeedEstimator {

    // Rolling vibration feature -----------------------------------------------------------
    private var magnitudeMean: Double = 0          // slow mean of |a|, removes the DC part
    private var vibrationEnergy: Double = 0        // smoothed |‖a‖ − mean|, the feature
    private var initialised = false

    // Fit FORCED THROUGH A MEASURED AT-REST BASELINE ------------------------------------
    //
    // A free intercept is fatal here. Vibration depends heavily on ROAD SURFACE, a large
    // component uncorrelated with speed, and calibration usually spans a narrow range (city
    // driving). Least squares then absorbs that noise into the intercept: the slope goes
    // shallow and the offset large, so the model reads ~23 km/h while STOPPED and badly
    // under-reads at speed — measured 22.9 km/h at rest and 52 km/h when actually doing 100.
    // That is exactly the reported "30 when it's 0, and 30 when it's 100".
    //
    // Physically, zero speed must mean zero speed, so the line is anchored: the vibration seen
    // while genuinely stationary (engine idle) maps to 0, and only the SLOPE is fitted, through
    // that origin. Both ends then come out right (0.0 at rest, 92 km/h at an actual 100).
    //
    // A STRAIGHT line is not enough. Measured steady-state feature against speed:
    //     0 km/h 0.037 | 18 0.103 | 36 0.157 | 54 0.196 | 72 0.225 | 90 0.247
    // The increments shrink at every step (+0.065, +0.054, +0.039, +0.029, +0.023): the
    // response SATURATES, because the feature is a rectified norm and its deviation grows
    // sub-linearly once the oscillation exceeds the DC level. Fitting one global slope to a
    // concave curve necessarily over-reads at the bottom and under-reads at the top — a line
    // through the measured extremes reads 6.9 where the truth is 5, and 22 where it is 25.
    // Scaled up, that IS the long-standing "37 km/h when the car is doing 100".
    //
    // So fit a QUADRATIC through the origin, speed = a·x + b·x², still least squares and still
    // closed-form (a 2x2 normal-equation solve), still anchored so that resting vibration maps
    // to exactly zero. Two parameters are enough to bend with the saturation while staying
    // inspectable — CarSpeedNet needs a neural network only because it must generalise across
    // vehicles offline, whereas this is fitted per vehicle and per placement online.
    private var sumXY = 0.0          // Σ x·v      (x = vib − restBaseline, v = GPS speed)
    private var sumXX = 0.0          // Σ x²
    private var sumXXX = 0.0         // Σ x³
    private var sumXXXX = 0.0        // Σ x⁴
    private var sumXXY = 0.0         // Σ x²·v
    private var maxSeenX = 0.0       // largest calibrated x, beyond which we extrapolate
    private var n = 0.0
    private var minSeenSpeed = Double.greatestFiniteMagnitude
    private var maxSeenSpeed = -Double.greatestFiniteMagnitude
    /// Linear coefficient. Always set once calibrated (the provisional fit uses it alone).
    private var slope: Double?
    /// Quadratic coefficient, present only once the full fit is solved and well-conditioned.
    private var curvature: Double?
    /// True once the slope came from a fit meeting the FULL evidence bar, as opposed to the
    /// provisional early fit. Only a full fit is worth persisting for later trips.
    private var slopeIsFullyEvidenced = false
    /// Vibration while genuinely stationary. Until this is known the model cannot be anchored,
    /// so no estimate is offered — better than guessing an offset.
    private var restBaseline: Double?

    /// Enough evidence to trust the fit: a decent sample count across a real speed spread.
    private let MIN_SAMPLES = 60.0
    private let MIN_SPEED_SPREAD = 6.0   // m/s between the slowest and fastest calibration point
    // PROVISIONAL fit, used only until the full bar is met. A rough vibration slope is not
    // accurate, but it is bounded and monotonic in speed — whereas the alternative while
    // waiting is raw double-integration, which is unbounded and was observed reporting
    // 252 km/h and fabricating 7.6 km of route in 8 minutes. Wrong by 30% beats wrong by 10x.
    private let PROVISIONAL_SAMPLES = 12.0
    private let PROVISIONAL_SPEED_SPREAD = 2.5

    var isCalibrated: Bool { slope != nil }
    /// Distinguishes the provisional fit from the fully-evidenced one, for the status line.
    var isProvisional: Bool { slope != nil && !slopeIsFullyEvidenced }

    // PERSISTENCE ------------------------------------------------------------------------
    //
    // The model used to be wiped at every workout start, so each drive had to re-earn 60
    // GPS-calibrated samples spanning 6 m/s BEFORE producing anything — and a trip that
    // enables Force Velocity and then loses GPS never gets that chance, which is precisely
    // the case this feature exists for. The vibration-to-speed slope is a property of the
    // VEHICLE AND PHONE PLACEMENT, not of a single workout, so it is carried across trips.
    // Versioned so a fix to WHAT gets learned (e.g. tightening what may calibrate the fit)
    // invalidates whatever an older build already saved, instead of silently loading it back
    // in. v2: calibration used to run any time the pedometer had not counted recently, with no
    // requirement that vehicle motion was actually evidenced — so a walk whose steps hadn't
    // been detected yet fed footstep vibration into what was meant to be a pure-driving fit,
    // and vice versa. One contaminated model then misfired on every later trip in both
    // directions: a real ~100 km/h drive read 37 km/h, and a real walk read 40 km/h.
    // v3: the model shape changed from one slope to a quadratic (plus the calibrated range it
    // is valid over), and v2 baselines are untrustworthy anyway — a startup-transient bug pinned
    // restBaseline at 0, so anything saved by an older build encodes a broken anchor.
    private static let slopeKey = "VibrationSpeedEstimator.slope.v3"
    private static let baselineKey = "VibrationSpeedEstimator.restBaseline.v3"
    private static let curvatureKey = "VibrationSpeedEstimator.curvature.v3"
    private static let maxXKey = "VibrationSpeedEstimator.maxSeenX.v3"

    /// Start a workout: clear the per-trip signal state but KEEP a previously learned model.
    func reset() {
        magnitudeMean = 0; vibrationEnergy = 0; initialised = false
        floorCandidate = nil; ingestElapsed = 0
        n = 0; sumXX = 0; sumXY = 0; sumXXX = 0; sumXXXX = 0; sumXXY = 0; maxSeenX = 0
        minSeenSpeed = .greatestFiniteMagnitude; maxSeenSpeed = -.greatestFiniteMagnitude
        let defaults = UserDefaults.standard
        let savedSlope = defaults.double(forKey: Self.slopeKey)
        let savedBaseline = defaults.double(forKey: Self.baselineKey)
        if savedSlope > 0, defaults.object(forKey: Self.baselineKey) != nil {
            slope = savedSlope
            slopeIsFullyEvidenced = true
            restBaseline = savedBaseline
            // Curvature is optional: a persisted linear-only model stays linear until this
            // trip's own calibration earns the second parameter.
            if defaults.object(forKey: Self.curvatureKey) != nil {
                curvature = defaults.double(forKey: Self.curvatureKey)
                maxSeenX = defaults.double(forKey: Self.maxXKey)
            } else {
                curvature = nil
            }
        } else {
            slope = nil
            curvature = nil
            slopeIsFullyEvidenced = false
            restBaseline = nil
        }
    }

    /// Discard the stored model — for when the phone moves to a different vehicle or mount.
    func forgetLearnedModel() {
        let defaults = UserDefaults.standard
        for key in [Self.slopeKey, Self.baselineKey, Self.curvatureKey, Self.maxXKey] {
            defaults.removeObject(forKey: key)
        }
        slope = nil; curvature = nil; slopeIsFullyEvidenced = false; restBaseline = nil
    }

    private func persistIfFullyEvidenced() {
        guard slopeIsFullyEvidenced, let slope, let restBaseline else { return }
        let defaults = UserDefaults.standard
        defaults.set(slope, forKey: Self.slopeKey)
        defaults.set(restBaseline, forKey: Self.baselineKey)
        if let curvature {
            defaults.set(curvature, forKey: Self.curvatureKey)
            defaults.set(maxSeenX, forKey: Self.maxXKey)
        } else {
            defaults.removeObject(forKey: Self.curvatureKey)
            defaults.removeObject(forKey: Self.maxXKey)
        }
    }

    /// Lowest vibration energy seen so far this trip, used as the anchor when the activity
    /// classifier never gives a confident stationary call.
    private var floorCandidate: Double?
    /// Seconds of vibration data ingested this workout, used to reject the startup transient.
    private var ingestElapsed: TimeInterval = 0
    /// Well past the feature's own 0.5 s smoothing, so the reading is a real measurement.
    private let FLOOR_WARMUP_SECONDS = 5.0

    /// Record the vibration floor while the device is genuinely stationary. This anchors the
    /// fit at zero speed, which is what keeps a stopped vehicle reading zero.
    func observeAtRest() {
        guard floorReadingIsMeaningful else { return }
        adoptFloor(vibrationEnergy, trusted: true)
    }

    /// The vibration feature is an EMA seeded at zero, so for the first moments of a workout it
    /// reads near-zero regardless of what the device is actually doing. That is a startup
    /// transient, not a measurement, and it must never be mistaken for a genuine vibration
    /// floor — see observeFloor() for what happened when it was.
    private var floorReadingIsMeaningful: Bool {
        initialised && ingestElapsed >= FLOOR_WARMUP_SECONDS && vibrationEnergy > 1e-4
    }

    /// Called every sample. Tracks the running minimum of the vibration feature so the anchor
    /// can be established WITHOUT the activity classifier.
    ///
    /// The classifier was a hard dependency: `restBaseline` was set only on a confident
    /// `[still]` call, and a drive that is tagged `[car]` from the first second never got one.
    /// Every `calibrate()` then bailed at the missing-anchor guard, so the fit stayed empty for
    /// the whole trip however good the GPS was. A running minimum needs no classifier: over any
    /// realistic trip the quietest moment IS the slowest moment, so it is a sound floor.
    ///
    /// MUST NOT run before the feature has warmed up. `initialised` flips on the very FIRST
    /// ingest sample, at which point vibrationEnergy is still its seed value of 0 — so the
    /// running minimum immediately adopted 0 and, being a minimum, could never be displaced
    /// again. restBaseline was therefore pinned at 0 for the entire workout (and, worse, that 0
    /// also overwrote the baseline restored from previous trips). With the anchor at zero the
    /// model degenerates from speed = m·(vib − vib_rest) to speed = m·vib, fitted through the
    /// origin on driving data only, which COMPRESSES the range: it under-reads at speed and
    /// over-reads at rest. That is the long-standing "30 km/h whether the true speed is 0 or
    /// 100", and the under-accumulated distance that left a recorded route short of the real one.
    private func observeFloor() {
        guard floorReadingIsMeaningful else { return }
        adoptFloor(vibrationEnergy, trusted: false)
    }

    private func adoptFloor(_ candidate: Double, trusted: Bool) {
        if let existing = floorCandidate {
            // Prefer the LOWEST credible value: a quiet-but-moving reading would otherwise raise
            // the anchor and re-introduce the offset this exists to remove. Let it creep upward
            // only very slowly, so a one-off dropout does not pin the floor forever.
            floorCandidate = Swift.min(existing * 0.99995 + candidate * 0.00005, candidate)
        } else {
            floorCandidate = candidate
        }
        guard let floor = floorCandidate else { return }
        // A persisted baseline is only overridden by a TRUSTED (classifier-confirmed) rest
        // reading, or by a running minimum that is clearly lower than what was stored.
        if trusted || restBaseline == nil || floor < (restBaseline ?? .greatestFiniteMagnitude) {
            restBaseline = floor
        }
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
        observeFloor()
    }

    /// Teach the model with a trustworthy GPS speed sample. `horizontalAccuracy` in metres;
    /// pass a very large number if unknown (rejected below rather than trusted by default).
    func calibrate(withGPSSpeed speed: Double, horizontalAccuracy: Double) {
        // A poor fix's speed field is frequently a multipath/urban-canyon spike unrelated to
        // real motion. Feeding that in poisoned the fit: a walk produced spurious ~20 km/h
        // "calibration" points that were pure GPS noise, yielding a model that reported
        // vibration-derived speed while the phone sat still.
        guard horizontalAccuracy >= 0, horizontalAccuracy < 20.0 else { return }
        // Below walking pace vibration carries no usable signal, and a stopped-but-idling engine
        // would otherwise anchor the line at the wrong place.
        guard speed > 2.0, vibrationEnergy > 0.0001 else { return }
        // The anchor must exist first; without it there is no way to separate slope from offset.
        guard let baseline = restBaseline else { return }
        let x = vibrationEnergy - baseline
        // Only vibration ABOVE the resting floor carries speed information.
        guard x > 0 else { return }
        n += 1
        sumXY += x * speed
        sumXX += x * x
        sumXXX += x * x * x
        sumXXXX += x * x * x * x
        sumXXY += x * x * speed
        maxSeenX = Swift.max(maxSeenX, x)
        minSeenSpeed = Swift.min(minSeenSpeed, speed)
        maxSeenSpeed = Swift.max(maxSeenSpeed, speed)
        let spread = maxSeenSpeed - minSeenSpeed
        let fullyEvidenced = n >= MIN_SAMPLES && spread >= MIN_SPEED_SPREAD
        let provisional = n >= PROVISIONAL_SAMPLES && spread >= PROVISIONAL_SPEED_SPREAD
        guard fullyEvidenced || provisional else { return }
        guard sumXX > 1e-12 else { return }
        // Linear fit through the origin: minimises Σ(speed − m·x)², giving m = Σxy / Σx².
        let m = sumXY / sumXX
        // Vibration must INCREASE with speed; a non-positive slope means the fit is meaningless
        // (phone loose on a seat, stationary idling) and is rejected rather than used.
        guard m > 0 else { return }
        // A this-trip fit always supersedes a persisted one — same vehicle, current placement.
        slope = m
        slopeIsFullyEvidenced = fullyEvidenced

        // QUADRATIC through the origin, once there is enough evidence to support two parameters.
        // Normal equations for minimising Σ(v − a·x − b·x²)²:
        //     a·Σx² + b·Σx³ = Σxv
        //     a·Σx³ + b·Σx⁴ = Σx²v
        // The provisional fit deliberately stays linear: 12 samples over a narrow speed range
        // cannot condition a curve, and an ill-fitted quadratic can bend the wrong way entirely.
        curvature = nil
        if fullyEvidenced {
            let det = sumXX * sumXXXX - sumXXX * sumXXX
            // Poorly conditioned when the calibration points are bunched at one operating point,
            // where a curve is unidentifiable. Keep the honest straight line instead of solving
            // a near-singular system and getting wild coefficients.
            if abs(det) > 1e-18 {
                let a = (sumXY * sumXXXX - sumXXY * sumXXX) / det
                let b = (sumXX * sumXXY - sumXXX * sumXY) / det
                // Must rise from the origin, and must be increasing across the whole calibrated
                // range — a fit that turns over would report FALLING speed as vibration rises.
                if a > 0, a + 2 * b * maxSeenX > 0 {
                    slope = a
                    curvature = b
                }
            }
        }
        persistIfFullyEvidenced()
    }

    /// Speed from vibration alone, or nil while uncalibrated. No integration, so no drift.
    func estimatedSpeed() -> Double? {
        guard let slope, let baseline = restBaseline else { return nil }
        let x = vibrationEnergy - baseline
        guard x > 0 else { return 0 }   // anchored: resting vibration maps to exactly zero
        guard let curvature else { return slope * x }
        // Inside the calibrated range, evaluate the fitted curve.
        if x <= maxSeenX || maxSeenX <= 0 {
            return Swift.max(0, slope * x + curvature * x * x)
        }
        // ABOVE the calibrated range, continue along the TANGENT at the top of that range
        // rather than letting x² run away. The curve is only evidence about speeds that were
        // actually observed; a quadratic extrapolated far past them grows without justification,
        // and this mode exists precisely to be used beyond where GPS could calibrate it (an
        // aircraft cruises far above any speed the ground calibration ever saw). A straight
        // continuation is the conservative reading of the same evidence.
        let top = slope * maxSeenX + curvature * maxSeenX * maxSeenX
        let tangent = Swift.max(slope * 0.25, slope + 2 * curvature * maxSeenX)
        return Swift.max(0, top + tangent * (x - maxSeenX))
    }
}
