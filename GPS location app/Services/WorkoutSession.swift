import Foundation
import HealthKit
import CoreLocation
import CoreMotion
import Combine
import ActivityKit
import UIKit

class WorkoutSession: ObservableObject {
    static let shared = WorkoutSession()

    private struct ActiveWorkoutSnapshot: Codable {
        let flight: Flight
        let currentMetrics: FlightMetrics
        let workoutTypeRawValue: UInt
        let isPaused: Bool
        let totalPausedTime: TimeInterval
        let pauseStartTime: Date?
        let locationsToSkipAfterResume: Int
        let savedAt: Date
    }

    private let healthStore = HKHealthStore()
    private var workoutBuilder: HKWorkoutBuilder?
    private var workoutType: HKWorkoutActivityType = .walking

    @Published var isActive = false
    @Published var isPaused = false
    @Published var flight: Flight
    @Published var currentMetrics = FlightMetrics()

    let locationManager = LocationManager()
    let healthKitManager = HealthKitManager.shared
    private let connectivityManager = WatchConnectivityManager.shared
    private let notificationManager = WorkoutNotificationManager.shared
    private var cancellables = Set<AnyCancellable>()

    // Track pause/resume to prevent GPS drift distance bugs
    private var locationsToSkipAfterResume = 0
    private let LOCATIONS_TO_SKIP_AFTER_RESUME = 3  // Skip 3 locations to let GPS stabilize

    // Pause time tracking
    private var totalPausedTime: TimeInterval = 0
    private var pauseStartTime: Date?

    // Live Activity tracking
    private var lastLiveActivityUpdate: Date?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var didAttemptSnapshotRestore = false
    private var lastSnapshotSaveDate: Date?

    // Thermal management — back off heavy work as the device heats up so iOS
    // doesn't terminate the app for overheating during long workouts.
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    private var thermalObserver: NSObjectProtocol?

    private var isHot: Bool { thermalState == .serious || thermalState == .critical }

    private var LIVE_ACTIVITY_UPDATE_INTERVAL: TimeInterval {
        switch thermalState {
        case .critical: return 10.0
        case .serious: return 5.0
        default: return 2.0
        }
    }
    private var ACTIVE_WORKOUT_AUTOSAVE_INTERVAL: TimeInterval {
        switch thermalState {
        case .critical: return 30.0
        case .serious: return 15.0
        default: return 5.0
        }
    }
    private let ACTIVE_WORKOUT_MAX_RESTORE_AGE: TimeInterval = 24 * 60 * 60
    private let activeWorkoutSnapshotQueue = DispatchQueue(
        label: "com.exmstc.gps.activeWorkoutSnapshot",
        qos: .utility
    )
    private let activeWorkoutSnapshotFileName = "active_workout_snapshot.json"

    private var liveActivitySpeedMps: Double {
        currentMetrics.tenSecondAverageSpeed > 0 ? currentMetrics.tenSecondAverageSpeed : currentMetrics.smoothedSpeed
    }

    private var activeWorkoutSnapshotURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(activeWorkoutSnapshotFileName)
    }

    // Computed property for active duration (excluding paused time)
    var activeDuration: TimeInterval {
        guard isActive else { return 0 }

        let elapsed = Date().timeIntervalSince(flight.startDate)

        // Calculate current pause duration if paused
        let currentPausedTime: TimeInterval
        if isPaused {
            if let pauseStart = pauseStartTime {
                currentPausedTime = Date().timeIntervalSince(pauseStart)
            } else {
                // This shouldn't happen - log error
                print("⚠️ ERROR: isPaused=true but pauseStartTime is nil!")
                currentPausedTime = 0
            }
        } else {
            currentPausedTime = 0
        }

        let active = elapsed - totalPausedTime - currentPausedTime

        return max(0, active) // Ensure never negative
    }

    // GPS accuracy thresholds. Keep iPhone/iPad aligned with the Watch path so
    // fast GPS workouts do not lose most of their distance on the phone.
    private let MAX_HORIZONTAL_ACCURACY: Double = 100.0
    private let MAX_LOCATION_AGE: TimeInterval = 15.0
    private let DEFAULT_MAX_SPEED_MPS: Double = .greatestFiniteMagnitude  // speed limit disabled
    private let DEFAULT_MAX_DISTANCE_JUMP: Double = 150.0
    private let DEFAULT_MAX_ACCELERATION_MPS2: Double = 10.0

    // ABSOLUTE SAFETY LIMITS - applied even in Raw GPS mode to prevent impossible physics
    private let ABSOLUTE_MAX_SPEED_MPS: Double = .greatestFiniteMagnitude  // speed limit disabled
    private let ABSOLUTE_MAX_DISTANCE_JUMP: Double = 2000.0

    // Estimated-location fallback for GPS gaps. These points are explicitly marked
    // as estimated so the app can distinguish them from real Core Location fixes.
    private var estimatedFallbackTimer: Timer?
    private var isUsingEstimatedLocationFallback = false
    private var lastRealLocationTime: Date = .distantPast
    private var lastEstimatedFallbackTick: Date?
    private var estimatedFallbackSpeed: Double = 0.0
    private var estimatedFallbackDistanceAdded: Double = 0.0
    /// When a dead-reckoned point was last written, so a track exists even when the speed model
    /// is producing nothing. See the heartbeat in checkEstimatedLocationFallback.
    private var lastEstimatedAppendTime: Date = .distantPast
    private let ESTIMATED_HEARTBEAT_SECONDS: TimeInterval = 5.0
    /// Dead-reckoned movement measured before any geographic origin existed. Replayed as real
    /// points the moment one arrives, so a workout that starts without GPS keeps its shape.
    private var pendingUnanchoredMovement: [(distance: Double, heading: Double, speed: Double, timestamp: Date)] = []
    private let ESTIMATED_LOCATION_GAP_THRESHOLD: TimeInterval = 5.0
    private let ESTIMATED_LOCATION_TICK_INTERVAL: TimeInterval = 1.0
    private let ESTIMATED_LOCATION_HORIZONTAL_ACCURACY: Double = 250.0
    private let ESTIMATED_LOCATION_VERTICAL_ACCURACY: Double = 250.0

    // MARK: - Forced velocity (inertial dead reckoning) — mirrors the watch implementation
    /// UI toggle: force velocity/acceleration dead reckoning and ignore GPS for distance.
    @Published var forceMotionFallback = false
    /// Live status for the UI, e.g. "DR FORCED 62km/h +410m".
    @Published var motionFallbackStatus = "GPS OK"
    // Signed WORLD-frame velocity vector (north/east). Integrating a VECTOR (not the
    // magnitude of acceleration) is what makes deceleration subtract and transient bumps
    // cancel — integrating |accel| can only ever increase speed and diverges.
    private var motionVelNorth: Double = 0.0
    private var motionVelEast: Double = 0.0
    private var accelBiasNorth: Double = 0.0
    private var accelBiasEast: Double = 0.0
    private var prevResidualNorth: Double = 0.0
    private var prevResidualEast: Double = 0.0
    private var worldAccelNorth: Double = 0.0
    private var worldAccelEast: Double = 0.0
    private var motionHeadingDegrees: Double = 0.0
    /// Constant offset between the device's attitude-yaw heading and the actual direction of
    /// travel, captured when dead reckoning engages (travel course − device yaw). While the
    /// phone rides fixed in a pocket/mount, travel heading = device yaw + this offset — and
    /// attitude yaw tracks every turn via the gyro with NO dependence on acceleration, which
    /// is what makes direction work while walking (zero net accel) as well as in vehicles.
    private var yawHeadingOffset: Double?
    // PEDESTRIAN DEAD RECKONING (PDR): for step-based activities the accelerometer cannot
    // recover distance (steps sum to ~zero net acceleration), but Apple's pedometer — step
    // detection + stride model — measures walking distance to within a few percent. So in a
    // GPS gap the DR tick uses PEDOMETER DISTANCE + YAW HEADING for walk/run/hike, and
    // accelerometer integration only for vehicle/flight types where there are no steps.
    private let fallbackPedometer = CMPedometer()
    /// Apple's activity classifier. It reports STATIONARY / automotive / walking directly and
    /// is unaffected by how far the integrator has drifted, so it can rescue a diverged
    /// estimate that ZUPT's own thresholds can no longer reach.
    private let activityManager = CMMotionActivityManager()
    /// Speed from the ride's vibration signature — no integration, so no drift. Calibrated
    /// online from GPS while it is available (see VibrationSpeedEstimator).
    private let vibrationSpeed = VibrationSpeedEstimator()
    /// Per-tick record of what the speed model saw and decided, for export and live inspection.
    let sessionDiagnostics = SessionDiagnosticsRecorder()
    private var isDeviceStationaryByActivity = false
    private var activityIsAutomotive = false
    private var fallbackPedometerDistance: Double?      // cumulative metres since fallback start
    private var fallbackPedometerPace: Double?          // seconds per metre (for smooth speed)
    private var fallbackPedometerSpeed: Double = 0      // m/s, smoothed from pedometer updates
    private var pdrAppendedDistance: Double = 0         // total distance already laid down in PDR
    private var lastPedometerUpdateTime: Date?
    private var lastFallbackPedometerDistance: Double = 0
    private var fallbackPedometerActive = false
    private var activityUpdatesActive = false
    /// True when Motion & Fitness is denied — surfaced in the UI because it silently disables
    /// pedometer distance AND the stationary/automotive classifier.
    @Published var motionPermissionDenied = false
    /// Distance measured but not yet long enough to justify a route point; carried forward so
    /// short ticks accumulate rather than being thrown away.
    private var pendingEstimatedDistance: Double = 0
    /// Step tracking used to decide whether the pedometer is a VALID distance source right
    /// now — it is not, in a vehicle or aircraft, whatever activity the user selected.
    private var lastFallbackStepCount: Int = 0
    private var lastStepIncrementTime: Date?
    private var lastStepSampleTime: Date?
    private var stepCadence: Double = 0    // steps/s, smoothed — distinguishes walking from vehicle vibration
    /// Last heading backed by a real measurement (GPS course, or the velocity vector under
    /// genuine acceleration), plus the device yaw at that moment. Used ONLY to decide which
    /// end of the PCA walking axis we are travelling along — a binary choice, so gyro drift
    /// is harmless here even though it would ruin an absolute heading.
    private var trustedHeading: Double?
    private var trustedHeadingYaw: Double?
    /// Device yaw at the previous heading tick; its DELTA gives the turn angle.
    private var lastDeviceYawForHeading: Double?
    /// Per-tick pull of the dead-reckoned heading toward the compass. The gyro gives turns but
    /// no absolute datum; the compass has no drift. Small so real turns are never fought.
    private let COMPASS_CORRECTION_GAIN: Double = 0.25
    /// Angle from the phone's magnetic heading to the actual direction of travel, learned from
    /// the PCA walking axis. The compass alone measures device orientation, so this offset is
    /// what turns it into a usable absolute datum for travel direction.
    private var compassMisalignment: Double?

    /// The compass offset to actually apply, and how hard to pull toward it.
    ///
    /// Until this build, a nil misalignment meant NO compass correction at all — every
    /// correction site was gated behind `if let`. Heading then free-ran on the gyro from
    /// whatever it was seeded with, and integrated turn rate has no absolute datum, so an
    /// initial error simply persisted. A 0.22 km walk recorded heading east while the walk went
    /// north: the shape was right, the datum was never established, and nothing could ever pull
    /// it back. That is the worst of both worlds, because the magnetometer WAS available.
    ///
    /// Zero is a far better prior than "the seed was correct": it says the phone points roughly
    /// where you are going, which is true for a hand-held phone and merely imprecise otherwise,
    /// whereas a free-running gyro is unbounded. Applied at half gain so a genuinely learned
    /// offset, which is a real measurement of body-versus-device orientation, always wins.
    private var effectiveCompassMisalignment: (value: Double, gain: Double) {
        if let learned = compassMisalignment { return (learned, COMPASS_CORRECTION_GAIN) }
        return (0, COMPASS_CORRECTION_GAIN * 0.5)
    }
    /// Whether the heading seed came from a real GPS course rather than the compass, and where
    /// the compass-seeded run begins, so it can be rotated once the truth is known.
    private var headingSeedWasMeasured = false
    private var untrustedHeadingPrefixStart: Int?
    private var untrustedSeedHeading: Double?
    /// Rolling ~3 s of world-frame horizontal acceleration, for PCA of the walking axis.
    private var walkAccelWindow: [(north: Double, east: Double)] = []
    private let WALK_WINDOW_SAMPLES = 80   // ~1.6 s: several steps, without smearing turns
    /// EMA of the gait-skewness forward/back vote, so a single noisy ~1.6 s window (2-3 steps)
    /// cannot flip the resolved travel direction 180° on its own. See walkingAxisHeading().
    private var walkingSkewEMA: Double = 0
    private var walkingSkewEMAValid = false
    private var wasPedometerCountingForSkewReset = false
    private var isStepBasedWorkout: Bool {
        workoutType == .walking || workoutType == .running || workoutType == .hiking
    }
    // ZERO-VELOCITY UPDATE (ZUPT) state. This REPLACES the old per-second velocity leak and
    // the "settle to rest" damping. Those two heuristics decayed velocity continuously, which
    // is wrong: a steady cruise has ~zero acceleration, so a leak silently bleeds away real
    // speed and under-reports distance the longer you travel. ZUPT is the standard inertial
    // technique instead — detect moments when the device is GENUINELY stationary, and only
    // then hard-zero the velocity and re-learn the accelerometer bias. Between those moments
    // the integration is left alone to do honest physics.
    private var zuptWindow: [(t: TimeInterval, accel: Double, rotation: Double)] = []
    private var zuptWindowFilled = false
    private var isInertialStationary = false
    /// Peak residual acceleration allowed within the window for it to count as stationary.
    /// Tuned by simulation: above ~0.35 the detector starts firing during a genuine smooth
    /// cruise and destroys real velocity (a 0.5 threshold lost 80% of the distance).
    /// Above this speed, low accel + low rotation means COASTING, not stopped, so ZUPT is
    /// inhibited and velocity is held. Below it, the device may genuinely be at rest.
    private let ZUPT_MAX_SPEED: Double = 5.0            // m/s (~18 km/h): normal-stop tier
    // Prolonged-stillness tier: stricter thresholds, longer window, but NO speed gate — this
    // is what recovers from drift that has climbed above the normal-stop gate while standing.
    private let HARD_ZUPT_ACCEL: Double = 0.15          // m/s²
    private let HARD_ZUPT_ROTATION: Double = 0.18       // rad/s
    private let HARD_ZUPT_WINDOW: TimeInterval = 2.0     // s of near-total stillness
    private var hardQuietDuration: TimeInterval = 0
    private var lastFastMotionTime: Date?
    private var launchMeanNorth: Double = 0
    private var launchMeanEast: Double = 0
    private var launchWindowElapsed: TimeInterval = 0
    /// Worst horizontal accuracy still worth recording as a route point, in metres. Set loosely
    /// on purpose: weak urban GPS legitimately reaches 50–100 m and is still far better than
    /// dead reckoning, so only genuinely unusable fixes are dropped.
    /// Worst accuracy still accepted as the velocity-mode ANCHOR, so the single origin point of
    /// a dead-reckoned track is not placed by a wildly uncertain fix.
    private let GPS_MAX_USABLE_ACCURACY: Double = 150.0
    /// A fix this poor is dropped, but ONLY while a better one is still recent — see
    /// processNewLocation for why an unconditional cap is wrong in both directions.
    private let POOR_FIX_ACCURACY: Double = 100.0
    /// Accuracy that counts as "GPS is working", which is what makes dropping a bad fix safe.
    private let GOOD_FIX_ACCURACY: Double = 35.0
    private var lastGoodAccuracyFixTime: Date = .distantPast
    private var vehicleLaunchDetected = false
    /// Latched once GPS has directly measured a speed no pedestrian can reach. This is far more
    /// reliable evidence of "in a vehicle" than the inertial launch detector, which infers it
    /// from a sustained acceleration vector and can miss a gentle pull-away entirely (or one
    /// that happened before the workout was started). Used to gate vibration-model calibration
    /// and use, so a real drive is never locked out of the only non-diverging speed source.
    private var vehicleConfirmedByGPSSpeed = false
    /// When vehicle evidence was last actually OBSERVED, as opposed to remembered. The latches
    /// above never clear, which is correct for deciding "this trip is a drive" but wrong for
    /// deciding "the vibration reading right now describes a moving vehicle": after a drive,
    /// standing still with the phone in hand kept reporting vibration-derived speed forever.
    private var lastVehicleEvidenceTime: Date?
    /// Evidence goes stale after this long with nothing to renew it. Generous, because the
    /// activity classifier drops to "unknown" for long stretches inside a smooth-riding vehicle
    /// and losing the speed source mid-flight would be far worse than a late expiry.
    private let VEHICLE_EVIDENCE_TTL: TimeInterval = 300
    /// Smoothed rotation-rate magnitude — how much the device is being TURNED. A phone resting
    /// in a car, a pocket or a seat-back tray barely rotates; a phone in a hand rotates
    /// constantly. Hand tremor sits at 8–12 Hz, squarely inside the vibration passband, so
    /// handling is indistinguishable from road vibration by amplitude alone and needs its own
    /// signal to veto it.
    private var handlingRotationLevel: Double = 0
    /// Sustained rotation above this reads as a hand, not a vehicle. A car yaws ~0.2 rad/s
    /// through a turn and only briefly; an aircraft banks far more slowly than that. A phone
    /// held or fidgeted with sits well above it continuously.
    private let HANDLING_ROTATION_THRESHOLD = 0.40

    /// Vehicle evidence that is still current, rather than merely remembered from earlier in
    /// the trip. Vibration only describes a moving vehicle while we are actually in one.
    private var vehicleContextIsCurrent: Bool {
        if activityIsAutomotive { return true }
        guard let seen = lastVehicleEvidenceTime else { return false }
        return Date().timeIntervalSince(seen) < VEHICLE_EVIDENCE_TTL
    }

    /// The device is being carried in a hand rather than resting in the vehicle, so its
    /// vibration is dominated by the person holding it and says nothing about road speed.
    private var deviceIsBeingHandled: Bool {
        handlingRotationLevel > HANDLING_ROTATION_THRESHOLD
    }
    /// Long-window (~90 s) mean world acceleration = bias + gravity leakage. Removing it is
    /// what bounds a vehicle, whose true mean acceleration over such a window is ~0.
    private var longRunMeanNorth: Double = 0
    private var longRunMeanEast: Double = 0
    /// Divergence backstop: no vehicle a phone rides sustains this speed (an airliner cruises
    /// ~250 m/s), so anything beyond it is integration runaway and the velocity is rescaled
    /// back to the ceiling rather than allowed to reach thousands of km/h.
    private let DR_MAX_SPEED: Double = 360.0            // m/s (~1300 km/h)
    private let ZUPT_ACCEL_THRESHOLD: Double = 0.25     // m/s²
    /// Gyro magnitude ceiling — a stationary device is not rotating either.
    private let ZUPT_ROTATION_THRESHOLD: Double = 0.35  // rad/s
    /// The device must look quiet for this long before velocity is zeroed.
    private let ZUPT_WINDOW: TimeInterval = 0.75        // s
    /// Bias learning rate during a confirmed ZUPT (fast — the velocity is known to be zero).
    private let ZUPT_BIAS_RATE: Double = 0.05
    // CONTINUOUS gated bias estimation. This is NOT redundant with ZUPT and must not be
    // removed: the dominant real-world error is attitude error tilting GRAVITY into the
    // horizontal axes (0.5° = 0.086 m/s² of phantom acceleration). On a sustained cruise the
    // device never becomes stationary, so ZUPT never fires, and this estimator is the only
    // thing that can cancel that term. Simulation of a 30-minute highway drive: with it,
    // −0.3% distance error; without it, +211%.
    private let MOTION_BIAS_RATE: Double = 0.02    // learning rate during quiet periods
    // m/s²: above this = REAL sustained acceleration → freeze bias. Raised 0.3 → 1.0: a
    // hand-held phone standing still reads ~0.5 m/s² of gravity-leakage/tilt, which at 0.3 was
    // treated as real motion so the bias FROZE and the leakage integrated to phantom speed
    // (observed: 252 km/h while standing). At 1.0 that leakage is cancelled — which also drops
    // the residual below the ZUPT threshold so the estimate is zeroed. A vehicle/aircraft
    // launch (~2–4 m/s²) still stays above 1.0 and is preserved.
    private let MOTION_BIAS_GATE: Double = 1.0

    private var healthKitExportType: HKWorkoutActivityType {
        let preference = UserDefaults.standard.string(forKey: "healthKitExportType") ?? "auto"
        switch preference {
        case "cycling":
            return .cycling
        case "running":
            return .running
        case "walking":
            return .walking
        case "hiking":
            return .hiking
        default:
            // Fitness app doesn't show routes/distances for .other reliably.
            // Export flights as cycling when in Auto.
            return workoutType == .other ? .cycling : workoutType
        }
    }

    func setWorkoutType(_ type: HKWorkoutActivityType) {
        workoutType = type
        print("🏃 Workout type set to: \(type.rawValue)")
    }

    private func getWorkoutTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .cycling:
            return "Cycling"
        case .running:
            return "Running"
        case .walking:
            return "Walking"
        case .hiking:
            return "Hiking"
        case .other:
            return "Other"
        default:
            return "Workout"
        }
    }

    private func maxSpeedThresholdMps(for type: HKWorkoutActivityType) -> Double {
        switch type {
        case .walking, .running, .hiking, .cycling, .traditionalStrengthTraining:
            return DEFAULT_MAX_SPEED_MPS
        case .other:
            // Flight mode handled separately.
            return DEFAULT_MAX_SPEED_MPS
        default:
            return DEFAULT_MAX_SPEED_MPS
        }
    }

    private func maxDistanceJumpThreshold(for type: HKWorkoutActivityType) -> Double {
        switch type {
        case .walking, .running, .hiking, .cycling, .traditionalStrengthTraining:
            return DEFAULT_MAX_DISTANCE_JUMP
        case .other:
            // Flight mode handled separately.
            return DEFAULT_MAX_DISTANCE_JUMP
        default:
            return DEFAULT_MAX_DISTANCE_JUMP
        }
    }

    private func maxAccelerationThresholdMps2(for type: HKWorkoutActivityType) -> Double {
        switch type {
        case .walking, .running, .hiking, .cycling, .traditionalStrengthTraining:
            return DEFAULT_MAX_ACCELERATION_MPS2
        case .other:
            return 25.0
        default:
            return 6.0
        }
    }

    private init() {
        self.flight = Flight()
        setupLocationUpdates()
        setupWatchConnectivity()
        setupAppLifecycleObservers()
        setupThermalMonitoring()
    }

    private func setupThermalMonitoring() {
        thermalState = ProcessInfo.processInfo.thermalState
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let newState = ProcessInfo.processInfo.thermalState
            self.thermalState = newState
            self.applyThermalMitigation(for: newState)
        }
    }

    /// Progressively reduce power draw as the device heats up. This keeps the
    /// workout running instead of letting iOS terminate the app for overheating.
    private func applyThermalMitigation(for state: ProcessInfo.ThermalState) {
        let hot = (state == .serious || state == .critical)
        let stateName: String
        switch state {
        case .nominal: stateName = "nominal"
        case .fair: stateName = "fair"
        case .serious: stateName = "serious"
        case .critical: stateName = "critical"
        @unknown default: stateName = "unknown"
        }
        print("🌡️ Thermal state: \(stateName) — \(hot ? "throttling to cool down" : "full performance")")

        // Only throttle GPS/motion while a workout is active.
        guard isActive else { return }
        locationManager.applyThermalAccuracy(reduced: hot)
        locationManager.applyThermalMotionInterval(hot: hot)
        // Snapshot + Live Activity intervals adjust automatically via their
        // thermal-aware computed properties.
    }

    private func setupLocationUpdates() {
        locationManager.onLocationUpdate = { [weak self] location in
            self?.processNewLocation(location)
        }
        locationManager.onMotionAccelerationUpdate = { [weak self] acceleration, x, y, z, pitch, roll, yaw, rotationX, rotationY, rotationZ, timestamp in
            guard let self = self, self.isActive, !self.isPaused else { return }
            self.currentMetrics.updateWithMotionAcceleration(
                acceleration,
                x: x,
                y: y,
                z: z,
                pitch: pitch,
                roll: roll,
                yaw: yaw,
                rotationRateX: rotationX,
                rotationRateY: rotationY,
                rotationRateZ: rotationZ,
                timestamp: timestamp
            )
        }
        locationManager.onCompassHeadingUpdate = { [weak self] heading, timestamp in
            guard let self = self, self.isActive, !self.isPaused else { return }
            self.currentMetrics.updateWithCompassHeading(heading, timestamp: timestamp)
        }
        locationManager.onBarometricAltitudeUpdate = { [weak self] relativeAltitude, pressure, timestamp in
            guard let self = self, self.isActive, !self.isPaused else { return }
            self.currentMetrics.updateWithBarometricAltitude(
                relativeAltitude: relativeAltitude,
                pressure: pressure,
                timestamp: timestamp
            )
        }
    }

    private func setupWatchConnectivity() {
        // DISABLED: Don't mirror Watch workouts on iPhone
        // iPhone and Watch workouts are now independent
        // Only iPhone → Watch sync is enabled (for mirroring iPhone workouts on Watch)
        print("📱 Watch connectivity initialized (iPhone → Watch sync only)")
    }

    private func setupAppLifecycleObservers() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.handleDidEnterBackground()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.handleWillEnterForeground()
            }
            .store(in: &cancellables)
    }

    func handleAppLaunch(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        let launchedForLocation = launchOptions?[.location] != nil
        if launchedForLocation {
            print("📱 App launched by iOS for location event")
        }
        restoreActiveWorkoutIfNeeded(launchedForLocationEvent: launchedForLocation)
    }

    func handleAppWillTerminate() {
        guard isActive else { return }
        persistActiveWorkoutSnapshot(force: true, reason: "willTerminate", shouldLog: true)
    }

    private func handleDidEnterBackground() {
        guard isActive else { return }
        print("📱 App entered background with active workout - requesting transition background task")
        beginTransitionBackgroundTask()
        logBackgroundRefreshStatus()
        if locationManager.authorizationStatus == .authorizedWhenInUse {
            print("⚠️ Background reliability is limited with 'When In Use' permission - requesting 'Always'")
            locationManager.requestAlwaysAuthorization()
        }
        persistActiveWorkoutSnapshot(force: true, reason: "enteredBackground", shouldLog: true)
    }

    private func handleWillEnterForeground() {
        persistActiveWorkoutSnapshot(force: true, reason: "enteredForeground", shouldLog: true)
        endTransitionBackgroundTaskIfNeeded()
    }

    private func restoreActiveWorkoutIfNeeded(launchedForLocationEvent: Bool) {
        guard !didAttemptSnapshotRestore else { return }
        didAttemptSnapshotRestore = true

        guard let snapshot = loadActiveWorkoutSnapshot() else { return }

        if snapshot.flight.endDate != nil {
            // Snapshot was finishing when the app died — make sure the track is saved.
            recoverOrphanedWorkout(snapshot, endDate: snapshot.flight.endDate ?? snapshot.savedAt, reason: "snapshotAlreadyEnded")
            clearActiveWorkoutSnapshot(reason: "snapshotAlreadyEnded", shouldLog: true)
            return
        }

        let age = Date().timeIntervalSince(snapshot.savedAt)
        if age > ACTIVE_WORKOUT_MAX_RESTORE_AGE {
            print("⚠️ Active workout snapshot too old to resume (\(Int(age/3600))h old) — recovering track instead of discarding")
            // Don't lose the trace: finalize and save it locally so the user keeps the route.
            recoverOrphanedWorkout(snapshot, endDate: snapshot.savedAt, reason: "snapshotTooOld")
            clearActiveWorkoutSnapshot(reason: "snapshotTooOld", shouldLog: true)
            return
        }

        flight = snapshot.flight
        currentMetrics = snapshot.currentMetrics
        workoutType = HKWorkoutActivityType(rawValue: snapshot.workoutTypeRawValue) ?? .walking
        isActive = true
        isPaused = snapshot.isPaused
        totalPausedTime = snapshot.totalPausedTime
        pauseStartTime = snapshot.pauseStartTime
        locationsToSkipAfterResume = snapshot.locationsToSkipAfterResume
        lastLiveActivityUpdate = nil
        lastSnapshotSaveDate = snapshot.savedAt

        print("✅ Restored active workout snapshot: id=\(flight.id), locations=\(flight.locations.count), distance=\(String(format: "%.2f", currentMetrics.totalDistance/1000))km, paused=\(isPaused)")
        if launchedForLocationEvent {
            print("📍 Restore path triggered by location launch event")
        }
        logBackgroundRefreshStatus()

        let activityType: CLActivityType = (workoutType == .other) ? .airborne : .fitness
        locationManager.updateActivityType(activityType)
        if !isPaused {
            locationManager.startTracking()
        }

        // Re-arm notifications and Live Activity after process relaunch.
        notificationManager.requestAuthorization { [weak self] granted in
            guard let self = self, granted else { return }
            self.notificationManager.startWorkoutNotifications(workoutSession: self)
        }

        if #available(iOS 16.1, *), WorkoutLiveActivityManager.isSupported {
            WorkoutLiveActivityManager.shared.startLiveActivity(workoutType: getWorkoutTypeName(workoutType))
            WorkoutLiveActivityManager.shared.updateLiveActivity(
                duration: activeDuration,
                distance: currentMetrics.totalDistance,
                speed: liveActivitySpeedMps,
                calories: currentMetrics.caloriesBurned,
                altitude: currentMetrics.currentAltitude,
                heartRate: currentMetrics.currentHeartRate,
                isPaused: isPaused
            )
        }

        NotificationCenter.default.post(name: .workoutDidStart, object: nil)
        persistActiveWorkoutSnapshot(force: true, reason: "restored", shouldLog: true)
    }

    /// Crash-recovery fallback: when an active-workout snapshot can't be resumed
    /// (stale, or it was mid-finish when the process died), finalize the captured
    /// track into a saved Flight and push it to HealthKit so the trace is never lost.
    private func recoverOrphanedWorkout(_ snapshot: ActiveWorkoutSnapshot, endDate: Date, reason: String) {
        var recovered = snapshot.flight
        guard !recovered.locations.isEmpty else {
            print("♻️ Orphaned workout (\(reason)) has no locations — nothing to recover")
            return
        }

        // Skip if this flight was already saved (avoid duplicates).
        if FlightDataStore.shared.getFlight(by: recovered.id) != nil
            || FlightDataStore.shared.loadFlightDetails(id: recovered.id) != nil {
            print("♻️ Orphaned workout \(recovered.id) already saved — skipping recovery")
            return
        }

        recovered.endDate = endDate

        var metrics = snapshot.currentMetrics
        let duration = max(0, endDate.timeIntervalSince(recovered.startDate) - snapshot.totalPausedTime)
        metrics.calculateAverages(duration: duration)
        metrics.estimateCalories(duration: duration)
        metrics.finalizeSplits()
        metrics.sanitize()  // guard against NaN/Inf so the save can't crash
        recovered.metrics = metrics
        if recovered.effort == nil { recovered.effort = 10 }

        // 1) Always persist locally first — this guarantees the trace survives.
        FlightDataStore.shared.saveFlight(recovered)
        print("♻️ Recovered orphaned workout (\(reason)): id=\(recovered.id), locations=\(recovered.locations.count), distance=\(String(format: "%.2f", metrics.totalDistance/1000))km — saved locally")

        // 2) Best-effort export to HealthKit (non-fatal if it fails; track is already safe locally).
        let recoveredFlight = recovered
        let recoveredMetrics = metrics
        healthKitManager.resyncFlightToHealthKit(
            flight: recoveredFlight,
            locations: recoveredFlight.locations,
            metrics: recoveredMetrics
        ) { success, error, workout in
            if success {
                if let workout = workout {
                    FlightDataStore.shared.updateWorkoutUUID(for: recoveredFlight.id, workoutUUID: workout.uuid)
                }
                print("♻️ Recovered workout exported to HealthKit ✅")
            } else {
                print("♻️ Recovered workout HealthKit export failed (track safe locally): \(error?.localizedDescription ?? "unknown")")
            }
        }
    }

    private func loadActiveWorkoutSnapshot() -> ActiveWorkoutSnapshot? {
        let url = activeWorkoutSnapshotURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ActiveWorkoutSnapshot.self, from: data)
        } catch {
            print("⚠️ Failed to decode active workout snapshot: \(error.localizedDescription)")
            clearActiveWorkoutSnapshot(reason: "decodeFailed", shouldLog: true)
            return nil
        }
    }

    private func persistActiveWorkoutSnapshot(
        force: Bool = false,
        reason: String,
        shouldLog: Bool = false
    ) {
        guard isActive else { return }

        let now = Date()
        if !force, let lastSave = lastSnapshotSaveDate,
           now.timeIntervalSince(lastSave) < ACTIVE_WORKOUT_AUTOSAVE_INTERVAL {
            return
        }

        let snapshot = ActiveWorkoutSnapshot(
            flight: flight,
            currentMetrics: currentMetrics,
            workoutTypeRawValue: workoutType.rawValue,
            isPaused: isPaused,
            totalPausedTime: totalPausedTime,
            pauseStartTime: pauseStartTime,
            locationsToSkipAfterResume: locationsToSkipAfterResume,
            savedAt: now
        )

        lastSnapshotSaveDate = now
        let url = activeWorkoutSnapshotURL

        activeWorkoutSnapshotQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("⚠️ Failed to save active workout snapshot: \(error.localizedDescription)")
            }
        }

        if shouldLog {
            print("💾 Active workout checkpoint saved (\(reason)): locations=\(snapshot.flight.locations.count), distance=\(String(format: "%.2f", snapshot.currentMetrics.totalDistance/1000))km")
        }
    }

    private func clearActiveWorkoutSnapshot(reason: String, shouldLog: Bool = false) {
        lastSnapshotSaveDate = nil
        let url = activeWorkoutSnapshotURL

        activeWorkoutSnapshotQueue.async {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("⚠️ Failed to clear active workout snapshot: \(error.localizedDescription)")
            }
        }

        if shouldLog {
            print("🧹 Cleared active workout snapshot (\(reason))")
        }
    }

    private func logBackgroundRefreshStatus() {
        let status = UIApplication.shared.backgroundRefreshStatus
        switch status {
        case .available:
            print("📱 Background App Refresh: Available")
        case .denied:
            print("⚠️ Background App Refresh: Disabled (Settings) - location relaunch will not work reliably")
        case .restricted:
            print("⚠️ Background App Refresh: Restricted")
        @unknown default:
            print("⚠️ Background App Refresh: Unknown status")
        }
    }

    private func beginTransitionBackgroundTask() {
        endTransitionBackgroundTaskIfNeeded()

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WorkoutTrackingTransition") { [weak self] in
            guard let self = self else { return }
            print("⚠️ Workout transition background task expired")
            self.endTransitionBackgroundTaskIfNeeded()
        }

        if backgroundTaskID == .invalid {
            print("⚠️ Failed to start transition background task")
        } else {
            print("✅ Transition background task started")
        }
    }

    private func endTransitionBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        print("✅ Transition background task ended")
    }

    // DISABLED: iPhone no longer mirrors Watch workout data
    // Each device runs workouts independently
    private func updateMetricsFromWatchData(_ data: WorkoutSyncData) {
        // No longer used - removed to prevent Watch → iPhone mirroring
    }

    func startWorkoutOnWatch() {
        print("📱 Starting workout on Watch with type: \(workoutType.rawValue)")
        connectivityManager.startWorkoutOnWatch(workoutType: Int(workoutType.rawValue))
    }

    func stopWorkoutOnWatch() {
        connectivityManager.stopWorkoutOnWatch()
    }

    /// Ask for Motion & Fitness explicitly and report the outcome.
    ///
    /// The app previously only called startUpdates(), which fails SILENTLY when the user was
    /// never prompted or has declined — so CMPedometer (walking distance) and
    /// CMMotionActivityManager (stationary / automotive detection) both returned nothing and
    /// every feature built on them was dead. A historical query is the documented way to
    /// trigger the prompt.
    func ensureMotionPermission() {
        let status = CMPedometer.authorizationStatus()
        switch status {
        case .authorized:
            motionPermissionDenied = false
        case .denied, .restricted:
            motionPermissionDenied = true
            print("📍 ⛔️ Motion & Fitness DENIED — pedometer and activity classifier unavailable")
        case .notDetermined:
            // Triggers the system prompt.
            fallbackPedometer.queryPedometerData(from: Date().addingTimeInterval(-60), to: Date()) { [weak self] _, error in
                DispatchQueue.main.async {
                    self?.motionPermissionDenied = (CMPedometer.authorizationStatus() != .authorized)
                    if let error { print("📍 ⚠️ Motion permission query: \(error.localizedDescription)") }
                }
            }
        @unknown default:
            motionPermissionDenied = false
        }
    }

    func startWorkout() {
        guard !isActive else {
            print("⚠️ startWorkout ignored: workout already active")
            NotificationCenter.default.post(name: .openLiveSessionRequested, object: nil)
            return
        }

        print("🚀 Starting workout session...")
        ensureMotionPermission()
        clearActiveWorkoutSnapshot(reason: "newWorkoutStart")

        // Initialize flight first
        let startDate = Date()
        flight = Flight(startDate: startDate)
        flight.workoutType = workoutType.rawValue
        isActive = true
        lastRealLocationTime = startDate
        lastGoodAccuracyFixTime = .distantPast
        pendingUnanchoredMovement = []
        lastEstimatedAppendTime = Date()
        isUsingEstimatedLocationFallback = false
        lastEstimatedFallbackTick = nil
        estimatedFallbackSpeed = 0.0
        estimatedFallbackDistanceAdded = 0.0
        forceMotionFallback = false          // manual velocity override always starts OFF
        motionFallbackStatus = "GPS OK"
        resetInertialState(seedSpeed: 0, courseDegrees: 0)
        // Feed the inertial integrator at the device-motion sample rate.
        locationManager.onWorldAccelSample = { [weak self] north, east, up, rotationRate, dt in
            self?.integrateWorldAccelSample(north: north, east: east, up: up,
                                            rotationRate: rotationRate, dt: dt)
        }
        // Feed the vibration model. World-frame components are used only as a convenient
        // 3-axis sample; the feature is rotation-invariant magnitude, so orientation does not
        // matter — which is precisely why this path is immune to the attitude errors that
        // corrupt integration.
        locationManager.onWorldAccelSampleSecondary = { [weak self] north, east, up, _, dt in
            guard let self else { return }
            self.vibrationSpeed.ingest(ax: north, ay: east, az: up, dt: dt)
            // Keep the raw vertical trace alongside the model's own view of it. Everything the
            // estimator computes is a lossy summary; a spectrum can only be taken from this.
            self.sessionDiagnostics.recordRaw(verticalAccel: up, at: Date())
        }
        vibrationSpeed.reset()
        sessionDiagnostics.reset()
        NotificationCenter.default.post(name: .workoutDidStart, object: nil)

        print("✅ Flight initialized at: \(startDate)")
        persistActiveWorkoutSnapshot(force: true, reason: "startWorkout", shouldLog: true)

        let activityType: CLActivityType = (workoutType == .other) ? .airborne : .fitness
        locationManager.updateActivityType(activityType)

        // Apply current thermal state immediately (device may already be warm).
        thermalState = ProcessInfo.processInfo.thermalState
        applyThermalMitigation(for: thermalState)

        if workoutType != .other {
            let speedThresholdKmh = maxSpeedThresholdMps(for: workoutType) * 3.6
            let jumpThreshold = maxDistanceJumpThreshold(for: workoutType)
            let accelerationThreshold = maxAccelerationThresholdMps2(for: workoutType)
            print("📏 Movement thresholds: maxSpeed=\(String(format: "%.1f", speedThresholdKmh))km/h, maxJump=\(String(format: "%.0f", jumpThreshold))m, maxAccel=\(String(format: "%.1f", accelerationThreshold))m/s²")
        }

        // Start Live Activity for Dynamic Island
        if #available(iOS 16.1, *) {
            if WorkoutLiveActivityManager.isSupported {
                let workoutTypeName = getWorkoutTypeName(workoutType)
                WorkoutLiveActivityManager.shared.startLiveActivity(workoutType: workoutTypeName)
                print("🔴 Live Activity started for Dynamic Island")
            } else {
                print("⚠️ Live Activity unavailable (device unsupported or Live Activities disabled in Settings)")
            }
        }

        // Request notification permission and start notifications
        notificationManager.requestAuthorization { [weak self] granted in
            if granted, let self = self {
                self.notificationManager.startWorkoutNotifications(workoutSession: self)
            }
        }

        // Check and request location permission if needed
        let locationStatus = locationManager.authorizationStatus
        print("📍 Location permission status: \(locationStatus.rawValue)")
        logBackgroundRefreshStatus()

        if locationStatus == .authorizedWhenInUse {
            print("⚠️ 'When In Use' permission may suspend long workouts in background - requesting 'Always'")
            locationManager.requestAlwaysAuthorization()
        }

        if locationStatus == .notDetermined {
            print("📍 Requesting location permission (iOS will show dialog)...")
            print("⏳ Will start tracking once permission is granted...")

            // Request permission and listen for changes
            locationManager.requestAuthorization()

            // Set up observer to start tracking once permission is granted
            locationManager.$authorizationStatus
                .sink { [weak self] status in
                    if status == .authorizedWhenInUse || status == .authorizedAlways {
                        print("✅ Permission granted! Starting location tracking now...")
                        self?.locationManager.startTracking()
                        print("📍 GPS tracking active - locations will be collected")
                    }
                }
                .store(in: &cancellables)
        } else if locationStatus == .denied || locationStatus == .restricted {
            print("❌ Location permission denied!")
            print("👉 Please enable location access in:")
            print("   Settings → Privacy & Security → Location Services → GPS Workout Tracker")
        } else {
            // Already have permission - start tracking immediately
            print("📍 Starting location tracking...")
            locationManager.startTracking()
            print("📍 GPS tracking active - locations will be collected")
        }
        startEstimatedFallbackTimer()

        // HealthKit operations (only on real devices)
        #if targetEnvironment(simulator)
        print("⚠️ HealthKit workout tracking not available in simulator")
        print("✅ GPS tracking active - test on physical device for full HealthKit integration")
        #else
        // Request HealthKit permission if not already authorized
        // IMPORTANT: Don't check status repeatedly - just request if needed
        if !healthKitManager.isAuthorized {
            print("🏥 Requesting HealthKit permission...")
            healthKitManager.requestAuthorization { [weak self] success, error in
                if success {
                    print("✅ HealthKit permission granted")
                    self?.startHealthKitWorkout(startDate: startDate)
                } else {
                    print("❌ HealthKit permission denied: \(error?.localizedDescription ?? "Unknown")")
                    print("💡 To enable: Settings → Health → Data Access & Devices → This App")
                }
            }
        } else {
            // Already authorized - just start the workout
            print("✅ HealthKit authorized - starting workout builder")
            startHealthKitWorkout(startDate: startDate)
        }
        #endif

        // DISABLED: Watch no longer mirrors iPhone workouts
        // No notification needed

        print("✅ Workout session started - isActive: \(isActive)")
    }

    #if !targetEnvironment(simulator)
    private func startHealthKitWorkout(startDate: Date) {
        print("🏥 HealthKit workout tracking enabled")
        print("💡 Builder will be created when you stop the workout (avoids Error(7) state)")
        print("📊 GPS data is being collected - workout will be saved to HealthKit when you stop")

        // Don't create the builder here - it often enters Error(7) state if HealthKit daemon isn't ready
        // Instead, we'll create a FRESH builder when stopping the workout
        // This avoids the builder sitting in error state for the entire workout
    }

    #endif

    func stopWorkout(completion: @escaping (Bool) -> Void) {
        persistActiveWorkoutSnapshot(force: true, reason: "stopWorkoutRequested", shouldLog: true)
        // The manual velocity override is a per-workout choice; never let it leak forward.
        forceMotionFallback = false
        stopEstimatedFallbackTimer()

        // Stop location tracking
        locationManager.stopTracking()

        // End workout session
        let endDate = Date()
        flight.endDate = endDate

        // If still paused when stopping, accumulate final pause time
        if isPaused, let pauseStart = pauseStartTime {
            let pausedDuration = Date().timeIntervalSince(pauseStart)
            totalPausedTime += pausedDuration
            print("⏱️ Final pause duration: \(String(format: "%.1f", pausedDuration))s")
        }

        // SAFETY: Validate workout data before proceeding
        guard flight.locations.count > 0 else {
            print("⚠️ WARNING: Workout has no locations - saving minimal data")
            flight.metrics = currentMetrics
            FlightDataStore.shared.saveFlight(flight)
            isActive = false
            clearActiveWorkoutSnapshot(reason: "stopNoLocations", shouldLog: true)
            completion(false)
            return
        }

        // Calculate final metrics using active duration (excluding paused time)
        let finalActiveDuration = max(0, activeDuration) // Ensure non-negative
        print("⏱️ Total active time: \(String(format: "%.1f", finalActiveDuration))s (paused: \(String(format: "%.1f", totalPausedTime))s)")

        // 🔒 CRITICAL: Capture distance BEFORE any further processing to ensure accuracy
        // This is the CORRECT distance that was displayed during the workout
        let displayedDistance = currentMetrics.totalDistance
        print("🔒 DISTANCE GUARD: Captured displayed distance = \(String(format: "%.2f", displayedDistance/1000))km (\(displayedDistance)m)")
        print("🔒 This distance was calculated incrementally during the workout from pre-filtered GPS points")
        print("🔒 This is the CORRECT distance - will use this for HealthKit")

        // DO NOT recalculate - the displayed distance is already correct!
        // The incremental distance tracking during workout uses pre-filtered locations from processNewLocation()
        // Recalculating would apply different filters and produce incorrect results

        // Ensure distance is preserved before calculating averages
        currentMetrics.totalDistance = displayedDistance
        currentMetrics.calculateAverages(duration: finalActiveDuration)
        currentMetrics.estimateCalories(duration: finalActiveDuration)
        currentMetrics.finalizeSplits()
        currentMetrics.sanitize()  // guard against NaN/Inf before save (local + HealthKit)
        flight.metrics = currentMetrics
        if flight.effort == nil {
            flight.effort = 10
            print("⚡️ Effort not set - defaulting to 10")
        }

        // 🔒 VERIFY: Distance should not have changed
        print("🔒 DISTANCE GUARD: After calculateAverages = \(String(format: "%.2f", currentMetrics.totalDistance/1000))km (\(currentMetrics.totalDistance)m)")
        if abs(currentMetrics.totalDistance - displayedDistance) > 0.1 {
            print("⚠️⚠️⚠️ CRITICAL BUG: Distance changed after calculateAverages!")
            print("   Before: \(displayedDistance)m")
            print("   After: \(currentMetrics.totalDistance)m")
            print("   Difference: \(currentMetrics.totalDistance - displayedDistance)m")
            // Force restore the correct distance
            currentMetrics.totalDistance = displayedDistance
            flight.metrics = currentMetrics
        }

        // Log final metrics for verification
        print("📊 ========== FINAL WORKOUT METRICS ==========")
        print("📊 Start Date: \(flight.startDate)")
        print("📊 End Date: \(endDate)")
        print("📊 Duration: \(String(format: "%.1f", finalActiveDuration))s (\(currentMetrics.formattedDuration))")
        print("📊 Distance: \(String(format: "%.2f", currentMetrics.totalDistance/1000))km (\(currentMetrics.totalDistance)m)")
        print("📊 Avg Speed: \(String(format: "%.1f", currentMetrics.averageSpeed * 3.6))km/h (\(currentMetrics.averageSpeed)m/s)")
        print("📊 Max Speed: \(String(format: "%.1f", currentMetrics.maxSpeed * 3.6))km/h (\(currentMetrics.maxSpeed)m/s)")
        print("📊 Max Acceleration: \(String(format: "%.2f", currentMetrics.maxAcceleration ?? 0))m/s²")
        print("📊 Max Deceleration: \(String(format: "%.2f", currentMetrics.maxDeceleration ?? 0))m/s²")
        print("📊 Max Motion Acceleration: \(String(format: "%.2f", currentMetrics.maxMotionAcceleration ?? 0))m/s²")
        print("📊 Smoothed Speed: \(String(format: "%.1f", currentMetrics.smoothedSpeed * 3.6))km/h (\(currentMetrics.smoothedSpeed)m/s)")
        print("📊 Current Speed: \(String(format: "%.1f", currentMetrics.currentSpeed * 3.6))km/h (\(currentMetrics.currentSpeed)m/s)")
        print("📊 Avg Pace: \(currentMetrics.formattedAveragePace)")
        print("📊 Max Altitude: \(String(format: "%.1f", currentMetrics.maxAltitude))m")
        print("📊 Min Altitude: \(String(format: "%.1f", currentMetrics.minAltitude))m")
        print("📊 Altitude Gain: \(String(format: "%.1f", currentMetrics.totalAltitudeGain))m")
        print("📊 Altitude Loss: \(String(format: "%.1f", currentMetrics.totalAltitudeLoss))m")
        print("📊 Baro Gain/Loss: \(String(format: "%.1f", currentMetrics.barometricAltitudeGain ?? 0))m / \(String(format: "%.1f", currentMetrics.barometricAltitudeLoss ?? 0))m")
        print("📊 GPS Quality: current=\(String(format: "%.0f", currentMetrics.currentGPSQualityScore ?? 0)), avg=\(String(format: "%.0f", currentMetrics.averageGPSQualityScore ?? 0))")
        print("📊 Calories: \(String(format: "%.0f", currentMetrics.caloriesBurned))kcal")
        if let steps = currentMetrics.stepsCount {
            print("📊 Steps: \(String(format: "%.0f", steps)) steps")
        } else {
            print("📊 Steps: Not available (will be estimated from distance)")
        }
        print("📊 GPS Points: \(currentMetrics.totalPoints) (valid: \(currentMetrics.validPoints))")
        print("📊 Avg Accuracy: ±\(String(format: "%.1f", currentMetrics.averageAccuracy))m")
        print("📊 Signal Coverage: \(String(format: "%.1f", currentMetrics.signalCoverage))%")
        print("📊 Speed History Count: \(currentMetrics.speedHistory.count)")
        print("📊 ============================================")

        // CRITICAL CHECK: Verify metrics are not zero
        if currentMetrics.maxSpeed == 0.0 {
            print("⚠️⚠️⚠️ WARNING: MAX SPEED IS ZERO! This is wrong!")
            print("   Speed history has \(currentMetrics.speedHistory.count) samples")
            // SAFETY: Use safe array access
            if !currentMetrics.speedHistory.isEmpty, currentMetrics.speedHistory.count > 0 {
                let maxInHistory = currentMetrics.speedHistory.compactMap { $0.speed }.max() ?? 0
                print("   Max speed in history: \(String(format: "%.1f", maxInHistory * 3.6))km/h")
            }
        }

        if currentMetrics.totalDistance == 0.0 {
            print("⚠️⚠️⚠️ WARNING: DISTANCE IS ZERO! This is wrong!")
        }

        // Stop workout notifications and show completion
        notificationManager.stopWorkoutNotifications()
        notificationManager.showCompletionNotification(metrics: currentMetrics, duration: finalActiveDuration)

        // End Live Activity
        if #available(iOS 16.1, *) {
            WorkoutLiveActivityManager.shared.endLiveActivity(
                finalDuration: finalActiveDuration,
                finalDistance: currentMetrics.totalDistance,
                finalCalories: currentMetrics.caloriesBurned
            )
            print("🔴 Live Activity ended")
        }

        // DISABLED: Watch no longer mirrors iPhone workouts
        // No notification needed

        // Note: HKWorkoutBuilder automatically calculates distance from saved route
        // Distance appears in Fitness app from the route data, not manual samples

        isActive = false
        clearActiveWorkoutSnapshot(reason: "stopWorkoutCompleted", shouldLog: true)
        endTransitionBackgroundTaskIfNeeded()
        NotificationCenter.default.post(name: .workoutDidStop, object: nil)

        // Save flight to local storage (includes route data)
        // Note: FlightDataStore automatically creates a summary to reduce memory
        FlightDataStore.shared.saveFlight(flight)
        print("✅ Flight saved to local storage successfully")

        // MEMORY OPTIMIZATION: Keep a copy of locations for HealthKit, then clear from flight
        let locationsForHealthKit = flight.locations
        print("   ⚡️ Keeping \(locationsForHealthKit.count) locations for HealthKit save")

        // Clear location data from flight object to free memory (already saved to file)
        flight.locations = []
        currentMetrics.speedHistory = []
        currentMetrics.altitudeHistory = []
        currentMetrics.accelerationHistory = []
        currentMetrics.motionAccelerationHistory = []
        currentMetrics.barometricAltitudeHistory = []
        currentMetrics.gpsQualityHistory = []
        print("   ⚡️ Cleared location arrays from memory - data saved to file")

        #if targetEnvironment(simulator)
        // In simulator, just complete without HealthKit operations
        print("⚠️ Workout stopped in simulator - HealthKit save skipped")
        print("📊 Flight data collected: \(locationsForHealthKit.count) locations")
        completion(true)
        #else
        // On real device, always save via direct workout creation to ensure
        // the displayed distance is preserved.
        print("✅ Saving to HealthKit using direct workout save (displayed distance)")
        fallbackSaveToHealthKit(locations: locationsForHealthKit, endDate: endDate) { success in
            completion(success)
        }
        return

        // Legacy builder path (kept for reference; currently bypassed)
        // Since we no longer create the builder at workout start (to avoid Error(7) state),
        // workoutBuilder will be nil and we'll use the fresh builder approach
        guard let builder = workoutBuilder else {
            print("✅ Creating fresh HealthKit builder for save (avoids Error(7) state)")
            fallbackSaveToHealthKit(locations: locationsForHealthKit, endDate: endDate) { success in
                completion(success)
            }
            return
        }

        print("📊 Finishing workout...")
        print("📊 Adding final workout statistics to HealthKit...")

        // SAFETY: Check if builder is in a valid state before proceeding
        // If builder failed during collection, skip straight to fallback
        if #available(iOS 17.0, *) {
            // Note: We can't directly check builder state in older iOS versions
            // The error will surface when we try to add metadata
            print("📊 Proceeding with HealthKit builder save...")
        }

        // Add metadata first
        var metadata: [String: Any] = [
            HKMetadataKeyIndoorWorkout: false,
            HKMetadataKeyTimeZone: TimeZone.current.identifier,
            "totalDistance": currentMetrics.totalDistance,
            "com.exmstc.gps.gpsDistanceMeters": displayedDistance,
            "averageSpeed": currentMetrics.averageSpeed,
            "maxSpeed": currentMetrics.maxSpeed,
            "maxAcceleration": currentMetrics.maxAcceleration ?? 0,
            "maxDeceleration": currentMetrics.maxDeceleration ?? 0,
            "averageAcceleration": currentMetrics.averageAcceleration ?? 0,
            "maxMotionAcceleration": currentMetrics.maxMotionAcceleration ?? 0,
            "averageMotionAcceleration": currentMetrics.averageMotionAcceleration ?? 0,
            "maxAltitude": currentMetrics.maxAltitude,
            "minAltitude": currentMetrics.minAltitude,
            "altitudeGain": currentMetrics.totalAltitudeGain,
            "altitudeLoss": currentMetrics.totalAltitudeLoss,
            "barometricAltitudeGain": currentMetrics.barometricAltitudeGain ?? 0,
            "barometricAltitudeLoss": currentMetrics.barometricAltitudeLoss ?? 0,
            "maxClimbRate": currentMetrics.maxClimbRate ?? 0,
            "maxDescentRate": currentMetrics.maxDescentRate ?? 0,
            "averagePace": currentMetrics.averagePacePerKm,
            "gpsPoints": currentMetrics.totalPoints,
            "validPoints": currentMetrics.validPoints,
            "averageAccuracy": currentMetrics.averageAccuracy,
            "averageGPSQualityScore": currentMetrics.averageGPSQualityScore ?? 0,
            "worstGPSQualityScore": currentMetrics.worstGPSQualityScore ?? 0
        ]
        currentMetrics.healthKitSensorMetadata.forEach { metadata[$0.key] = $0.value }
        if let nativeStepDistance = currentMetrics.nativeStepDistance, nativeStepDistance > 0 {
            metadata["com.exmstc.gps.nativeStepDistanceMeters"] = nativeStepDistance
        }
        if let nativeStepCount = currentMetrics.stepsCount, nativeStepCount > 0 {
            metadata["com.exmstc.gps.nativeStepCount"] = nativeStepCount
        }

        let nativeStepDistanceText = currentMetrics.nativeStepDistance.map { String(format: "%.2f", $0) } ?? "nil"
        let nativeStepCountText = currentMetrics.stepsCount.map { String(format: "%.0f", $0) } ?? "nil"
        print("📱 🧭 Save channels: gpsDistance=\(String(format: "%.2f", displayedDistance))m, nativeSteps=\(nativeStepCountText), nativeStepDistance=\(nativeStepDistanceText)m")

        if let effort = flight.effort {
            metadata["effort"] = effort
        }

        if currentMetrics.totalAltitudeGain > 0 {
            metadata[HKMetadataKeyElevationAscended] = HKQuantitySafe(unit: .meter(), doubleValue: currentMetrics.totalAltitudeGain)
        }
        if currentMetrics.totalAltitudeLoss > 0 {
            metadata[HKMetadataKeyElevationDescended] = HKQuantitySafe(unit: .meter(), doubleValue: currentMetrics.totalAltitudeLoss)
        }

        builder.addMetadata(sanitizedHealthKitMetadata(metadata)) { metadataSuccess, metadataError in
            if !metadataSuccess {
                print("⚠️ Failed to add metadata: \(metadataError?.localizedDescription ?? "Unknown")")
                print("⚠️ Builder is in error state - switching to fallback save")
                // Builder is broken - use fallback immediately
                self.fallbackSaveToHealthKit(locations: locationsForHealthKit, endDate: endDate) { success in
                    completion(success)
                }
                return
            }
            print("✅ Metadata added successfully")

            // Use locations for HealthKit samples (already sampled at 1 point per minute during GPS collection)
            let sampledLocations = locationsForHealthKit

            let exportType = self.healthKitExportType
            self.healthKitManager.addWorkoutSamples(
                to: builder,
                metrics: self.currentMetrics,
                activityType: exportType,
                locations: sampledLocations,
                startDate: self.flight.startDate,
                endDate: endDate,
                includeDistanceSamples: false
            ) {
                // Keep the primary activity distance and mirror cycling to walking/running totals.
                var distanceIdentifiers: [HKQuantityTypeIdentifier]
                switch exportType {
                case .cycling, .running, .walking, .hiking:
                    distanceIdentifiers = [.distanceCycling, .distanceWalkingRunning]
                default:
                    distanceIdentifiers = [.distanceWalkingRunning]
                }

                var distanceSources: [(label: String, value: Double)] = [("gps", displayedDistance)]
                if (exportType == .running || exportType == .walking || exportType == .hiking),
                   let nativeStepDistance = self.currentMetrics.nativeStepDistance,
                   nativeStepDistance > 0 {
                    distanceSources.append(("nativeStep", nativeStepDistance))
                }

                // 🔒 CRITICAL: Use the captured displayed distance for HealthKit
                print("🔒 DISTANCE GUARD: Creating HealthKit distance sample with \(String(format: "%.2f", displayedDistance/1000))km (\(displayedDistance)m)")

                var distanceSamples: [HKSample] = []
                for source in distanceSources {
                    for identifier in distanceIdentifiers {
                        guard let distanceType = HKQuantityType.quantityType(forIdentifier: identifier) else {
                            print("❌ CRITICAL: Failed to create distance quantity type for \(identifier)")
                            self.fallbackSaveToHealthKit(locations: locationsForHealthKit, endDate: endDate) { success in
                                completion(success)
                            }
                            return
                        }

                        let distanceSample = HKCumulativeQuantitySample(
                            type: distanceType,
                            quantity: HKQuantitySafe(unit: .meter(), doubleValue: source.value),
                            start: self.flight.startDate,
                            end: endDate
                        )
                        distanceSamples.append(distanceSample)
                    }
                }

                self.healthKitManager.fetchEnergyStats(startDate: self.flight.startDate, endDate: endDate) { activeEnergy, basalEnergy in
                    var activeEnergyValue = self.currentMetrics.caloriesBurned
                    if let activeEnergy, activeEnergy > 0 {
                        activeEnergyValue = activeEnergy
                    }

                    var basalEnergyValue: Double = 0
                    if let basalEnergy, basalEnergy > 0 {
                        basalEnergyValue = basalEnergy
                    }

                    self.currentMetrics.caloriesBurned = activeEnergyValue
                    self.currentMetrics.restingEnergyBurned = basalEnergyValue
                    self.flight.metrics = self.currentMetrics

                    if let details = FlightDataStore.shared.loadFlightDetails(id: self.flight.id) {
                        var updated = details
                        updated.metrics = self.currentMetrics
                        FlightDataStore.shared.saveFlight(updated)
                    }

                    // SAFETY: Guard against nil quantity type
                    guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
                        print("❌ CRITICAL: Failed to create energy quantity type")
                        self.fallbackSaveToHealthKit(locations: locationsForHealthKit, endDate: endDate) { success in
                            completion(success)
                        }
                        return
                    }

                    let energyQuantity = HKQuantitySafe(unit: .kilocalorie(), doubleValue: activeEnergyValue)
                    let energySample = HKCumulativeQuantitySample(
                        type: energyType,
                        quantity: energyQuantity,
                        start: self.flight.startDate,
                        end: endDate
                    )

                    var samples: [HKSample] = distanceSamples
                    samples.append(energySample)

                    if basalEnergyValue > 0, let basalType = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned) {
                        let basalQuantity = HKQuantitySafe(unit: .kilocalorie(), doubleValue: basalEnergyValue)
                        let basalSample = HKCumulativeQuantitySample(
                            type: basalType,
                            quantity: basalQuantity,
                            start: self.flight.startDate,
                            end: endDate
                        )
                        samples.append(basalSample)
                    }

                    print("📊 Adding distance and energy samples to workout:")
                    let distanceTypeText = distanceIdentifiers.map { "\($0)" }.joined(separator: ", ")
                    print("   Distance Types: \(distanceTypeText)")
                    let distanceSourceText = distanceSources.map { "\($0.label)=\(String(format: "%.2f", $0.value))m" }.joined(separator: ", ")
                    print("   Distance Sources: \(distanceSourceText)")
                    print("   🔒 Distance (DISPLAYED): \(String(format: "%.2f", displayedDistance))m (\(String(format: "%.2f", displayedDistance/1000))km)")
                    print("   🔒 Distance (METRICS): \(String(format: "%.2f", self.currentMetrics.totalDistance))m (\(String(format: "%.2f", self.currentMetrics.totalDistance/1000))km)")
                    print("   Active Energy: \(String(format: "%.0f", activeEnergyValue))kcal")
                    print("   Resting Energy: \(String(format: "%.0f", basalEnergyValue))kcal")
                    print("   Start: \(self.flight.startDate)")
                    print("   End: \(endDate)")
                    print("   Duration: \(String(format: "%.1f", endDate.timeIntervalSince(self.flight.startDate)))s")

                    // SAFETY: Add timeout for builder operations (30 seconds)
                    var didComplete = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
                        guard let self = self else { return }
                        if !didComplete {
                            print("⏱️ TIMEOUT: HealthKit builder operations took too long - using fallback save")
                            didComplete = true
                            self.fallbackSaveToHealthKit(locations: locationsForHealthKit, endDate: endDate) { success in
                                completion(success)
                            }
                        }
                    }

                    // Add samples BEFORE ending collection
                    builder.add(samples) { samplesSuccess, samplesError in
                        guard !didComplete else {
                            print("⚠️ Builder operation already timed out - skipping")
                            return
                        }

                        if !samplesSuccess {
                            print("⚠️ Failed to add distance/energy samples: \(samplesError?.localizedDescription ?? "Unknown")")
                            print("⚠️ Builder sample add failed - switching to fallback save")
                            didComplete = true
                            self.fallbackSaveToHealthKit(locations: locationsForHealthKit, endDate: endDate) { success in
                                completion(success)
                            }
                            return
                        }

                        print("✅ Distance and energy samples added successfully to builder")

                        // Now end collection
                        builder.endCollection(withEnd: endDate) { [weak self] success, error in
                            guard !didComplete else {
                                print("⚠️ Builder operation already timed out - skipping")
                                return
                            }
                            guard let self = self else { return }

                            if success {
                                // Finalize workout
                                builder.finishWorkout { workout, error in
                                    guard !didComplete else {
                                        print("⚠️ Builder operation already timed out - skipping")
                                        return
                                    }

                                    if let workout = workout {
                                        didComplete = true // Mark as completed successfully
                                        self.flight.workoutUUID = workout.uuid
                                        FlightDataStore.shared.updateWorkoutUUID(for: self.flight.id, workoutUUID: workout.uuid)
                                        let signature = FlightDataStore.shared.resyncSignature(for: self.flight)
                                        FlightDataStore.shared.markResynced(flightID: self.flight.id, signature: signature)
                                        print("✅ Workout finished successfully")
                                        print("   Workout UUID: \(workout.uuid)")
                                        print("   Workout Type: \(workout.workoutActivityType.rawValue)")
                                        print("   Start Date: \(workout.startDate)")
                                        print("   End Date: \(workout.endDate)")
                                        print("   Duration: \(String(format: "%.1f", workout.duration))s")

                                        // Get distance and calories from workout statistics
                                        let distance = workout.totalDistance?.doubleValue(for: .meter()) ?? 0
                                        let calories = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0

                                        print("📊 HealthKit calculated values:")
                                        print("   Total distance: \(String(format: "%.2f", distance/1000))km (\(distance)m)")
                                        print("   Total calories: \(String(format: "%.0f", calories))kcal")

                                        if distance == 0 {
                                            print("⚠️⚠️⚠️ WARNING: HealthKit workout has ZERO distance!")
                                            print("   This will show as 0:00 or just duration in Fitness app")
                                            print("   We added: \(self.currentMetrics.totalDistance)m")
                                        }

                                        if workout.duration == 0 {
                                            print("⚠️⚠️⚠️ WARNING: HealthKit workout has ZERO duration!")
                                        }

                                        // Save route to the existing workout (~1 point per second from iOS GPS)
                                        // Note: saveRoute() processes in batches to manage memory efficiently
                                        print("🗺️ Preparing to save route with \(locationsForHealthKit.count) locations (~1Hz)")
                                        self.healthKitManager.saveRoute(
                                            for: workout,
                                            locations: locationsForHealthKit
                                        ) { success, error in
                                            if success {
                                                print("✅ Workout route saved to HealthKit - will appear in Fitness app")
                                            } else {
                                                print("❌ Failed to save workout route: \(error?.localizedDescription ?? "Unknown")")
                                            }
                                            completion(success)
                                        }
                                    } else {
                                        print("❌ Failed to finish workout: \(error?.localizedDescription ?? "Unknown")")
                                        didComplete = true
                                        self.fallbackSaveToHealthKit(locations: locationsForHealthKit, endDate: endDate) { success in
                                            completion(success)
                                        }
                                    }
                                }
                            } else {
                                print("❌ Failed to end collection: \(error?.localizedDescription ?? "Unknown")")
                                didComplete = true
                                self.fallbackSaveToHealthKit(locations: locationsForHealthKit, endDate: endDate) { success in
                                    completion(success)
                                }
                            }
                        }
                    }
                }
            }
        }
        #endif
    }

    #if !targetEnvironment(simulator)
    private func fallbackSaveToHealthKit(
        locations: [FlightLocation],
        endDate: Date,
        completion: @escaping (Bool) -> Void
    ) {
        print("📊 Saving workout to HealthKit with fresh builder...")
        print("💡 This avoids Error(7) state by creating builder only when needed")

        // Don't check authorization again - just attempt the save
        // Excessive authorization checks cause Error(7) state machine failures
        self.healthKitManager.saveWorkoutDirectly(
            flight: self.flight,
            locations: locations,
            metrics: self.currentMetrics
        ) { success, error, workout in
            if let workout = workout {
                self.flight.workoutUUID = workout.uuid
                FlightDataStore.shared.updateWorkoutUUID(for: self.flight.id, workoutUUID: workout.uuid)
                let signature = FlightDataStore.shared.resyncSignature(for: self.flight)
                FlightDataStore.shared.markResynced(flightID: self.flight.id, signature: signature)
            }
            if success {
                print("✅ Fallback workout saved to HealthKit")
            } else {
                if let error = error as NSError? {
                    print("❌ Fallback HealthKit save failed: \(error.localizedDescription)")
                    print("   Error domain: \(error.domain), code: \(error.code)")
                    if !error.userInfo.isEmpty {
                        print("   UserInfo: \(error.userInfo)")
                    }
                } else {
                    print("❌ Fallback HealthKit save failed: error is nil")
                }
                print("")
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                print("⚠️  HEALTHKIT SAVE ERROR")
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                print("")
                print("Your workout data is SAFE - it's saved locally.")
                print("You can view it in the app and export as GPX.")
                print("")
                print("If you want to save to HealthKit:")
                print("1. Restart the app completely (swipe up to quit)")
                print("2. Open the Health app")
                print("3. Try recording a new workout")
                print("")
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            }
            completion(success)
        }
    }
    #endif

    private func calculateTotalDistance(from locations: [FlightLocation]) -> Double {
        guard locations.count > 1 else { return 0 }

        let isFlight = workoutType == .other
        let maxJump = isFlight ? 2000.0 : 1000.0
        let maxAccuracy = 1000.0

        var totalDistance: Double = 0
        for i in 1..<locations.count {
            let current = locations[i]
            let previous = locations[i - 1]

            guard current.horizontalAccuracy >= 0,
                  previous.horizontalAccuracy >= 0,
                  current.horizontalAccuracy <= maxAccuracy,
                  previous.horizontalAccuracy <= maxAccuracy else {
                continue
            }

            let distance = current.distance(to: previous)
            if distance <= maxJump {
                totalDistance += distance
            }
        }

        return totalDistance
    }

    /// Integrate the world-frame acceleration VECTOR into a velocity VECTOR at the sensor
    /// rate. Called from LocationManager.onWorldAccelSample. Signed integration means
    /// braking subtracts and bumps cancel; a gated bias estimator bounds drift (it learns
    /// ONLY while there is no real acceleration, so it never absorbs genuine motion).
    private func integrateWorldAccelSample(north: Double, east: Double, up: Double,
                                           rotationRate: Double, dt: TimeInterval) {
        guard isActive, !isPaused else { return }
        // Light low-pass, time-constant corrected. A fixed 0.7/0.3 blend means a completely
        // different corner frequency at 2Hz than at 50Hz, so the filter changed character
        // whenever the sample rate was switched. Deriving alpha from dt keeps it constant.
        let tau = 0.15
        let alpha = min(dt / (tau + dt), 1.0)
        worldAccelNorth += (north - worldAccelNorth) * alpha
        worldAccelEast += (east - worldAccelEast) * alpha
        guard isUsingEstimatedLocationFallback || forceMotionFallback else { return }

        let rN = worldAccelNorth - accelBiasNorth
        let rE = worldAccelEast - accelBiasEast

        // Feed the walking-axis PCA window (world frame ⇒ independent of device orientation).
        walkAccelWindow.append((north: rN, east: rE))
        if walkAccelWindow.count > WALK_WINDOW_SAMPLES { walkAccelWindow.removeFirst() }

        // --- Stationarity detection over a sliding window ---------------------------------
        // Use the FULL 3-axis residual plus the gyro: a device at rest is quiet on every
        // axis and is not rotating. Judging by horizontal magnitude alone would call a
        // smooth constant-speed cruise "stationary" and destroy the velocity.
        let sampleTime = (zuptWindow.last?.t ?? 0) + dt
        let accelMag3D = sqrt(rN * rN + rE * rE + up * up)
        zuptWindow.append((t: sampleTime, accel: accelMag3D, rotation: rotationRate))
        // Trimming keeps only samples INSIDE the window, so the retained span is always a
        // little SHORTER than ZUPT_WINDOW and a `span >= ZUPT_WINDOW` test would never pass
        // (verified in simulation: the detector fired on 0.0% of samples). Having trimmed at
        // all is the correct proof that a full window of history has accumulated.
        while let first = zuptWindow.first, sampleTime - first.t > ZUPT_WINDOW {
            zuptWindow.removeFirst()
            zuptWindowFilled = true
        }
        // Judge on the PEAK rather than the mean so a single real movement inside the window
        // vetoes the ZUPT.
        let peakAccel = zuptWindow.map(\.accel).max() ?? 0
        let peakRotation = zuptWindow.map(\.rotation).max() ?? 0
        // CRITICAL for cruise (aircraft, highway): a body coasting at constant velocity has
        // ~zero acceleration and ~zero rotation — identical to being parked. ZUPT alone
        // cannot tell them apart and was zeroing real cruise velocity, so a plane at 900 km/h
        // read as stopped. Only treat low accel + low rotation as STOPPED when the current
        // SPEED is also low; otherwise it is coasting and velocity is HELD (v = v₀ + a·dt with
        // a ≈ 0 keeps v₀), exactly as physics requires.
        let currentSpeed = sqrt(motionVelNorth * motionVelNorth + motionVelEast * motionVelEast)
        // "Recently moving fast" latch. The classifier frequently reports UNKNOWN ([?] in the
        // status line), and treating unknown as "not driving" let the quiet tiers zero the
        // speed mid-drive — gentle acceleration away from a stop is quiet AND below the speed
        // gate, so the estimate was repeatedly reset and stayed near zero while the car
        // actually reached 40 km/h. Something that was doing 20+ km/h seconds ago has not
        // genuinely stopped unless the classifier positively says so.
        if currentSpeed > 5.5 { lastFastMotionTime = Date() }
        let recentlyFast = lastFastMotionTime.map { Date().timeIntervalSince($0) < 12.0 } ?? false
        let drivingNow = (activityIsAutomotive || recentlyFast) && !isDeviceStationaryByActivity
        // TIER 1 (normal stop): brief quiet + already slow ⇒ stopped.
        let softStationary = !drivingNow
            && zuptWindowFilled
            && peakAccel < ZUPT_ACCEL_THRESHOLD
            && peakRotation < ZUPT_ROTATION_THRESHOLD
            && currentSpeed < ZUPT_MAX_SPEED
        // TIER 2 (prolonged stillness): the speed gate alone left a hole — while genuinely
        // standing still the estimate can DRIFT above the gate (observed: 13 km/h) and then
        // ZUPT could never pull it back. So when the device is VERY quiet for a sustained
        // period it is zeroed REGARDLESS of the drifted speed: 2 s of near-total stillness
        // cannot occur while actually moving (even a smooth cruise has engine/road vibration),
        // whereas a hand-held phone standing still easily clears it.
        if peakAccel < HARD_ZUPT_ACCEL && peakRotation < HARD_ZUPT_ROTATION {
            hardQuietDuration += dt
        } else {
            hardQuietDuration = 0
        }
        // While Apple's classifier says AUTOMOTIVE and not stationary, we are demonstrably
        // moving in a vehicle, so no amount of quiet means "stopped" — a smooth cruise on a
        // good road is quiet. Inhibiting the quiet-based tiers here removes the 0 km/h
        // readings that appeared while actually driving.
        let hardStationary = !drivingNow && hardQuietDuration >= HARD_ZUPT_WINDOW
        // Apple's activity classifier is authoritative about being STATIONARY, and it does not
        // care what the integrated speed says. Without it a diverged estimate was unrecoverable:
        // soft-ZUPT needs speed < 5 m/s (it was 93) and hard-ZUPT needs accel < 0.15 (engine
        // idle exceeds it), so 336 km/h persisted while parked. This breaks that trap.
        isInertialStationary = softStationary || hardStationary || isDeviceStationaryByActivity

        if isInertialStationary {
            // Truly at rest: the velocity IS zero, so assert it rather than nudging it, and
            // use this known-good moment to re-learn the bias quickly.
            motionVelNorth = 0
            motionVelEast = 0
            accelBiasNorth += rN * ZUPT_BIAS_RATE
            accelBiasEast += rE * ZUPT_BIAS_RATE
            prevResidualNorth = 0
            prevResidualEast = 0
            return
        }

        // VERTICAL-MOTION GUARD (elevators, lifts, stairs).
        //
        // An elevator produces LARGE genuine vertical acceleration and no horizontal motion.
        // Any small attitude error leaks a fraction of that vertical signal into the
        // horizontal axes, and ZUPT cannot suppress it because the 3-axis residual really is
        // large — so the leakage was integrated into phantom horizontal speed and drawn as a
        // long straight run (observed: a 0.41 km walk rendered with a segment longer than the
        // entire recorded distance).
        //
        // The discriminator is dominance: when the vertical residual clearly exceeds the
        // horizontal one, the horizontal part is leakage rather than travel, so it must not be
        // integrated. Real walking or driving is the opposite — horizontal dominates.
        let horizontalResidual = sqrt(rN * rN + rE * rE)
        if abs(up) > 0.3 && abs(up) > 2.5 * horizontalResidual {
            prevResidualNorth = 0
            prevResidualEast = 0
            return
        }

        // VIOLENT-ROTATION GUARD: when the device is whipped around, the attitude estimate
        // lags and GRAVITY leaks into the "horizontal" axes, which integrates into absurd
        // speed. Freeze integration only for genuinely violent rotation.
        //
        // THRESHOLD HISTORY: this was 1.5 rad/s, which broke recording entirely — ordinary
        // WALKING (arm swing, body sway, phone shifting in a pocket) routinely exceeds
        // 1.5 rad/s, so integration froze on nearly every sample, velocity never built, and
        // no route point ever cleared the append threshold. Body motion runs ~1–3 rad/s, so
        // the freeze must sit above that; the residual clamp below does the everyday
        // spike-bounding work.
        if rotationRate > 4.0 {
            prevResidualNorth = 0
            prevResidualEast = 0
            return
        }

        // LONG-WINDOW MEAN REMOVAL — the constraint that actually bounds a vehicle.
        //
        // Over a long window the mean horizontal acceleration of ANY vehicle is ~0: sustained
        // acceleration would imply impossible speed (1 m/s² held for 60 s is already
        // 216 km/h). So the long-run mean IS the sensor bias plus gravity leakage, and it can
        // be removed UNCONDITIONALLY. The gated estimator below cannot do this in a car: it
        // freezes whenever the residual exceeds the gate, which in traffic (accelerating,
        // braking, hills, turns) is most of the time — so the leakage was never cancelled and
        // integrated without bound (observed: 871 km/h in a car).
        //
        // Time constant is long (~90 s) so a genuine acceleration burst (a launch lasting a
        // few seconds) passes through nearly untouched, while any persistent offset is
        // absorbed. This is a high-pass on acceleration, which is exactly what unaided
        // inertial navigation needs to stay bounded.
        // Kept at 90 s deliberately. A shorter window was TESTED and is clearly worse: at 20 s
        // it absorbs the vehicle's own acceleration bursts (a typical 8 s pull-away), and the
        // simulated drive-cycle error rose from 2.7 to 27.9 km/h mean. Long window only.
        let meanTau = 90.0
        let meanAlpha = min(dt / (meanTau + dt), 1.0)
        longRunMeanNorth += (worldAccelNorth - longRunMeanNorth) * meanAlpha
        longRunMeanEast += (worldAccelEast - longRunMeanEast) * meanAlpha

        // Moving: keep learning the bias whenever residual acceleration is small (this is what
        // cancels gravity leakage during a long cruise), but FREEZE it during genuine
        // acceleration or braking so it cannot absorb real motion.
        if sqrt(rN * rN + rE * rE) < MOTION_BIAS_GATE {
            accelBiasNorth += rN * MOTION_BIAS_RATE
            accelBiasEast += rE * MOTION_BIAS_RATE
        }

        // Trapezoidal integration — no leak, no damping, but the residual is CLAMPED to a
        // physical bound: no ground or air vehicle sustains |a| > 6 m/s² horizontally (a jet
        // takeoff is ~3), so anything larger is sensor/attitude noise and is clipped.
        func clamped(_ v: Double) -> Double { max(-4.0, min(4.0, v)) }
        // Subtract BOTH the gated bias and the long-run mean. The mean-removal is what keeps a
        // vehicle bounded when the gated estimator is frozen.
        // NOTE: no world-frame mean subtraction here. Bias and gravity leakage are removed in
        // the DEVICE frame (LocationManager.referenceFrameAcceleration), which is the only
        // frame where they are constant — a world-frame mean cannot cancel an error vector
        // that rotates every time the vehicle turns.
        let iN = clamped(worldAccelNorth - accelBiasNorth)
        let iE = clamped(worldAccelEast - accelBiasEast)
        motionVelNorth += ((prevResidualNorth + iN) / 2.0) * dt
        motionVelEast += ((prevResidualEast + iE) / 2.0) * dt
        prevResidualNorth = iN
        prevResidualEast = iE

        // NO SPEED CAP. A ceiling only hides divergence at the display and would clip a
        // genuinely fast aircraft; the estimate must be correct by construction (bias and
        // long-run-mean removal above), not clamped after the fact.
    }

    // MARK: - DEBUG: synthetic flight replay (simulator has no Core Motion)
    // The iOS Simulator cannot supply accelerometer/gyro/attitude, so Force Velocity gets no
    // input there. This replay pushes a synthesized flight's WORLD-frame acceleration straight
    // into the real integrateWorldAccelSample + estimated-fallback tick, so the reconstructed
    // route draws on the live map exactly as production would. Reached ONLY via the
    // `-replayFlight` launch argument — inert in normal use.
    private var debugReplayTimer: Timer?
    private var debugReplayT: Double = 0

    private func debugFlightHeadingSpeed(_ t: Double) -> (spd: Double, hdg: Double) {
        // (endTime, targetSpeed m/s, targetHeadingDeg); values ramp linearly within each leg.
        let legs: [(Double, Double, Double)] = [
            (8, 60, 90), (25, 60, 90),      // takeoff east, cruise east
            (33, 60, 180), (50, 60, 180),   // turn right to south, cruise south
            (58, 60, 90), (66, 60, 90),     // turn left to east, cruise east
        ]
        var prevEnd = 0.0, prevSpd = 0.0, prevHdg = 90.0
        for leg in legs {
            if t < leg.0 {
                let f = (t - prevEnd) / (leg.0 - prevEnd)
                var dh = leg.2 - prevHdg
                if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
                return (prevSpd + (leg.1 - prevSpd) * f, prevHdg + dh * f)
            }
            prevEnd = leg.0; prevSpd = leg.1; prevHdg = leg.2
        }
        return (prevSpd, prevHdg)
    }

    private func debugFlightVel(_ t: Double) -> (Double, Double) {
        let s = debugFlightHeadingSpeed(t)
        let h = s.hdg * .pi / 180
        return (s.spd * cos(h), s.spd * sin(h))
    }

    /// Synthetic world-frame (north, east) acceleration + turn rate at time t, with a small
    /// vibration term so the ZUPT detector behaves as it would in a real (never perfectly
    /// still) aircraft rather than false-triggering during smooth cruise.
    private func debugFlightSample(_ t: Double) -> (north: Double, east: Double, rot: Double) {
        let dh = 0.05
        let a = debugFlightVel(t + dh), b = debugFlightVel(t - dh)
        let aN = (a.0 - b.0) / (2 * dh), aE = (a.1 - b.1) / (2 * dh)
        let vib = 0.32
        let noiseN = vib * sin(t * 37.0), noiseE = vib * cos(t * 41.0)
        let hs0 = debugFlightHeadingSpeed(t - dh), hs1 = debugFlightHeadingSpeed(t + dh)
        var dHdg = (hs1.hdg - hs0.hdg)
        if dHdg > 180 { dHdg -= 360 } else if dHdg < -180 { dHdg += 360 }
        let turnRate = abs(dHdg * .pi / 180 / (2 * dh)) + 0.02
        return (aN + noiseN, aE + noiseE, turnRate)
    }

    func debugReplaySyntheticFlight() {
        guard !isActive else { return }
        print("🧪 DEBUG: synthetic flight replay starting (simulator has no Core Motion)")
        workoutType = .other
        let startDate = Date()
        flight = Flight(startDate: startDate)
        flight.workoutType = workoutType.rawValue
        isActive = true
        isPaused = false
        lastRealLocationTime = startDate
        lastGoodAccuracyFixTime = .distantPast
        pendingUnanchoredMovement = []
        lastEstimatedAppendTime = Date()

        // Seed a real starting fix so the estimated points have an anchor to project from.
        let seed = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5645),
            altitude: 3000, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 90, speed: 0, timestamp: startDate)
        flight.locations.append(FlightLocation(from: seed, isValid: true))

        forceMotionFallback = true
        resetInertialState(seedSpeed: 0, courseDegrees: 90)
        // Begin the fallback explicitly so the 1 Hz tick does not re-seed velocity to zero.
        startEstimatedLocationFallback(anchor: flight.locations.last, gapSeconds: 0)
        startEstimatedFallbackTimer()
        NotificationCenter.default.post(name: .workoutDidStart, object: nil)

        debugReplayT = 0
        debugReplayTimer?.invalidate()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let s = self.debugFlightSample(self.debugReplayT)
            self.integrateWorldAccelSample(north: s.north, east: s.east, up: 0,
                                           rotationRate: s.rot, dt: 0.02)
            self.debugReplayT += 0.02
            if self.debugReplayT >= 66 {
                self.debugReplayTimer?.invalidate(); self.debugReplayTimer = nil
                print("🧪 DEBUG replay complete: \(self.flight.locations.count) pts, " +
                      "\(String(format: "%.2f", self.currentMetrics.totalDistance / 1000))km")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        debugReplayTimer = timer
    }

    /// Learn the offset between the phone's magnetic heading and the actual direction of
    /// travel, using GPS course over ground as the truth. Course is the real travel direction,
    /// so this is both more reliable than gait and — unlike the PCA walking axis — available in
    /// a vehicle, where there are no steps.
    ///
    /// Must be called on BOTH the normal and the Force Velocity paths; see the call site in
    /// processNewLocation for what happened when it only ran on one.
    private func learnCompassMisalignment(from location: FlightLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 20,
              location.speed > 2.0,
              let course = validCourse(location.course),
              let compass = locationManager.currentCompassHeading else { return }
        var offset = course - compass
        if offset > 180 { offset -= 360 } else if offset < -180 { offset += 360 }
        if let existing = compassMisalignment {
            var delta = offset - existing
            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
            compassMisalignment = existing + 0.1 * delta
        } else {
            compassMisalignment = offset
            // First time the true travel direction is known: fix the stretch that was drawn
            // from a compass-seeded (device-orientation) heading.
            correctUntrustedHeadingPrefix(trueHeadingNow: course)
        }
    }

    /// Rotate the opening run of estimated points that was laid down before the true travel
    /// direction was known.
    ///
    /// When Force Velocity is engaged while stationary there is no GPS course, so the heading
    /// seeds from the compass — device orientation, not travel. Every point until the offset is
    /// learned is therefore drawn rotated by one CONSTANT error, which is exactly what makes it
    /// correctable: rotating that run about its anchor by the now-known difference restores the
    /// real shape instead of leaving the route starting off in the wrong direction.
    private func correctUntrustedHeadingPrefix(trueHeadingNow: Double) {
        guard let start = untrustedHeadingPrefixStart,
              let seedHeading = untrustedSeedHeading,
              start > 0, flight.locations.count > start else {
            untrustedHeadingPrefixStart = nil
            return
        }
        var rotation = trueHeadingNow - seedHeading
        if rotation > 180 { rotation -= 360 } else if rotation < -180 { rotation += 360 }
        // A tiny correction is not worth rewriting history for.
        guard abs(rotation) > 5 else { untrustedHeadingPrefixStart = nil; return }

        let anchor = flight.locations[start - 1]
        let anchorLat = anchor.latitude, anchorLon = anchor.longitude
        let cosLat = max(cos(anchorLat * .pi / 180), 0.000001)
        let radians = rotation * .pi / 180
        let cosR = cos(radians), sinR = sin(radians)

        for index in start..<flight.locations.count {
            let point = flight.locations[index]
            // Offsets from the anchor in metres (north, east).
            let north = (point.latitude - anchorLat) * 111_320.0
            let east = (point.longitude - anchorLon) * 111_320.0 * cosLat
            // Rotate clockwise by `rotation` in the compass sense (north toward east).
            let rotatedNorth = north * cosR - east * sinR
            let rotatedEast = north * sinR + east * cosR
            flight.locations[index] = point.movedHorizontally(north: rotatedNorth - north,
                                                              east: rotatedEast - east)
        }
        print("📍 🧭 Rotated \(flight.locations.count - start) early points by \(Int(rotation))° once true heading was known")
        untrustedHeadingPrefixStart = nil
        untrustedSeedHeading = nil
    }

    /// Angular distance between two bearings, 0…180.
    private func angularDistance(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d
    }

    /// Walking axis (degrees from north, modulo 180) from the principal component of recent
    /// WORLD-frame horizontal acceleration. World-frame acceleration has device orientation
    /// already removed, so this measures how the BODY is moving, not how the device is held.
    ///
    /// Returns nil unless the principal axis is clearly dominant: when lateral sway rivals
    /// the forward push the axis is meaningless, and on a wrist (arm swing dominant) it comes
    /// out roughly perpendicular to the true direction. Better to return nothing than a
    /// confident right angle.
    private func walkingAxisHeading() -> Double? {
        guard walkAccelWindow.count >= 40 else { return nil }
        let n = Double(walkAccelWindow.count)
        let meanN = walkAccelWindow.reduce(0.0) { $0 + $1.north } / n
        let meanE = walkAccelWindow.reduce(0.0) { $0 + $1.east } / n
        var cnn = 0.0, cee = 0.0, cne = 0.0
        for s in walkAccelWindow {
            let dn = s.north - meanN, de = s.east - meanE
            cnn += dn * dn; cee += de * de; cne += dn * de
        }
        // Eigenvalues of the 2x2 covariance matrix.
        let trace = cnn + cee
        let det = cnn * cee - cne * cne
        let disc = max(trace * trace / 4 - det, 0)
        let lambda1 = trace / 2 + sqrt(disc)
        let lambda2 = trace / 2 - sqrt(disc)
        guard lambda1 > 0, lambda2 >= 0 else { return nil }
        // Require the principal axis to carry clearly more variance than the orthogonal one.
        guard lambda1 / max(lambda2, 1e-9) >= 4.0 else { return nil }
        var deg = 0.5 * atan2(2 * cne, cnn - cee) * 180 / .pi
        if deg < 0 { deg += 360 }

        // RESOLVE WHICH END IS FORWARD, from the gait itself.
        //
        // PCA yields an AXIS, and previously the forward end was chosen as whichever was
        // closer to the heading already believed. That is self-reinforcing: if the belief
        // starts 180° wrong, the wrong end is chosen, the belief is "confirmed", and the
        // misalignment locks the inversion in for the whole workout — the reported symptom
        // that the route needs turning 180° to be right.
        //
        // Human gait is ASYMMETRIC along the direction of travel: push-off is a sharper, larger
        // acceleration than the gentler braking of heel-strike, so acceleration projected onto
        // the travel axis is positively SKEWED toward forward. The sign of the third moment
        // therefore identifies forward independently of any prior belief.
        let axisRad = deg * .pi / 180
        let ux = cos(axisRad), uy = sin(axisRad)
        var m2 = 0.0, m3 = 0.0
        for sample in walkAccelWindow {
            let projection = (sample.north - meanN) * ux + (sample.east - meanE) * uy
            m2 += projection * projection
            m3 += projection * projection * projection
        }
        let variance = m2 / n
        guard variance > 1e-6 else { return nil }
        let skewness = (m3 / n) / pow(variance, 1.5)

        // SMOOTH the forward/back vote across calls instead of deciding from one window alone.
        // walkAccelWindow spans ~1.6 s — only 2-3 steps — so its skewness is noisy, and this
        // function is re-evaluated roughly once a tick. Trusting the raw instantaneous sign let
        // the resolved axis flip 180° for a tick or two whenever noise pushed it past the bar,
        // which is exactly what turned a straight walked line into the tangled, doubling-back
        // loop seen live: the drawn path is correct in total DISTANCE but keeps reversing which
        // end is "forward" for a few ticks at a time. An EMA needs sustained, one-sided evidence
        // before the belief moves, so an isolated noisy window can no longer flip it alone.
        if walkingSkewEMAValid {
            walkingSkewEMA += (skewness - walkingSkewEMA) * 0.12
        } else {
            walkingSkewEMA = skewness
            walkingSkewEMAValid = true
        }
        // Only trust a clear, SUSTAINED asymmetry; ambiguous gait leaves the axis unresolved
        // rather than guessing, so a wrong 180° choice is never forced.
        guard abs(walkingSkewEMA) > 0.15 else { return nil }
        if walkingSkewEMA < 0 { deg = (deg + 180).truncatingRemainder(dividingBy: 360) }
        return deg
    }

    private func resetInertialState(seedSpeed: Double, courseDegrees: Double) {
        let c = courseDegrees * .pi / 180
        motionVelNorth = seedSpeed * cos(c)
        motionVelEast = seedSpeed * sin(c)
        motionHeadingDegrees = courseDegrees
        accelBiasNorth = 0; accelBiasEast = 0
        prevResidualNorth = 0; prevResidualEast = 0
        zuptWindow.removeAll()
        zuptWindowFilled = false
        isInertialStationary = false
        longRunMeanNorth = 0
        longRunMeanEast = 0
    }

    private func startEstimatedFallbackTimer() {
        stopEstimatedFallbackTimer()
        estimatedFallbackTimer = Timer.scheduledTimer(withTimeInterval: ESTIMATED_LOCATION_TICK_INTERVAL, repeats: true) { [weak self] _ in
            self?.checkEstimatedLocationFallback()
        }
        RunLoop.main.add(estimatedFallbackTimer!, forMode: .common)
        print("📍 Estimated-location fallback timer started")
    }

    private func stopEstimatedFallbackTimer() {
        estimatedFallbackTimer?.invalidate()
        estimatedFallbackTimer = nil
        if isUsingEstimatedLocationFallback {
            endEstimatedLocationFallback(reason: "workout stopped")
        }
    }

    private func checkEstimatedLocationFallback() {
        guard isActive && !isPaused else { return }
        // High motion sample rate only while forced (thermal-friendly otherwise).
        locationManager.setHighRateMotion(forceMotionFallback)

        let anchor = flight.locations.last(where: { !$0.isEstimated && $0.isValid })
        let timeSinceRealFix = Date().timeIntervalSince(lastRealLocationTime)

        // MANUAL OVERRIDE: when the user forces velocity mode, dead reckoning runs
        // UNCONDITIONALLY — it does not wait for a GPS gap. GPS is ignored for distance
        // while forced (see processNewLocation), so there is no double-counting.
        if !forceMotionFallback {
            // NOTE: deliberately NOT requiring a prior real GPS fix. A workout that begins
            // with no GPS at all (already airborne, basement, airplane mode) has no anchor,
            // and the old `guard anchor != nil` meant dead reckoning NEVER engaged — the
            // exact case where it is needed most. appendEstimatedLocation seeds a synthetic
            // anchor from the last-known position instead (mirrors the watch).
            guard timeSinceRealFix >= ESTIMATED_LOCATION_GAP_THRESHOLD else {
                if isUsingEstimatedLocationFallback {
                    endEstimatedLocationFallback(reason: "GPS returned")
                }
                return
            }
        }

        if !isUsingEstimatedLocationFallback {
            startEstimatedLocationFallback(anchor: anchor, gapSeconds: timeSinceRealFix)
        }

        let now = Date()
        let previousTick = lastEstimatedFallbackTick ?? now.addingTimeInterval(-ESTIMATED_LOCATION_TICK_INTERVAL)
        let dt = min(max(now.timeIntervalSince(previousTick), 0.5), 2.0)
        lastEstimatedFallbackTick = now

        // The velocity VECTOR is integrated at sensor rate in integrateWorldAccelSample,
        // which also owns drift correction via ZUPT. There is deliberately NO velocity leak
        // and no settle-to-rest damping here any more: both decayed genuine cruise speed
        // (which has ~zero acceleration and is indistinguishable from drift by magnitude
        // alone) and caused distance to be systematically under-reported.
        // NO speed cap — speed is simply the magnitude of the velocity vector.
        let nextSpeed = sqrt(motionVelNorth * motionVelNorth + motionVelEast * motionVelEast)
        // Whether steps are genuinely being counted right now (drives both the heading source
        // and the distance source); computed before the heading block that consumes it.
        // LONG window: CMPedometer updates are sparse, so 5 s dropped us into integration
        // between them. 20 s keeps us in the pedometer branch across the gaps.
        // How much the device is being turned, smoothed over a few seconds so a single knock or
        // a car's turn does not trip it but continuous handling does.
        if let rr = locationManager.currentRotationRate {
            handlingRotationLevel += (rr - handlingRotationLevel) * min(dt / (3.0 + dt), 1.0)
        }

        let pedometerIsCounting = lastStepIncrementTime.map { now.timeIntervalSince($0) < 20.0 } ?? false
        // A fresh bout of walking (after standing still, turning around, sitting down, etc.)
        // gets a fresh forward/back vote instead of carrying over a belief that may no longer
        // apply — the body could easily now be walking the opposite way relative to the axis.
        if pedometerIsCounting, !wasPedometerCountingForSkewReset {
            walkingSkewEMAValid = false
        }
        wasPedometerCountingForSkewReset = pedometerIsCounting
        let velHeading = nextSpeed > 0.1
            ? normalizedHeading(atan2(motionVelEast, motionVelNorth) * 180 / .pi)
            : nil

        // HEADING. Device ORIENTATION is deliberately NOT used as a proxy for direction of
        // travel: nothing keeps a phone in a pocket, a phone in a hand, or a watch on a
        // swinging wrist at a fixed angle to the body, so "travel = device yaw + offset" is
        // an invalid assumption (it produced confidently wrong routes). Heading is derived
        // only from measurements of MOTION, in priority order:
        //
        //   1. Velocity vector — valid when there is genuine sustained acceleration
        //      (vehicle pulling away, aircraft takeoff/turn).
        //   2. PCA of world-frame horizontal acceleration while stepping — the walking axis.
        //      World-frame acceleration already has device orientation removed, so this is
        //      independent of how the device is carried. Gated on a confidence check because
        //      it is only trustworthy when the forward push dominates lateral sway: measured
        //      ~1° error for a trunk/pocket carry, but ~88° (perpendicular) on a wrist where
        //      arm swing dominates.
        //   3. Otherwise hold the last known course rather than inventing a direction.
        let rNh = worldAccelNorth - accelBiasNorth
        let rEh = worldAccelEast - accelBiasEast
        let horizAccelMag = sqrt(rNh * rNh + rEh * rEh)

        var resolvedHeading: Double? = nil
        // The velocity vector is only "trustworthy" if the velocity itself is plausible. When
        // the integrator has diverged (observed: 336 km/h with the car barely moving) this
        // branch fed garbage heading AND bypassed the compass correction below, which is why
        // the computed heading sat 90° from the compass. Require a sane speed too.
        // The velocity-vector heading is NOT used as an absolute reference. It is derived from
        // the integrated velocity, which this mode has repeatedly shown to diverge, and it
        // OVERWROTE the heading every tick — the compass correction below could only nudge it
        // 8% before being replaced again, which is why the recorded heading sat ~45° (once
        // 205°) from the compass indefinitely. Direction now comes from the gyro for turns and
        // the compass for the absolute datum, exactly as the PDR literature prescribes.
        do {
            // COMPLEMENTARY FILTER. Turn ANGLE comes from the gyro, absolute direction from
            // PCA. Previously heading was taken straight from the PCA axis, but that axis is
            // computed over a ~3 s window, so during a turn it averages acceleration from
            // before AND after — turns came out shallow and late, and the confidence gate
            // froze the heading mid-turn entirely.
            //
            // 1) Propagate by how far the DEVICE turned since the last tick. Attitude yaw is
            //    gyro-fused and absolute, so its DELTA is an accurate turn angle. This is a
            //    rotation measurement, not an assumption that the device points where you go.
            // Use the UNWRAPPED cumulative rotation, not a per-tick wrapped delta. A brisk
            // about-face turns ~180° within one tick, which the previous "implausible jump"
            // guard discarded outright — so reversals were never propagated and the 180°
            // ambiguity could not resolve. Sensor-rate accumulation makes a fast turn a run of
            // small deltas, so nothing legitimate is ever clipped.
            let cumulativeYaw = locationManager.cumulativeDeviceYawRotation
            var turningNow = false
            if let previousCumulative = lastDeviceYawForHeading {
                let dYaw = cumulativeYaw - previousCumulative
                motionHeadingDegrees = normalizedHeading(motionHeadingDegrees + dYaw)
                turningNow = abs(dYaw) > 8   // deg per tick — actively turning
            }
            lastDeviceYawForHeading = cumulativeYaw
            // 2) Pull slowly toward the PCA walking axis, which is absolute and orientation-
            //    independent. This removes the drift the gyro accumulates, without letting a
            //    slow window dictate fast turn dynamics. The axis's 180° ambiguity resolves
            //    against the now gyro-propagated heading, so reversals are still detected.
            // The PCA pull is SUSPENDED while actively turning: the axis is computed over a
            // trailing window, so mid-turn it still points at the pre-turn direction and the
            // pull dragged the heading BACKWARDS against the gyro — the visible turn lag.
            // Drift correction only needs the straight stretches, where the axis is honest.
            if !turningNow, pedometerIsCounting, let axis = walkingAxisHeading() {
                // walkingAxisHeading() now returns a DIRECTED heading (forward end resolved
                // from gait skewness), so it must NOT be re-resolved against the current
                // belief — doing that is what allowed a 180° error to persist.
                let target = axis
                var err = target - motionHeadingDegrees
                if err > 180 { err -= 360 } else if err < -180 { err += 360 }
                motionHeadingDegrees = normalizedHeading(motionHeadingDegrees + 0.25 * err)

                // LEARN THE MISALIGNMENT between the phone's magnetic heading and the actual
                // direction of travel. The compass measures where the PHONE points, not where
                // the BODY goes — in a pocket those differ by a large, roughly constant angle,
                // so correcting straight to the compass (build 37) reintroduced the very
                // device-orientation error this mode had to avoid. The PCA walking axis is a
                // true measurement of body travel, so their difference IS the misalignment,
                // and it is what makes the compass usable as an absolute datum.
                if let compass = locationManager.currentCompassHeading {
                    var offset = target - compass
                    if offset > 180 { offset -= 360 } else if offset < -180 { offset += 360 }
                    if let existing = compassMisalignment {
                        var delta = offset - existing
                        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                        compassMisalignment = existing + 0.1 * delta
                    } else {
                        compassMisalignment = offset
                    }
                }
            }

            // ABSOLUTE REFERENCE FROM THE COMPASS.
            //
            // The PDR literature is explicit that gyro + acceleration can only give RELATIVE
            // heading: "we do not address absolute heading angle but merely relative ones,
            // since the former requires additional information such as pedestrian forward
            // direction in the sensor frame" (Gravity-Based Methods for Heading Computation in
            // PDR). Integrated turn rate has no absolute datum, so any seed error — plus the
            // residual gyro drift — persists for the whole workout. That is why the recorded
            // direction stayed far from the compass (observed gaps of 40–80°) and whole routes
            // pointed the wrong way.
            //
            // The magnetometer supplies the missing absolute datum. It is noisy instantaneously
            // but has NO drift, which is the exact complement of the gyro: gyro for fast turns,
            // compass for the long-run truth. Correct slowly so it never fights a real turn,
            // and only while NOT turning (a turn swings the compass through its own transient).
            if !turningNow, let compass = locationManager.currentCompassHeading {
                let (misalignment, gain) = effectiveCompassMisalignment
                // Target = where the phone points PLUS how the body is offset from it.
                let target = normalizedHeading(compass + misalignment)
                var err = target - motionHeadingDegrees
                if err > 180 { err -= 360 } else if err < -180 { err += 360 }
                motionHeadingDegrees = normalizedHeading(motionHeadingDegrees + gain * err)
            }
            resolvedHeading = motionHeadingDegrees
        }
        if let rh = resolvedHeading { motionHeadingDegrees = rh }
        // ABSOLUTE DATUM, ALWAYS. Applied outside the branches above so a diverged velocity
        // vector can never lock the heading away from the only drift-free reference we have.
        if let compass = locationManager.currentCompassHeading {
            let (misalignment, gain) = effectiveCompassMisalignment
            let target = normalizedHeading(compass + misalignment)
            var err = target - motionHeadingDegrees
            if err > 180 { err -= 360 } else if err < -180 { err += 360 }
            motionHeadingDegrees = normalizedHeading(motionHeadingDegrees + gain * err)
            resolvedHeading = motionHeadingDegrees
        }
        // NOTE: the velocity vector no longer snaps the heading either. It is a product of the
        // integrated velocity, so when that diverges it dragged the heading away from the
        // compass every tick and the correction could never win.

        let headingDegrees = resolvedHeading
            ?? normalizedHeading(
                // Prefer GPS COURSE (true direction of travel) over the compass: inside a
                // vehicle — especially an aircraft — the magnetometer reads the metal shell
                // and local EMI, not the heading, so course-over-ground is far more reliable.
                anchor.flatMap { validCourse($0.course) }
                    ?? locationManager.currentCompassHeading
                    ?? locationManager.currentMotionDirectionDegrees
                    ?? 0.0
              )

        // DISTANCE: pedometer for step activities (PDR — accurate to a few %), accelerometer
        // integration only for vehicle/flight where there are no steps to count.
        // Route by what the sensors ACTUALLY detect, never by the activity label: the user
        // selects "Walking" while sitting in an aircraft, where the pedometer counts zero
        // steps — routing on the label alone yields zero distance and NO TRACK.
        var distance: Double
        var sourceTag = "DR"
        // VEHICLE-LAUNCH DETECTOR. A car or aircraft pulling away produces a large horizontal
        // acceleration sustained for seconds; walking and handling never do. This is the
        // positive evidence that permits integration at all, and once seen it latches for the
        // trip so a cruising vehicle does not lose it.
        // Uses the magnitude of the MEAN acceleration VECTOR, not time spent above a magnitude
        // threshold. The previous version false-fired on WALKING: step peaks easily exceed
        // 1.0 m/s², and with a continuous vibration floor the magnitude rarely dips under the
        // 0.3 reset, so the timer accumulated and latched after ~3 s of walking — after which
        // integration ran unconditionally and reported 18 km/h for a walk and 261 km/h for a
        // car doing 20-30.
        //
        // The discriminator is DIRECTIONAL PERSISTENCE. Walking pushes and brakes about a mean
        // of ~zero, so a vector average cancels it. A vehicle pulling away accelerates one way
        // for seconds, so its vector average is large. Same peak magnitudes, opposite means.
        let launchAlpha = min(dt / (3.0 + dt), 1.0)
        launchMeanNorth += (rNh - launchMeanNorth) * launchAlpha
        launchMeanEast += (rEh - launchMeanEast) * launchAlpha
        launchWindowElapsed += dt
        if launchWindowElapsed > 6.0,
           sqrt(launchMeanNorth * launchMeanNorth + launchMeanEast * launchMeanEast) > 0.8 {
            vehicleLaunchDetected = true
        }

        // Route by DETECTED stepping, never the activity label: if the pedometer is counting
        // steps you are walking, and its stride-model distance is right, whereas integrating
        // walking acceleration diverges. Only a genuinely stepless vehicle/aircraft falls
        // through to integration.
        if pedometerIsCounting, let pedometerTotal = fallbackPedometerDistance {
            // PEDOMETER (walking). CMPedometer delivers updates SPARSELY (seconds to tens of
            // seconds apart), so the cumulative distance jumps when an update lands and holds
            // flat between. The DELTA is still exactly the distance walked since the last tick
            // that consumed it, so it is correct regardless of update timing. The `counting`
            // window is deliberately LONG (see pedometerIsCounting) so we stay in this branch
            // across the sparse updates instead of dropping into integration and diverging.
            // CATCH-UP toward the pedometer cumulative, CAPPED per tick. CMPedometer updates
            // land seconds-to-tens-of-seconds apart, so the raw delta is a big jump that, drawn
            // as one segment, became the long straight line ignoring the turns walked during
            // the gap. Instead bleed the "owed" distance off a little each tick along the
            // CURRENT gyro heading — the path curves — while the TOTAL still converges exactly
            // to the pedometer distance (unlike pure speed×dt, which under-counts).
            // DECAY the displayed speed toward 0 once cadence stops, independent of the sparse
            // pedometer callback. fallbackPedometerSpeed is only WRITTEN when a new CMPedometer
            // update lands (seconds to tens of seconds apart), so stopping mid-walk (e.g. to
            // stand still) held the last nonzero smoothed speed for up to the full 20 s
            // `pedometerIsCounting` grace window — reported live as "PDR [walk] 6km/h" while
            // genuinely stationary. That 20 s window exists to bridge sparse DISTANCE updates
            // and must stay long; the instantaneous SPEED shown has no reason to share it. A
            // real walking cadence is 1.5–3 steps/s, so any gap over ~1.2 s already means the
            // steps have stopped, well before the next pedometer callback would say so.
            let sinceLastStep = lastStepIncrementTime.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            if sinceLastStep > 1.2 {
                let decayAlpha = min(dt / (0.5 + dt), 1.0)
                fallbackPedometerSpeed += (0 - fallbackPedometerSpeed) * decayAlpha
            }
            lastFallbackPedometerDistance = pedometerTotal
            let owed = max(0, pedometerTotal - pdrAppendedDistance)
            let perTickCap = max(fallbackPedometerSpeed * dt * 1.5, 1.5)
            distance = min(owed, perTickCap)
            pdrAppendedDistance += distance
            estimatedFallbackSpeed = fallbackPedometerSpeed   // for the speed display
            // CRITICAL: keep the accelerometer integrator from diverging while walking. Its
            // velocity is unused for distance here, but if left to run it climbs to hundreds
            // of km/h and then dumps that in the instant stepping stops. Peg it to the real
            // pedometer speed along the current heading so exiting walking mode is seamless.
            let hr = motionHeadingDegrees * .pi / 180
            motionVelNorth = estimatedFallbackSpeed * cos(hr)
            motionVelEast = estimatedFallbackSpeed * sin(hr)
            sourceTag = "PDR"
        } else if vehicleContextIsCurrent, !deviceIsBeingHandled,
                  let vibrationDerived = vibrationSpeed.estimatedSpeed() {
            // VIBRATION-BASED SPEED (vehicle). Preferred over integration whenever the model
            // has been calibrated, because it does not accumulate: road and engine vibration
            // scale with speed, so this is a direct reading rather than an integral, and the
            // bias that makes integration diverge simply has nowhere to accumulate.
            //
            // Gated on vehicle evidence, the same bar integration itself already required: a
            // model trained on driving is shaped for driving vibration, and applying it to
            // ordinary footstep vibration (tag "[?]", pedometer not yet counting) read a real
            // walk at 40 km/h, average 94 km/h. Without this gate a genuinely uncertain moment
            // fell through to whatever the vibration model last said, however inapplicable.
            // Time-constant blend (~0.8 s) rather than a fixed 0.6/0.4 per tick, which added
            // ~2.5 s of lag on top of the estimator's own smoothing.
            let blend = min(dt / (0.8 + dt), 1.0)
            estimatedFallbackSpeed += (vibrationDerived - estimatedFallbackSpeed) * blend
            distance = estimatedFallbackSpeed * dt
            // "VIB?" = provisional fit (few samples / narrow speed range) — still far better
            // than integration, but expect the magnitude to be rough until it firms up to "VIB".
            sourceTag = vibrationSpeed.isProvisional ? "VIB?" : "VIB"
            // Keep the integrator pegged so it cannot diverge in the background and reappear.
            let hr = motionHeadingDegrees * .pi / 180
            motionVelNorth = estimatedFallbackSpeed * cos(hr)
            motionVelEast = estimatedFallbackSpeed * sin(hr)
        } else {
            // NO TRUSTWORTHY SOURCE. Report nothing rather than invent a number.
            //
            // Raw double-integration of acceleration used to fill this gap, and it is now gone
            // entirely. It never once produced a usable number in testing: a stationary phone
            // read 81 km/h and fabricated 273 m in 35 s; a real 20–30 km/h drive read 261; an
            // 8-minute drive read 252 km/h and invented 7.6 km of route; a 40 s walk read 142.
            // The reason is structural, not a tuning problem — accelerometer bias is
            // indistinguishable from sustained real acceleration, and integrating it produces
            // an error that grows without bound (0.05 m/s² is 11 km/h per minute, and the
            // residual after bias removal is routinely ten times that). Every wrong-speed
            // report in testing carried this branch's "DR" tag.
            //
            // So speed comes only from sources that MEASURE rather than accumulate: the
            // pedometer for steps, and the vibration model for vehicles. Until one of those is
            // available the honest answer is "unknown", which is reported as zero rather than
            // as a plausible-looking fiction that silently corrupts the route and the totals.
            estimatedFallbackSpeed = 0
            distance = 0
            // Distinguish "in a vehicle but the speed model has not been calibrated yet" from
            // "nothing detected at all" — the first is fixed by driving once with GPS, and the
            // user cannot act on it unless it is named.
            if deviceIsBeingHandled, vibrationSpeed.isCalibrated {
                // Named explicitly: the model is fine, it just cannot be read through a hand.
                sourceTag = "DR(in hand)"
            } else if vehicleContextIsCurrent {
                sourceTag = vibrationSpeed.isCalibrated ? "DR(waiting)" : "NEEDS GPS CALIBRATION"
            } else {
                sourceTag = "DR(waiting)"
            }
        }

        // GLOBAL STATIONARY OVERRIDE. Live data showed "VIB [still] FORCED 17km/h" — the
        // activity classifier confidently said stationary while a computed branch (PDR, VIB, or
        // integration) still reported a nonzero speed, because none of those branches checked
        // it. This is the backstop: whatever the source computed, if the classifier is
        // confident the device is not moving, the reading is forced to zero. It never fights a
        // genuinely moving vehicle/walk, since it only fires on a CONFIDENT stationary call.
        if isDeviceStationaryByActivity {
            estimatedFallbackSpeed = 0
            distance = 0
            if !sourceTag.hasSuffix("[still]") { sourceTag += "[still]" }
            // A confirmed stationary moment is exactly when the vibration floor can be measured.
            // That floor anchors the speed fit at zero, which is what stops a stopped vehicle
            // from reading ~30 km/h.
            vibrationSpeed.observeAtRest()
        }
        // Live diagnostic: computed travel heading (from the integrated velocity vector) vs
        // the magnetometer. During a ground test, drive a KNOWN compass direction and check
        // that the computed heading (→) matches it — if it instead tracks the compass/phone
        // orientation, the inertial signal is too weak to establish direction (expected when
        // walking; a car/plane's sustained acceleration fixes it).
        // Keep the DISPLAYED speed in sync with the dead-reckoning estimate EVERY tick, not
        // only when a route point is appended. Appends are gated on distance ≥ 0.25 m, so
        // while standing still (ZUPT zeroing the velocity, no distance) the metrics card kept
        // showing its last, stale, high value while the DR status line correctly read 0 — the
        // mismatch between "the shown one" and "the purple one".
        currentMetrics.currentSpeed = estimatedFallbackSpeed
        currentMetrics.smoothedSpeed = estimatedFallbackSpeed

        // Diagnostic: if the pedometer never delivered any data, Motion & Fitness permission
        // is likely denied — surface that so it is not mistaken for an algorithm bug.
        // Report permission from the AUTHORIZATION STATUS, never inferred from missing data:
        // CMPedometer simply does not deliver updates while you are not walking, so a nil
        // distance in a vehicle is normal and previously produced a false "denied" warning.
        if motionPermissionDenied {
            sourceTag = "DR(MOTION PERMISSION OFF)"
        }
        let compassText = locationManager.currentCompassHeading.map { String(format: "%.0f", $0) } ?? "--"
        // Show the live activity classification. Its state decides whether ZUPT may zero the
        // speed, so when a reading looks wrong this says immediately whether Apple thinks you
        // are stationary, driving, or walking.
        let activityTag: String
        if isDeviceStationaryByActivity { activityTag = " [still]" }
        else if activityIsAutomotive { activityTag = " [car]" }
        else if pedometerIsCounting { activityTag = " [walk]" }
        else { activityTag = " [?]" }
        // Show the learned compass-to-travel offset (or "--" when it has not been learned yet).
        // Heading is corrected toward compass + offset, so if the route points wrong this
        // distinguishes "offset never learned, heading free-running" from "offset learned but
        // wrong" — the two need opposite fixes, and previously both looked identical.
        // "~0" means no offset has been learned yet and zero is being ASSUMED, which is very
        // different from a measured offset that happens to be near zero.
        let offsetText = compassMisalignment.map { String(format: "%+.0f", $0) } ?? "~0"
        // CALIBRATION COVERAGE, shown whenever vibration is the source. A drive that read ~50
        // km/h while actually doing 100–110 looked identical, from the status line alone, to a
        // model that was simply wrong — when in fact it had only ever been taught city speeds
        // and was extrapolating far past them. "n=NN ≤MM" makes that visible at a glance, and
        // "!" marks a reading above everything GPS ever labelled.
        var calText = ""
        if sourceTag.hasPrefix("VIB") {
            let d = vibrationSpeed.diagnostics
            let top = d.maxCalibratedSpeed.isFinite ? Int(d.maxCalibratedSpeed * 3.6) : 0
            // u is the feature actually driving the estimate. Printing it turns "the speed is
            // wrong" into two distinguishable cases at a glance: u varying while the speed does
            // not means the FIT is bad, u sitting still while the car speeds up means the
            // FEATURE carries no speed — which is what the last three attempts turned out to be,
            // and it cost several rounds each time to establish from exports.
            calText = String(format: " u=%.1f n=%.0f≤%dkm/h%@", d.feature, d.samples, top,
                             d.isExtrapolating ? "!" : "")
        }
        motionFallbackStatus = String(format: "%@%@%@ %.0fkm/h →%.0f° cmp%@° off%@° +%.0fm%@",
                                      sourceTag,
                                      activityTag,
                                      forceMotionFallback ? " FORCED" : "",
                                      estimatedFallbackSpeed * 3.6,
                                      headingDegrees,
                                      compassText,
                                      offsetText,
                                      estimatedFallbackDistanceAdded,
                                      calText)

        // Capture the model's inputs and coefficients alongside the number it produced. Offline
        // simulation has repeatedly agreed with itself and disagreed with the road, so the
        // decisive evidence has to come from the device.
        let vd = vibrationSpeed.diagnostics
        let lastFix = flight.locations.last(where: { !$0.isEstimated && $0.isValid })
        sessionDiagnostics.record(.init(
            t: now,
            source: sourceTag,
            activity: activityTag.trimmingCharacters(in: .whitespaces),
            reportedSpeed: estimatedFallbackSpeed,
            distanceAdded: distance,
            heading: headingDegrees,
            compass: locationManager.currentCompassHeading,
            offset: compassMisalignment,
            feature: vd.feature,
            p0: vd.p0, p1: vd.p1, p2: vd.p2,
            minCalU: vd.minCalibratedU, maxCalU: vd.maxCalibratedU,
            minCalSpeed: vd.minCalibratedSpeed, maxCalSpeed: vd.maxCalibratedSpeed,
            calSamples: vd.samples,
            extrapolating: vd.isExtrapolating,
            handlingRotation: handlingRotationLevel,
            gpsSpeed: lastFix?.speed,
            gpsAccuracy: lastFix?.horizontalAccuracy,
            latitude: lastFix?.latitude,
            longitude: lastFix?.longitude,
            accelMagnitude: locationManager.currentMotionAcceleration,
            rotationRate: locationManager.currentRotationRate,
            pitch: locationManager.currentPitch,
            roll: locationManager.currentRoll,
            yaw: locationManager.currentYaw,
            altitude: locationManager.currentRelativeAltitude))

        // Push the iPhone's integrated answer to the watch every tick, regardless of GPS —
        // the watch's own device motion is frequently suppressed, and without this its assist
        // data goes stale and its speed freezes.
        WatchConnectivityManager.shared.relayDeadReckoningState(
            speed: estimatedFallbackSpeed,
            headingDegrees: headingDegrees,
            velocityNorth: motionVelNorth,
            velocityEast: motionVelEast,
            isDeadReckoning: true)

        // Accumulate below the append threshold instead of DISCARDING. Previously a tick
        // under 0.25 m returned early and the distance was lost for good — the pedometer's
        // cumulative baseline had already advanced — so slow walking silently dropped
        // distance and appended nothing.
        pendingEstimatedDistance += distance

        // ALWAYS RECORD SOMETHING. The 0.25 m threshold exists so a stationary phone does not
        // fill the track with duplicate points, but it also meant that whenever the speed model
        // produced nothing — uncalibrated, waiting for evidence, vetoed as hand-held — the
        // workout recorded NO POINTS AT ALL. A recording that captures nothing cannot be
        // reviewed, cannot be exported, and cannot be debugged; it is the one outcome with no
        // recovery. A stationary point is a genuine observation ("we were here, not moving"),
        // and time is still passing whether or not the estimator has an answer.
        //
        // So: append on distance as before, or on a heartbeat if too long has passed without any
        // point. The heartbeat is slow enough that standing still costs a handful of points a
        // minute, and it guarantees a continuous, inspectable track under every failure mode.
        let sinceLastAppend = now.timeIntervalSince(lastEstimatedAppendTime)
        let heartbeatDue = sinceLastAppend >= ESTIMATED_HEARTBEAT_SECONDS
        guard pendingEstimatedDistance >= 0.25 || heartbeatDue else { return }
        let appendDistance = pendingEstimatedDistance
        pendingEstimatedDistance = 0
        lastEstimatedAppendTime = now
        appendEstimatedLocation(distanceMeters: appendDistance, headingDegrees: headingDegrees,
                                speedMetersPerSecond: estimatedFallbackSpeed, timestamp: now)
        estimatedFallbackDistanceAdded += appendDistance
    }

    private func startEstimatedLocationFallback(anchor: FlightLocation?, gapSeconds: TimeInterval) {
        isUsingEstimatedLocationFallback = true
        lastEstimatedFallbackTick = nil
        let anchorSpeed = anchor.map { max($0.speed, 0.0) } ?? 0.0
        // No speed cap — seed from the best known speed.
        let seed = max(currentMetrics.smoothedSpeed > 0 ? currentMetrics.smoothedSpeed : anchorSpeed, 0.0)
        estimatedFallbackSpeed = seed
        estimatedFallbackDistanceAdded = 0.0
        // Seed the velocity VECTOR along the last known course so a moving vehicle keeps
        // both its speed and its heading through the gap. Prefer GPS COURSE over the compass:
        // course-over-ground is the true direction of travel, whereas the magnetometer is
        // unreliable inside a vehicle/aircraft (metal shell, EMI). Matches the watch.
        // Was the seed a real TRAVEL direction, or just device orientation? Starting Force
        // Velocity while stationary means GPS course is invalid, so the heading seeds from the
        // compass — which points where the PHONE points, not where you will walk or drive. The
        // opening stretch of the route is then drawn in the wrong direction until the offset is
        // learned. That error is a CONSTANT rotation, so it can be undone retroactively once
        // the true heading is known (see correctUntrustedHeadingPrefix).
        let measuredCourse = anchor.flatMap { validCourse($0.course) }
        let course = measuredCourse
            ?? locationManager.currentCompassHeading
            ?? locationManager.currentMotionDirectionDegrees
            ?? 0.0
        headingSeedWasMeasured = (measuredCourse != nil)
        untrustedHeadingPrefixStart = headingSeedWasMeasured ? nil : flight.locations.count
        untrustedSeedHeading = headingSeedWasMeasured ? nil : course
        // PDR distance source for step activities: pedometer from the start of the gap.
        fallbackPedometerDistance = nil
        lastFallbackPedometerDistance = 0
        pendingEstimatedDistance = 0
        lastFallbackStepCount = 0
        lastStepIncrementTime = nil
        lastStepSampleTime = nil
        stepCadence = 0
        fallbackPedometerSpeed = 0
        lastPedometerUpdateTime = nil
        pdrAppendedDistance = 0
        // Start the pedometer REGARDLESS of the selected activity type. Distance is routed by
        // whether steps are actually being counted, not by the label — the user selects a
        // vehicle/flight type but may still be walking on the ground, where accelerometer
        // integration diverges (observed: 121 km/h while walking) and the pedometer is correct.
        if CMPedometer.isDistanceAvailable() && !fallbackPedometerActive {
            fallbackPedometerActive = true
            fallbackPedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let self, let data else { return }
                let distance = data.distance?.doubleValue
                let steps = data.numberOfSteps.intValue
                let pace = data.currentPace?.doubleValue   // s/m
                let now = Date()
                DispatchQueue.main.async {
                    // Derive a SMOOTH speed from each cumulative-distance update (robust; does
                    // not depend on currentPace being present). Prefer Apple's pace when valid.
                    if let d = distance {
                        if let prevD = self.fallbackPedometerDistance,
                           let prevT = self.lastPedometerUpdateTime {
                            let dt = now.timeIntervalSince(prevT)
                            if dt > 0.5 {
                                let instant = max(0, d - prevD) / dt
                                // TIME-CONSTANT smoothing, not a fixed 50/50 blend. CMPedometer
                                // updates arrive at irregular, often multi-second intervals, so a
                                // fixed blend ratio per UPDATE (not per second) responds far
                                // slower than intended whenever updates are sparse — reported as
                                // sluggish acceleration and deceleration. A ~2 s time constant
                                // means one update after 2 s has closed ~63% of the gap, matching
                                // every other filter in this pipeline instead of drifting with
                                // however often CMPedometer happens to report.
                                let alpha = min(dt / (2.0 + dt), 1.0)
                                self.fallbackPedometerSpeed = self.fallbackPedometerSpeed + (instant - self.fallbackPedometerSpeed) * alpha
                            }
                        }
                        self.fallbackPedometerDistance = d
                        self.lastPedometerUpdateTime = now
                    }
                    if let pace, pace > 0 { self.fallbackPedometerSpeed = 1.0 / pace }
                    // CADENCE, not "any step". Road vibration in a VEHICLE makes CMPedometer
                    // emit sporadic phantom steps; treating those as walking locked the app
                    // into pedometer distance and reported ~3 km/h while actually driving.
                    // Real walking is a sustained 1.5–3 steps/s; phantom steps are sporadic.
                    if steps > self.lastFallbackStepCount {
                        let added = steps - self.lastFallbackStepCount
                        if let prev = self.lastStepSampleTime {
                            let elapsed = now.timeIntervalSince(prev)
                            if elapsed > 0.5 {
                                let cadence = Double(added) / elapsed          // steps/s
                                // SEED on the first measurement instead of smoothing up from
                                // zero. Blending 50/50 from 0 meant a real 1.5 steps/s first
                                // read as 0.75 — below the gate — so PDR needed THREE sparse
                                // pedometer updates (~30 s) to engage, which is most of a short
                                // walk. Meanwhile the walk fell through to integration.
                                if self.stepCadence <= 0 {
                                    self.stepCadence = cadence
                                } else {
                                    self.stepCadence = self.stepCadence * 0.5 + cadence * 0.5
                                }
                                // Only a genuine walking cadence counts as "stepping".
                                if self.stepCadence >= 1.0 { self.lastStepIncrementTime = now }
                            }
                        }
                        self.lastStepSampleTime = now
                    }
                    self.lastFallbackStepCount = steps
                }
            }
            print("📍 👟 PDR: pedometer engaged as gap distance source")
        }
        if CMMotionActivityManager.isActivityAvailable() && !activityUpdatesActive {
            activityUpdatesActive = true
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let self, let activity else { return }
                // Only trust a CONFIDENT stationary call, so a brief misclassification cannot
                // zero a genuinely moving vehicle.
                self.isDeviceStationaryByActivity = activity.stationary && activity.confidence != .low
                self.activityIsAutomotive = activity.automotive
                if activity.automotive { self.lastVehicleEvidenceTime = Date() }
            }
            print("📍 🚗 Activity classifier engaged (stationary/automotive detection)")
        }
        resetInertialState(seedSpeed: seed, courseDegrees: course)
        // Anchor the yaw-relative heading: from here on, travel heading = device yaw + offset,
        // so the gyro-fused attitude carries every subsequent turn.
        if let deviceYaw = locationManager.currentDeviceYawHeading {
            yawHeadingOffset = normalizedHeading(course - deviceYaw)
        } else {
            yawHeadingOffset = nil
        }
        // Anchor the reversal reference: the seed course is a real measurement.
        trustedHeading = course
        trustedHeadingYaw = locationManager.currentDeviceYawHeading
        lastDeviceYawForHeading = locationManager.cumulativeDeviceYawRotation
        motionHeadingDegrees = course
        print("📍 Estimated-location fallback started after \(String(format: "%.1f", gapSeconds))s without GPS (seed \(String(format: "%.1f", seed * 3.6))km/h @ \(Int(course))°, yawAnchor=\(yawHeadingOffset.map { String(Int($0)) } ?? "none"))")
    }

    private func endEstimatedLocationFallback(reason: String) {
        guard isUsingEstimatedLocationFallback else { return }
        print("📍 Estimated-location fallback ended: \(reason)")
        isUsingEstimatedLocationFallback = false
        lastEstimatedFallbackTick = nil
        estimatedFallbackSpeed = 0.0
        estimatedFallbackDistanceAdded = 0.0
        yawHeadingOffset = nil
        compassMisalignment = nil
        launchMeanNorth = 0; launchMeanEast = 0; launchWindowElapsed = 0
        vehicleLaunchDetected = false; vehicleConfirmedByGPSSpeed = false
        if fallbackPedometerActive {
            fallbackPedometer.stopUpdates()
            fallbackPedometerActive = false
        }
        if activityUpdatesActive {
            activityManager.stopActivityUpdates()
            activityUpdatesActive = false
        }
        isDeviceStationaryByActivity = false
        activityIsAutomotive = false
        fallbackPedometerDistance = nil
        lastFallbackPedometerDistance = 0
        pendingEstimatedDistance = 0
        lastFallbackStepCount = 0
        lastStepIncrementTime = nil
        lastStepSampleTime = nil
        stepCadence = 0
        fallbackPedometerSpeed = 0
        lastPedometerUpdateTime = nil
        pdrAppendedDistance = 0
        resetInertialState(seedSpeed: 0, courseDegrees: motionHeadingDegrees)
        motionFallbackStatus = "GPS OK"
    }

    private func reanchorAfterEstimatedFallback(with location: FlightLocation) {
        endEstimatedLocationFallback(reason: "real GPS fix received")
        // Before accepting the fix, rubber-sheet the dead-reckoned points in this gap so they
        // connect the last real anchor to the true GPS endpoint. This pins the whole gap to
        // GPS at BOTH ends instead of leaving the drifted DR track hanging — the single
        // biggest accuracy win when GPS is available intermittently.
        rubberSheetEstimatedGap(onto: location)
        flight.locations.append(location)
        lastRealLocationTime = Date()
        NotificationCenter.default.post(
            name: .workoutLocationUpdated,
            object: nil,
            userInfo: ["location": location.toCLLocation()]
        )
        currentMetrics.currentAltitude = location.altitude
        if location.altitude > currentMetrics.maxAltitude {
            currentMetrics.maxAltitude = location.altitude
        }
        currentMetrics.currentPressure = locationManager.currentPressure
        persistActiveWorkoutSnapshot(force: false, reason: "estimatedFallbackReanchor")
        print("📍 Estimated fallback reanchored to GPS without adding reanchor distance")
    }

    /// Rubber-sheet (linearly warp) the trailing run of dead-reckoned points so the DR path
    /// from the last real GPS anchor lands exactly on the new GPS fix. The accumulated drift
    /// is distributed along the run in proportion to distance travelled, which keeps the DR
    /// path's SHAPE while bounding its error to both anchors. Distance is reconciled so the
    /// total reflects the corrected geometry.
    private func rubberSheetEstimatedGap(onto fix: FlightLocation) {
        var start = flight.locations.count
        while start > 0 && flight.locations[start - 1].isEstimated { start -= 1 }
        let n = flight.locations.count - start
        // Need at least one estimated point AND a real anchor in front of it.
        guard n > 0, start > 0 else { return }
        let anchor = flight.locations[start - 1]

        // Original cumulative distance along the DR run (anchor → e1 → … → eN).
        var cumulative = [Double](repeating: 0, count: n)
        var previous = anchor
        var oldGapLength = 0.0
        for k in 0..<n {
            oldGapLength += flight.locations[start + k].distance(to: previous)
            cumulative[k] = oldGapLength
            previous = flight.locations[start + k]
        }
        guard oldGapLength > 0.5 else { return }

        // Drift vector = true endpoint (GPS fix) − drifted last estimated point, in metres.
        let last = flight.locations[start + n - 1]
        let driftNorth = (fix.latitude - last.latitude) * 111_320.0
        let driftEast = (fix.longitude - last.longitude) * 111_320.0 * cos(last.latitude * .pi / 180)
        let driftMagnitude = sqrt(driftNorth * driftNorth + driftEast * driftEast)
        // Below GPS noise there is nothing meaningful to correct.
        guard driftMagnitude > 3.0 else { return }
        // If the drift dwarfs the distance actually travelled, the anchor was wrong (stale
        // seed / bad fix) rather than the dead reckoning having drifted. Warping the points
        // onto it would stretch the route across the map as one long straight line. Discard
        // the mis-anchored estimated run instead, so the track simply resumes at the true fix.
        if driftMagnitude > max(oldGapLength * 2.0, 200.0) {
            print("📍 ⚠️ Re-anchor drift \(Int(driftMagnitude))m vs travelled \(Int(oldGapLength))m — dropping mis-anchored DR run (\(n) pts)")
            flight.locations.removeSubrange(start..<(start + n))
            currentMetrics.totalDistance = max(0, currentMetrics.totalDistance - oldGapLength)
            return
        }

        for k in 0..<n {
            let fraction = cumulative[k] / oldGapLength
            flight.locations[start + k] = flight.locations[start + k]
                .movedHorizontally(north: driftNorth * fraction, east: driftEast * fraction)
        }

        // Reconcile the accumulated distance for the change in the run's geometry.
        var newGapLength = 0.0
        previous = anchor
        for k in 0..<n {
            newGapLength += flight.locations[start + k].distance(to: previous)
            previous = flight.locations[start + k]
        }
        currentMetrics.totalDistance = max(0, currentMetrics.totalDistance + (newGapLength - oldGapLength))
        print("📍 Rubber-sheet: warped \(n) DR points onto GPS (drift \(String(format: "%.0f", driftMagnitude))m, Δdist \(String(format: "%+.0f", newGapLength - oldGapLength))m)")
    }

    /// Best-effort origin for dead reckoning when the workout has recorded no point yet
    /// (started with no GPS: airborne, basement, airplane mode). Uses the last position Core
    /// Location knows about, even a stale one — a route needs SOME geographic reference.
    private func syntheticFallbackAnchor(at timestamp: Date) -> FlightLocation? {
        // FRESHNESS IS MANDATORY. This used to accept any last-known location, including one
        // from a PREVIOUS workout hours ago and kilometres away: the track then started at
        // that stale point and, once the true position was known, drew a long straight line
        // across the map to it (observed: a 0.24 km walk rendered as a ~1 km diagonal).
        // Without a recent position it is better to have no anchor (distance-only) than to
        // anchor the whole route somewhere wrong.
        let candidate = locationManager.currentLocation ?? locationManager.latestRawLocation
        guard let known = candidate,
              timestamp.timeIntervalSince(known.timestamp) < 120,
              known.horizontalAccuracy >= 0, known.horizontalAccuracy < 200 else {
            return nil
        }
        let seed = CLLocation(
            coordinate: known.coordinate,
            altitude: known.altitude,
            horizontalAccuracy: ESTIMATED_LOCATION_HORIZONTAL_ACCURACY,
            verticalAccuracy: ESTIMATED_LOCATION_VERTICAL_ACCURACY,
            course: 0,
            speed: 0,
            // Slightly earlier so the first dead-reckoned point sorts strictly after it.
            timestamp: timestamp.addingTimeInterval(-0.5)
        )
        return FlightLocation(from: seed, isFiltered: false, isValid: true,
                              signalStrength: 20.0, pressure: locationManager.currentPressure,
                              isEstimated: true)
    }

    /// Snapshot of every motion sensor at this instant, attached to each recorded point so a
    /// dead-reckoned flight can be fully diagnosed afterwards (movement direction, device
    /// heading vs compass, acceleration components, attitude, climb rate).
    private func currentMotionSnapshot(movementDirection: Double?) -> MotionSnapshot {
        MotionSnapshot(
            acceleration: locationManager.currentMotionAcceleration,
            forwardAcceleration: locationManager.currentMotionForwardAcceleration,
            lateralAcceleration: locationManager.currentMotionLateralAcceleration,
            deviceHeading: locationManager.currentDeviceYawHeading,
            compassHeading: locationManager.currentCompassHeading,
            movementDirection: movementDirection ?? locationManager.currentMotionDirectionDegrees,
            pitch: locationManager.currentPitch,
            roll: locationManager.currentRoll,
            yaw: locationManager.currentYaw,
            rotationRate: locationManager.currentRotationRate,
            verticalSpeed: locationManager.currentVerticalSpeed,
            relativeAltitude: locationManager.currentRelativeAltitude
        )
    }

    private func appendEstimatedLocation(distanceMeters: Double, headingDegrees: Double,
                                         speedMetersPerSecond: Double, timestamp: Date) {
        var previousLocation: FlightLocation
        if let last = flight.locations.last {
            previousLocation = last
        } else if let seed = syntheticFallbackAnchor(at: timestamp) {
            // No point recorded yet (workout began without GPS): lay down an origin so the
            // dead-reckoned route can be drawn instead of silently producing nothing.
            flight.locations.append(seed)
            previousLocation = seed
            print("📍 🧭 Fallback seeded synthetic anchor (no GPS yet) at \(String(format: "%.5f", seed.latitude)),\(String(format: "%.5f", seed.longitude))")
        } else {
            // NO ORIGIN YET — buffer the movement instead of throwing its shape away.
            //
            // A coordinate genuinely cannot be produced without somewhere to start, and inventing
            // one would be worse than recording nothing. But the previous behaviour kept only the
            // scalar distance and discarded the SHAPE, so a workout that began before any fix —
            // already airborne, in a basement, in a tunnel — permanently lost its first stretch
            // even though every displacement had been measured. Hold them, and lay them all down
            // the moment a real position arrives.
            currentMetrics.totalDistance += distanceMeters
            if pendingUnanchoredMovement.count < 20_000 {
                pendingUnanchoredMovement.append((distanceMeters, headingDegrees,
                                                  speedMetersPerSecond, timestamp))
            }
            return
        }

        // An origin now exists, so anything buffered before it can finally be placed.
        if !pendingUnanchoredMovement.isEmpty {
            let buffered = pendingUnanchoredMovement
            pendingUnanchoredMovement = []
            print("📍 🧭 Replaying \(buffered.count) buffered pre-anchor movements")
            // Distance was already counted when buffered; replaying must not double it.
            let restoreDistance = currentMetrics.totalDistance
            for m in buffered {
                appendEstimatedLocation(distanceMeters: m.distance, headingDegrees: m.heading,
                                        speedMetersPerSecond: m.speed, timestamp: m.timestamp)
            }
            currentMetrics.totalDistance = restoreDistance
            previousLocation = flight.locations.last ?? previousLocation
        }
        let coordinate = projectedCoordinate(
            from: CLLocationCoordinate2D(latitude: previousLocation.latitude, longitude: previousLocation.longitude),
            distanceMeters: distanceMeters,
            bearingDegrees: headingDegrees
        )
        let location = CLLocation(
            coordinate: coordinate,
            altitude: previousLocation.altitude,
            horizontalAccuracy: ESTIMATED_LOCATION_HORIZONTAL_ACCURACY,
            verticalAccuracy: ESTIMATED_LOCATION_VERTICAL_ACCURACY,
            course: headingDegrees,
            speed: max(distanceMeters / max(timestamp.timeIntervalSince(previousLocation.timestamp), 0.5), 0.0),
            timestamp: timestamp
        )
        let estimatedLocation = FlightLocation(
            from: location,
            isFiltered: false,
            isValid: true,
            signalStrength: 20.0,
            pressure: locationManager.currentPressure,
            isEstimated: true
        ).withMotion(currentMotionSnapshot(movementDirection: headingDegrees))

        flight.locations.append(estimatedLocation)
        NotificationCenter.default.post(
            name: .workoutLocationUpdated,
            object: nil,
            userInfo: ["location": estimatedLocation.toCLLocation()]
        )
        let maxSpeedBeforeUpdate = currentMetrics.maxSpeed
        currentMetrics.updateWithLocation(estimatedLocation, previousLocation: previousLocation, elapsedTime: activeDuration)
        // The DEAD-RECKONING speed is authoritative for estimated points. FlightMetrics
        // otherwise RE-DERIVES speed from point geometry (distance ÷ timeDelta), which is a
        // different calculation from the DR estimate — so the Speed card and the Velocity
        // Mode status line disagreed. Geometry is also spiky when several ticks are batched
        // into one appended point, which is where absurd max speeds came from. Override with
        // the single authoritative value, and never let a geometric spike raise max speed.
        currentMetrics.currentSpeed = speedMetersPerSecond
        currentMetrics.smoothedSpeed = speedMetersPerSecond
        currentMetrics.maxSpeed = max(maxSpeedBeforeUpdate, speedMetersPerSecond)
        currentMetrics.currentPressure = locationManager.currentPressure
        currentMetrics.updateSplits(startDate: flight.startDate)
        persistActiveWorkoutSnapshot(force: false, reason: "estimatedLocationTick")
    }

    private func estimatedFallbackMaxSpeed() -> Double {
        // Speed cap disabled per user request — fallback can integrate
        // unconstrained, relying on ZUPT/decay to limit noise drift.
        return .greatestFiniteMagnitude
    }

    private func validCourse(_ course: Double) -> Double? {
        guard course >= 0, course <= 360 else { return nil }
        return course
    }

    private func normalizedHeading(_ heading: Double) -> Double {
        let normalized = heading.truncatingRemainder(dividingBy: 360.0)
        return normalized >= 0 ? normalized : normalized + 360.0
    }

    private func projectedCoordinate(from coordinate: CLLocationCoordinate2D, distanceMeters: Double, bearingDegrees: Double) -> CLLocationCoordinate2D {
        let earthRadiusMeters = 6_371_000.0
        let angularDistance = distanceMeters / earthRadiusMeters
        let bearing = bearingDegrees * .pi / 180.0
        let latitude1 = coordinate.latitude * .pi / 180.0
        let longitude1 = coordinate.longitude * .pi / 180.0

        let latitude2 = asin(
            sin(latitude1) * cos(angularDistance)
            + cos(latitude1) * sin(angularDistance) * cos(bearing)
        )
        let longitude2 = longitude1 + atan2(
            sin(bearing) * sin(angularDistance) * cos(latitude1),
            cos(angularDistance) - sin(latitude1) * sin(latitude2)
        )

        return CLLocationCoordinate2D(
            latitude: latitude2 * 180.0 / .pi,
            longitude: longitude2 * 180.0 / .pi
        )
    }

    private func processNewLocation(_ location: FlightLocation) {
        // FORCED VELOCITY MODE: the user has made velocity/acceleration dead reckoning the
        // SOLE distance source from the workout UI. Ignore GPS fixes entirely so they
        // can't double-count against the integrated motion distance. Turning the toggle
        // off resumes normal GPS on the next fix (reanchorAfterEstimatedFallback).
        if forceMotionFallback {
            // Still learn from GPS even though it is ignored for distance: Force Velocity is
            // usually enabled on the ground BEFORE the signal is lost, so this is exactly the
            // window in which the vibration model can be calibrated for the trip ahead.
            // NEVER while actively stepping: the vibration model is for VEHICLES, and a walk's
            // noisy instantaneous GPS speed poisoned it with spurious high-speed points that
            // then reported vibration-derived speed while the phone was sitting still.
            let currentlyStepping = lastStepIncrementTime.map { Date().timeIntervalSince($0) < 20.0 } ?? false
            // POSITIVE vehicle evidence required, not just "not stepping". "Not stepping" is a
            // 20 s-stale pedometer flag: it stays false for the first steps of a walk (before
            // any step has landed) and for a full 20 s after one, so early-walk and post-walk
            // GPS fixes leaked walking vibration into what is meant to be a pure-vehicle fit.
            // That single shared model then misfires in BOTH directions on later trips: a real
            // ~100 km/h drive read 37 km/h (walking points, low speed/high vibration, drag the
            // through-origin slope down), and a real walk read 40 km/h avg 94 (the model is
            // still car-shaped, so ordinary footstep vibration gets read as highway speed).
            // GPS speed alone proves a vehicle: 8 m/s is 29 km/h, far past any walking or
            // running pace, so this needs no help from the inertial launch detector — which
            // misses a gentle pull-away, and misses entirely a drive already under way when the
            // workout was started.
            sessionDiagnostics.latestGPSSpeed = location.speed
            if location.speed > 8.0, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 20.0 {
                vehicleConfirmedByGPSSpeed = true; lastVehicleEvidenceTime = Date()
            }
            if location.speed >= 0, !currentlyStepping,
               (vehicleLaunchDetected || activityIsAutomotive || vehicleConfirmedByGPSSpeed) {
                vibrationSpeed.calibrate(withGPSSpeed: location.speed, horizontalAccuracy: location.horizontalAccuracy)
            }
            // CRITICAL: learn the heading offset here too. This method previously ran only
            // AFTER this early return, so in Force Velocity — the mode this feature exists for —
            // it never executed. A vehicle has no steps, so the PCA path could not supply the
            // offset either, leaving compassMisalignment nil, NO compass correction applied at
            // all, and the heading free-running on the gyro from its seed. That is why vehicle
            // routes pointed the wrong way even after the offset logic was added.
            learnCompassMisalignment(from: location)

            // THE FIRST POINT, AND ONLY THE FIRST, MAY COME FROM GPS.
            //
            // In this mode the track must be dead-reckoned end to end — that is the whole point
            // of it, and letting later fixes in would mix two sources and hide exactly the
            // errors it exists to expose. But it still has to START somewhere real: without an
            // anchor the route was seeded from syntheticFallbackAnchor, i.e. whatever position
            // happened to be last known, which can be stale or missing entirely and puts the
            // whole otherwise-correct shape in the wrong place.
            //
            // So: one accurate fix, only while no point exists yet, purely as the origin.
            // lastRealLocationTime is deliberately left alone — GPS is not a distance source
            // here, and dead reckoning runs unconditionally in this mode anyway.
            if flight.locations.isEmpty,
               location.horizontalAccuracy >= 0,
               location.horizontalAccuracy <= GPS_MAX_USABLE_ACCURACY {
                let anchor = location.withMotion(
                    currentMotionSnapshot(movementDirection: validCourse(location.course)))
                flight.locations.append(anchor)
                print("📍 🧭 Velocity mode anchored to GPS ±\(Int(location.horizontalAccuracy))m — all later points are dead-reckoned")
            }
            return
        }

        // Accept every usable Core Location GPS fix on iPhone/iPad. Distance is
        // calculated from the recorded track without speed, jump, acceleration,
        // or stale-time caps.
        if location.horizontalAccuracy < 0 {
            print("🚫 INVALID GPS (no satellite fix) - REJECTED")
            return
        }

        // CONDITIONAL accuracy rejection: drop a bad fix only when something better is actually
        // available to take its place.
        //
        // A flat cap failed in both directions. Rejecting everything above a threshold broke
        // recording outright — this runs BEFORE lastRealLocationTime is set, so a rejected fix
        // is neither recorded nor counted as a fix, and with raw integration removed an
        // uncalibrated speed model adds nothing either, so a weak-signal walk recorded nothing
        // at all. Removing the cap entirely then let single wild fixes back into the track, and
        // those are worse than they look: the road-alignment pass snaps the trace to OSM
        // geometry, so one excursion does not stay a small wobble — it gets matched onto a
        // neighbouring road and drawn as a confident detour that was never walked.
        //
        // The distinction that matters is not how bad the fix is, but whether we can afford to
        // ignore it. With a good fix in the last 30 s the previous position and dead reckoning
        // together cover the gap, so a wild one is pure noise and is dropped. With nothing
        // better recently, even a poor fix is far more informative than no position at all, so
        // it is kept.
        let hasRecentGoodFix = Date().timeIntervalSince(lastGoodAccuracyFixTime) < 30.0
        if location.horizontalAccuracy > POOR_FIX_ACCURACY, hasRecentGoodFix {
            print("🚫 NOISY FIX ±\(Int(location.horizontalAccuracy))m dropped (good fix still recent)")
            return
        }
        if location.horizontalAccuracy <= GOOD_FIX_ACCURACY {
            lastGoodAccuracyFixTime = Date()
        }

        if isUsingEstimatedLocationFallback {
            reanchorAfterEstimatedFallback(with: location)
            return
        }

        // Check if we need to skip locations after resume from pause
        if locationsToSkipAfterResume > 0 {
            print("⏭️ Skipping location (\(LOCATIONS_TO_SKIP_AFTER_RESUME - locationsToSkipAfterResume + 1)/\(LOCATIONS_TO_SKIP_AFTER_RESUME)) to let GPS stabilize")
            locationsToSkipAfterResume -= 1

            // Add location but don't calculate distance
            flight.locations.append(location)
            lastRealLocationTime = Date()
            NotificationCenter.default.post(
                name: .workoutLocationUpdated,
                object: nil,
                userInfo: ["location": location.toCLLocation()]
            )

            // Update current altitude and other non-distance metrics
            currentMetrics.currentAltitude = location.altitude
            if location.altitude > currentMetrics.maxAltitude {
                currentMetrics.maxAltitude = location.altitude
            }

            return
        }

        // Add to flight (after GPS filtering passed), with the current motion snapshot.
        flight.locations.append(location.withMotion(currentMotionSnapshot(movementDirection: validCourse(location.course))))
        lastRealLocationTime = Date()
        NotificationCenter.default.post(
            name: .workoutLocationUpdated,
            object: nil,
            userInfo: ["location": location.toCLLocation()]
        )

        // Calculate time delta from previous location
        let previousLocation = flight.locations.count > 1 ? flight.locations[flight.locations.count - 2] : nil
        let timeDelta = previousLocation != nil ? location.timestamp.timeIntervalSince(previousLocation!.timestamp) : 0.0

        // Performance: Only log every 10th GPS point to reduce string formatting overhead
        // First 10 locations are always logged for debugging, then every 10th
        if flight.locations.count <= 10 || flight.locations.count % 10 == 0 {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let timeString = formatter.string(from: location.timestamp)
            let milliseconds = Int((location.timestamp.timeIntervalSince1970.truncatingRemainder(dividingBy: 1.0)) * 1000)

            print("📍 GPS #\(flight.locations.count) [\(timeString).\(String(format: "%03d", milliseconds))] Δt=\(String(format: "%.2f", timeDelta))s | lat=\(String(format: "%.6f", location.latitude)), lon=\(String(format: "%.6f", location.longitude)) | alt=\(String(format: "%.1f", location.altitude))m | acc=±\(String(format: "%.1f", location.horizontalAccuracy))m")
        }

        // Calculate active time (excluding paused periods) for accurate speed calculation
        let activeTime = activeDuration

        // Update metrics with active time for accurate speed calculation
        currentMetrics.updateWithLocation(location, previousLocation: previousLocation, elapsedTime: activeTime)

        // Update pressure from LocationManager
        currentMetrics.currentPressure = locationManager.currentPressure

        // Update splits
        currentMetrics.updateSplits(startDate: flight.startDate)
        persistActiveWorkoutSnapshot(force: false, reason: "locationTick")

        learnCompassMisalignment(from: location)

        // Teach the vibration model from this GPS fix. Doing it on every usable fix means the
        // model is already calibrated for THIS vehicle and phone placement by the time GPS is
        // lost, which is when it has to carry the estimate. Never while actively stepping — see
        // the FORCED-mode calibration call above for why.
        let currentlyStepping = lastStepIncrementTime.map { Date().timeIntervalSince($0) < 20.0 } ?? false
        sessionDiagnostics.latestGPSSpeed = location.speed
        // Same vehicle-evidence gate as the Force-Velocity calibration call above — see the
        // comment there for why "not stepping" alone let walking contaminate the fit, and why
        // GPS speed is admitted as evidence in its own right.
        if location.speed > 8.0, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 20.0 {
            vehicleConfirmedByGPSSpeed = true; lastVehicleEvidenceTime = Date()
        }
        if location.speed >= 0, !currentlyStepping,
           (vehicleLaunchDetected || activityIsAutomotive || vehicleConfirmedByGPSSpeed) {
            vibrationSpeed.calibrate(withGPSSpeed: location.speed, horizontalAccuracy: location.horizontalAccuracy)
        }

        // Relay the iPhone's BEST-KNOWN heading to the watch on every fix, not only from the
        // dead-reckoning tick. A watch cannot resolve walking direction by itself (arm swing
        // defeats the acceleration-axis method), so it depends on this. Previously the relay
        // fired only while the iPhone was ITSELF dead reckoning — so on a normal walk, where
        // the iPhone still has GPS, the watch received nothing, held one course and drew a
        // STRAIGHT LINE. With GPS present, course-over-ground is the best heading there is.
        if let course = validCourse(location.course) {
            let speed = max(location.speed, 0)
            WatchConnectivityManager.shared.relayDeadReckoningState(
                speed: speed,
                headingDegrees: course,
                velocityNorth: speed * cos(course * .pi / 180),
                velocityEast: speed * sin(course * .pi / 180),
                isDeadReckoning: false)
        }

        // Update Live Activity (throttled to every 2 seconds)
        let now = Date()
        if lastLiveActivityUpdate == nil || now.timeIntervalSince(lastLiveActivityUpdate!) >= LIVE_ACTIVITY_UPDATE_INTERVAL {
            if #available(iOS 16.1, *) {
                WorkoutLiveActivityManager.shared.updateLiveActivity(
                    duration: activeDuration,
                    distance: currentMetrics.totalDistance,
                    speed: liveActivitySpeedMps,
                    calories: currentMetrics.caloriesBurned,
                    altitude: currentMetrics.currentAltitude,
                    heartRate: currentMetrics.currentHeartRate,
                    isPaused: isPaused
                )
            }

            // DISABLED: Watch no longer mirrors iPhone workouts
            // No need to send updates to Watch

            lastLiveActivityUpdate = now
        }

        // Note: HKWorkoutBuilder automatically calculates distance from GPS route
        // No need to manually add distance samples during workout - causes inflated distance bug

        // Log summary every 50 locations
        if flight.locations.count % 50 == 0 {
            print("📊 Summary: \(flight.locations.count) locations, Distance: \(String(format: "%.2f", currentMetrics.totalDistance/1000))km, Speed: \(String(format: "%.1f", currentMetrics.smoothedSpeed * 3.6))km/h (smoothed), Avg: \(String(format: "%.1f", currentMetrics.averageSpeed * 3.6))km/h")
        }
    }

    // REMOVED: sendWorkoutUpdateToWatch() function
    // No longer needed since Watch doesn't mirror iPhone workouts

    func pauseWorkout() {
        print("⏸️ pauseWorkout() called")
        print("   Current state: isActive=\(isActive), isPaused=\(isPaused)")

        guard isActive else {
            print("⚠️ Cannot pause - workout not active")
            return
        }

        guard !isPaused else {
            print("⚠️ Cannot pause - already paused")
            return
        }

        print("⏸️ Pausing workout...")
        print("   Time before pause: \(String(format: "%.1f", activeDuration))s")
        print("   Location manager isTracking: \(locationManager.isTracking)")

        // Set state BEFORE stopping tracking
        isPaused = true
        pauseStartTime = Date()

        print("   State updated: isPaused=\(isPaused)")
        print("   Pause started at: \(pauseStartTime?.formatted() ?? "nil")")
        print("   Total paused time so far: \(String(format: "%.1f", totalPausedTime))s")

        // Mark to skip multiple locations after resume to let GPS stabilize
        locationsToSkipAfterResume = LOCATIONS_TO_SKIP_AFTER_RESUME
        persistActiveWorkoutSnapshot(force: true, reason: "pauseWorkout", shouldLog: true)

        // Update Live Activity to show paused state
        if #available(iOS 16.1, *) {
            WorkoutLiveActivityManager.shared.updateLiveActivity(
                duration: activeDuration,
                distance: currentMetrics.totalDistance,
                speed: liveActivitySpeedMps,
                calories: currentMetrics.caloriesBurned,
                altitude: currentMetrics.currentAltitude,
                heartRate: currentMetrics.currentHeartRate,
                isPaused: true
            )
        }

        // DISABLED: Watch no longer mirrors iPhone workouts

        // Stop location tracking on background thread to avoid blocking UI
        print("   Stopping location tracking...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            print("   📍 Calling locationManager.stopTracking()...")
            self.locationManager.stopTracking()

            DispatchQueue.main.async {
                print("✅ Workout paused successfully")
                print("   Location manager isTracking: \(self.locationManager.isTracking)")
                print("   Will skip \(self.locationsToSkipAfterResume) locations after resume")
                print("   State: isActive=\(self.isActive), isPaused=\(self.isPaused)")
            }
        }
    }

    func resumeWorkout() {
        print("📍 resumeWorkout() called")
        print("   Current state: isActive=\(isActive), isPaused=\(isPaused)")

        guard isActive else {
            print("⚠️ Cannot resume - workout not active")
            return
        }

        guard isPaused else {
            print("⚠️ Cannot resume - workout not paused")
            return
        }

        print("▶️ Resuming workout...")
        print("   Location manager isTracking: \(locationManager.isTracking)")

        // Calculate and accumulate paused time
        if let pauseStart = pauseStartTime {
            let pausedDuration = Date().timeIntervalSince(pauseStart)
            totalPausedTime += pausedDuration
            print("⏱️ Was paused for \(String(format: "%.1f", pausedDuration))s")
            print("   Total paused time: \(String(format: "%.1f", totalPausedTime))s")
            print("   Active duration after resume: \(String(format: "%.1f", activeDuration))s")
        } else {
            print("⚠️ WARNING: pauseStartTime was nil during resume!")
        }

        // Set state BEFORE starting tracking to avoid race conditions
        isPaused = false
        pauseStartTime = nil

        print("   State updated: isPaused=\(isPaused)")
        persistActiveWorkoutSnapshot(force: true, reason: "resumeWorkout", shouldLog: true)

        // Update Live Activity to show resumed state
        if #available(iOS 16.1, *) {
            WorkoutLiveActivityManager.shared.updateLiveActivity(
                duration: activeDuration,
                distance: currentMetrics.totalDistance,
                speed: liveActivitySpeedMps,
                calories: currentMetrics.caloriesBurned,
                altitude: currentMetrics.currentAltitude,
                heartRate: currentMetrics.currentHeartRate,
                isPaused: false
            )
        }

        // DISABLED: Watch no longer mirrors iPhone workouts

        // Start location tracking on background thread to avoid blocking UI
        print("   Starting location tracking...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            print("   📍 Calling locationManager.startTracking()...")
            self.locationManager.startTracking()

            DispatchQueue.main.async {
                print("✅ Workout resumed successfully")
                print("   Location manager isTracking: \(self.locationManager.isTracking)")
                print("   Will skip next \(self.locationsToSkipAfterResume) locations")
                print("   State: isActive=\(self.isActive), isPaused=\(self.isPaused)")
            }
        }
    }

    func reset() {
        stopEstimatedFallbackTimer()
        workoutBuilder = nil
        flight = Flight()
        currentMetrics = FlightMetrics()
        locationManager.reset()
        endTransitionBackgroundTaskIfNeeded()
        clearActiveWorkoutSnapshot(reason: "reset")
        isActive = false
        isPaused = false
        totalPausedTime = 0
        pauseStartTime = nil
        locationsToSkipAfterResume = 0
    }
}
