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
    /// The cabin altitude counted as the ground: where recording began, and after a landing, the
    /// airport just landed at, so a second flight in the same recording is found the same way.
    private var groundLevel: Double = 0

    /// THE DESCENT, AS TIMING ONLY (build 112). When the cabin had fallen DESCENT_DROP below its
    /// highest level while descending; nil before. On BR215 (Taoyuan-Singapore, ADS-B) the phase
    /// alone said DESCENT at 10:50, when the aircraft stepped down from 34,000 to 32,000 ft and the
    /// cabin fell 229 m, and then flickered between DESCENT and CRUISE through the real descent.
    /// The drop separates the two: this latched at 13:56:34-13:56:36 on all three devices, and
    /// the aircraft left its cruise level at about 13:56. It is never read as an altitude.
    private(set) var descentStartedAt: Date?
    /// When the cabin came back to the ground after a descent: the landing. On BR215 14:24:13-14
    /// on the two devices that recorded it, against 14:24:10 on ADS-B.
    private(set) var landedAt: Date?
    private var notFallingFor: TimeInterval = 0
    /// When the cabin last left the ground; nil on the ground.
    private(set) var airborneAt: Date?
    /// THE CABIN CONFIRMS A FLIGHT (build 113): it climbed CLIMB_CONFIRM above the ground within
    /// CLIMB_CONFIRM_WITHIN of leaving it. For a phone that never felt the takeoff roll (it was not
    /// still before it) and a watch with no iPhone. On BR215 2.9 minutes after the cabin left the
    /// ground on all three devices; on none of the 26 ground recordings with a barometer (the
    /// highest went 98 m).
    private(set) var climbConfirmed = false
    private let CLIMB_CONFIRM = 400.0                       // m
    private let CLIMB_CONFIRM_WITHIN: TimeInterval = 600
    private let DESCENT_DROP = 300.0              // m below the cabin's highest level
    private let LANDED_FRACTION = 0.1             // of that highest level, above the ground
    private let LANDED_SETTLE: TimeInterval = 60  // the cabin has stopped falling this long

    // A pressurised cabin sits far above any building or road gradient, and gets there over
    // minutes rather than seconds.
    /// Cabin climb before flight is credible. Lowered from 250 m after a real flight: the phase
    /// did not latch until four and a half minutes after rotation, and for that whole stretch a
    /// ground-trained speed model was answering — producing 18 to 791 km/h against a true 300 to
    /// 500, and being zeroed twice at over 400. Pressurisation lags the aircraft, so waiting for
    /// a quarter kilometre of cabin gain wastes the climb, which is exactly when the speed
    /// estimate is being established. The 90-second dwell below is what excludes a lift; this
    /// threshold need only exclude a building.
    private let AIRBORNE_ALTITUDE_GAIN = 120.0    // m of cabin climb before flight is credible
    private let CLIMB_RATE_THRESHOLD = 0.35       // m/s sustained; a lift does 1–2 m/s for seconds
    private let PHASE_CONFIRM_SECONDS = 90.0      // a lift cannot sustain this

    // NO SPEED CONSTANTS HERE, DELIBERATELY.
    //
    // An earlier version asserted 830 km/h for cruise and interpolated the climb against cabin
    // altitude. Both were wrong. The interpolation was meaningless: the barometer reads CABIN
    // altitude, held near 1,800–2,400 m by pressurisation regardless of the aircraft's real
    // height, so dividing it by an assumed ceiling does not track anything. And the constant was
    // exactly the mistake that sank five vibration features — a number asserted rather than
    // measured. An aircraft that cruises slower or faster than the guess would have had its
    // whole route scaled wrong, silently and confidently.
    //
    // Cabin pressure can say WHETHER the aircraft is flying, which is a real measurement of a
    // real signal. It cannot say how fast. Speed comes from GPS whenever GPS supplies it, and is
    // held between fixes; this class no longer produces a speed at all.

    func reset() {
        phase = .ground; altitude = 0; initialised = false; climbRate = 0
        lastSample = nil; peakAltitude = 0; phaseHeldFor = 0
        groundLevel = 0; descentStartedAt = nil; landedAt = nil; notFallingFor = 0
        airborneAt = nil; climbConfirmed = false
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
        let height = altitude - groundLevel
        peakAltitude = max(peakAltitude, height)
        phaseHeldFor += dt

        let next: Phase
        if height < AIRBORNE_ALTITUDE_GAIN * 0.4 && peakAltitude < AIRBORNE_ALTITUDE_GAIN {
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
        guard phase != .ground else { airborneAt = nil; climbConfirmed = false; return }
        let since = airborneAt ?? time
        airborneAt = since
        if !climbConfirmed, height >= CLIMB_CONFIRM, time.timeIntervalSince(since) <= CLIMB_CONFIRM_WITHIN {
            climbConfirmed = true
        }
        if descentStartedAt == nil, phase == .descent, peakAltitude - height >= DESCENT_DROP {
            descentStartedAt = time
        }
        // LANDED. Once the plane has started down, the cabin coming back to within a tenth of its
        // highest level and no longer falling is the landing. Without this the phase never left the
        // air again - the ground test above needs a peak under 120 m - so a recording that went on
        // after landing kept flying.
        if descentStartedAt != nil {
            notFallingFor = climbRate < -CLIMB_RATE_THRESHOLD ? 0 : notFallingFor + dt
            if height <= peakAltitude * LANDED_FRACTION, notFallingFor >= LANDED_SETTLE {
                phase = .ground; phaseHeldFor = 0
                groundLevel = altitude; peakAltitude = 0
                descentStartedAt = nil; notFallingFor = 0; landedAt = time
                airborneAt = nil; climbConfirmed = false
            }
        }
    }

    /// Whether the pressure profile says this is a flight. Used as CONTEXT — it makes holding a
    /// GPS-measured speed appropriate, and labels the status line — never to invent a speed.
    var isAirborne: Bool { phase != .ground }
}
