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

    // Online least-squares fit  speed ≈ slope · vibration + intercept ----------------------
    private var n = 0.0, sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0
    private var minSeenSpeed = Double.greatestFiniteMagnitude
    private var maxSeenSpeed = -Double.greatestFiniteMagnitude
    private var slope: Double?
    private var intercept: Double?

    /// Enough evidence to trust the fit: a decent sample count across a real speed spread.
    private let MIN_SAMPLES = 60.0
    private let MIN_SPEED_SPREAD = 6.0   // m/s between the slowest and fastest calibration point

    var isCalibrated: Bool { slope != nil }

    func reset() {
        magnitudeMean = 0; vibrationEnergy = 0; initialised = false
        n = 0; sumX = 0; sumY = 0; sumXX = 0; sumXY = 0
        minSeenSpeed = .greatestFiniteMagnitude; maxSeenSpeed = -.greatestFiniteMagnitude
        slope = nil; intercept = nil
    }

    /// Feed one raw device-frame acceleration sample (m/s², gravity already removed).
    func ingest(ax: Double, ay: Double, az: Double, dt: TimeInterval) {
        guard dt > 0 else { return }
        let magnitude = sqrt(ax*ax + ay*ay + az*az)
        if !initialised { magnitudeMean = magnitude; initialised = true }
        // Slow mean tracks the DC part; what is left is the vibration.
        magnitudeMean += (magnitude - magnitudeMean) * min(dt / (2.0 + dt), 1.0)
        let deviation = abs(magnitude - magnitudeMean)
        // ~1 s smoothing gives a stable energy estimate without lagging speed changes badly.
        vibrationEnergy += (deviation - vibrationEnergy) * min(dt / (1.0 + dt), 1.0)
    }

    /// Teach the model with a trustworthy GPS speed sample.
    func calibrate(withGPSSpeed speed: Double) {
        // Below walking pace vibration carries no usable signal, and a stopped-but-idling engine
        // would otherwise anchor the line at the wrong place.
        guard speed > 2.0, vibrationEnergy > 0.0001 else { return }
        let x = vibrationEnergy, y = speed
        n += 1; sumX += x; sumY += y; sumXX += x*x; sumXY += x*y
        minSeenSpeed = Swift.min(minSeenSpeed, speed)
        maxSeenSpeed = Swift.max(maxSeenSpeed, speed)
        guard n >= MIN_SAMPLES, (maxSeenSpeed - minSeenSpeed) >= MIN_SPEED_SPREAD else { return }
        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > 1e-9 else { return }
        let m = (n * sumXY - sumX * sumY) / denominator
        // Vibration must INCREASE with speed; a non-positive slope means the fit is meaningless
        // (phone loose on a seat, stationary idling) and is rejected rather than used.
        guard m > 0 else { return }
        slope = m
        intercept = (sumY - m * sumX) / n
    }

    /// Speed from vibration alone, or nil while uncalibrated. No integration, so no drift.
    func estimatedSpeed() -> Double? {
        guard let slope, let intercept else { return nil }
        return Swift.max(0, slope * vibrationEnergy + intercept)
    }
}
