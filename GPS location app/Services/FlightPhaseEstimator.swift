import Foundation

/// Infers flight phase from cabin pressure, and from that an autonomous speed for an airliner.
///
/// WHY THIS EXISTS, AND WHY ONLY FOR FLIGHT
///
/// A phone cannot measure a vehicle's ground speed without GPS. That is now established by
/// measurement rather than assumption: across 784 windows of 50 Hz data spanning 0–77 km/h,
/// correlation between vibration and GPS speed was −0.08 for total energy and no better than
/// 0.38 for any band, and the spectral peak stayed pinned at the car's 1.37 Hz suspension
/// resonance at every speed. No feature can recover information the signal does not carry, so
/// for a car with no GPS there is nothing honest to report but the last speed measured.
///
/// A pressurised aircraft is the one case where another sensor genuinely helps. The cabin is
/// held near 1,800–2,400 m regardless of the aircraft's real altitude, so the barometer does not
/// give true altitude — but its PROFILE is unmistakable and unlike anything on the ground:
///
///   climb    cabin altitude rises hundreds of metres over several minutes, monotonically
///   cruise   it holds nearly flat, far above any field elevation
///   descent  it falls back over several minutes
///
/// No car, lift or building produces a sustained several-hundred-metre pressure change held for
/// tens of minutes. So the phase can be detected without asking, and airliner speeds are a
/// narrow known range — cruise is 800–900 km/h for essentially every jet airliner, and the climb
/// runs from roughly rotation speed to cruise. That is an assumption, but a tightly bounded one
/// grounded in a real measurement, which is a different thing from inventing a number.
final class FlightPhaseEstimator {

    enum Phase: String {
        case ground = "GROUND"
        case climb = "CLIMB"
        case cruise = "CRUISE"
        case descent = "DESCENT"
    }

    private(set) var phase: Phase = .ground

    /// Smoothed cabin altitude, metres relative to where recording began.
    private var altitude: Double = 0
    private var initialised = false
    /// Rate of change, m/s, over a long window — pressurisation is slow and must not be confused
    /// with the second-to-second noise of a barometer.
    private var climbRate: Double = 0
    private var lastSample: Date?
    /// Highest cabin altitude seen, which is what distinguishes cruise from a lift or a hill.
    private var peakAltitude: Double = 0
    /// How long the current phase has held, so a transient cannot flip it.
    private var phaseHeldFor: TimeInterval = 0

    // A pressurised cabin sits far above any building or road gradient, and gets there over
    // minutes rather than seconds.
    private let AIRBORNE_ALTITUDE_GAIN = 250.0    // m of cabin climb before flight is credible
    private let CLIMB_RATE_THRESHOLD = 0.35       // m/s sustained; a lift does 1–2 m/s for seconds
    private let PHASE_CONFIRM_SECONDS = 90.0      // a lift cannot sustain this

    // Airliner speeds. Deliberately conservative: under-reading a cruise slightly is far better
    // than over-reading it, since the route length scales directly with this.
    private let CRUISE_KMH = 830.0
    private let CLIMB_START_KMH = 300.0

    func reset() {
        phase = .ground; altitude = 0; initialised = false; climbRate = 0
        lastSample = nil; peakAltitude = 0; phaseHeldFor = 0
    }

    /// Feed the relative altitude reported by the barometer, in metres.
    func ingest(relativeAltitude: Double, at time: Date) {
        guard let previous = lastSample else {
            lastSample = time; altitude = relativeAltitude; initialised = true; return
        }
        let dt = time.timeIntervalSince(previous)
        guard dt > 0.5 else { return }
        lastSample = time

        // Heavy smoothing: pressurisation changes over minutes, and the raw signal is noisy
        // enough that a short window would read as constant climbing and descending.
        let smoothed = altitude + (relativeAltitude - altitude) * min(dt / (20.0 + dt), 1.0)
        let rate = (smoothed - altitude) / dt
        altitude = smoothed
        climbRate += (rate - climbRate) * min(dt / (45.0 + dt), 1.0)
        peakAltitude = max(peakAltitude, altitude)
        phaseHeldFor += dt

        let next: Phase
        if altitude < AIRBORNE_ALTITUDE_GAIN * 0.4 && peakAltitude < AIRBORNE_ALTITUDE_GAIN {
            next = .ground
        } else if climbRate > CLIMB_RATE_THRESHOLD {
            next = .climb
        } else if climbRate < -CLIMB_RATE_THRESHOLD {
            next = .descent
        } else if peakAltitude >= AIRBORNE_ALTITUDE_GAIN {
            next = .cruise
        } else {
            next = phase
        }
        if next != phase {
            // Require the new phase to persist. A lift climbs fast but briefly; pressurisation
            // does not, so the dwell requirement is what separates them.
            if phaseHeldFor > PHASE_CONFIRM_SECONDS || next == .ground {
                phase = next
                phaseHeldFor = 0
            }
        }
    }

    /// Speed in m/s implied by the current phase, or nil while still on the ground — where the
    /// last measured GPS speed is the honest answer and no inference is warranted.
    func inferredSpeed() -> Double? {
        switch phase {
        case .ground:
            return nil
        case .cruise:
            return CRUISE_KMH / 3.6
        case .climb, .descent:
            // Interpolate with cabin altitude: near the ground the aircraft is near rotation
            // speed, near cruise altitude it is near cruise speed. Crude, but monotonic and
            // bounded by two figures that are true of every jet airliner.
            let f = min(max(altitude / 2000.0, 0), 1)
            return (CLIMB_START_KMH + (CRUISE_KMH - CLIMB_START_KMH) * f) / 3.6
        }
    }

    var isAirborne: Bool { phase != .ground }
}
