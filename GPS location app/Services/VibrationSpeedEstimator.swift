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
    private var sumXY = 0.0          // Σ (vib − restBaseline) · speed
    private var sumXX = 0.0          // Σ (vib − restBaseline)²
    private var n = 0.0
    private var minSeenSpeed = Double.greatestFiniteMagnitude
    private var maxSeenSpeed = -Double.greatestFiniteMagnitude
    private var slope: Double?
    /// Vibration while genuinely stationary. Until this is known the model cannot be anchored,
    /// so no estimate is offered — better than guessing an offset.
    private var restBaseline: Double?

    /// Enough evidence to trust the fit: a decent sample count across a real speed spread.
    private let MIN_SAMPLES = 60.0
    private let MIN_SPEED_SPREAD = 6.0   // m/s between the slowest and fastest calibration point

    var isCalibrated: Bool { slope != nil }

    func reset() {
        magnitudeMean = 0; vibrationEnergy = 0; initialised = false
        n = 0; sumXX = 0; sumXY = 0
        minSeenSpeed = .greatestFiniteMagnitude; maxSeenSpeed = -.greatestFiniteMagnitude
        slope = nil; restBaseline = nil
    }

    /// Record the vibration floor while the device is genuinely stationary. This anchors the
    /// fit at zero speed, which is what keeps a stopped vehicle reading zero.
    func observeAtRest() {
        guard initialised else { return }
        if let existing = restBaseline {
            // Track the floor gently, and prefer the LOWEST credible value seen: a stationary
            // reading contaminated by handling would otherwise raise the anchor and re-introduce
            // the offset this exists to remove.
            restBaseline = Swift.min(existing * 0.9 + vibrationEnergy * 0.1, existing)
        } else {
            restBaseline = vibrationEnergy
        }
    }

    /// Feed one raw device-frame acceleration sample (m/s², gravity already removed).
    func ingest(ax: Double, ay: Double, az: Double, dt: TimeInterval) {
        guard dt > 0 else { return }
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
        // Below walking pace vibration carries no usable signal, and a stopped-but-idling engine
        // would otherwise anchor the line at the wrong place.
        guard speed > 2.0, vibrationEnergy > 0.0001 else { return }
        // The anchor must exist first; without it there is no way to separate slope from offset.
        guard let baseline = restBaseline else { return }
        let x = vibrationEnergy - baseline
        // Only vibration ABOVE the resting floor carries speed information.
        guard x > 0 else { return }
        n += 1; sumXY += x * speed; sumXX += x * x
        minSeenSpeed = Swift.min(minSeenSpeed, speed)
        maxSeenSpeed = Swift.max(maxSeenSpeed, speed)
        guard n >= MIN_SAMPLES, (maxSeenSpeed - minSeenSpeed) >= MIN_SPEED_SPREAD else { return }
        guard sumXX > 1e-12 else { return }
        // Slope through the origin: minimises Σ(speed − m·x)², giving m = Σxy / Σx².
        let m = sumXY / sumXX
        // Vibration must INCREASE with speed; a non-positive slope means the fit is meaningless
        // (phone loose on a seat, stationary idling) and is rejected rather than used.
        guard m > 0 else { return }
        slope = m
    }

    /// Speed from vibration alone, or nil while uncalibrated. No integration, so no drift.
    func estimatedSpeed() -> Double? {
        guard let slope, let baseline = restBaseline else { return nil }
        // Anchored at rest: vibration at the resting floor maps to exactly zero speed.
        return Swift.max(0, slope * (vibrationEnergy - baseline))
    }
}
