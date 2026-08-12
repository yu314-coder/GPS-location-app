import Foundation
import HealthKit
import CoreLocation
import CoreMotion
import Combine
import Network

#if os(watchOS)
class WorkoutSession: NSObject, ObservableObject {
    private enum LocationInputSource {
        case watchGPS
        case iphoneAssist
        case iphoneFallback
    }

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var workoutType: HKWorkoutActivityType = .walking

    // Session health monitoring
    // NOTE: HKWorkoutSession provides extended runtime automatically - no WKExtendedRuntimeSession needed
    private var sessionHealthTimer: Timer?
    private var keepAliveTimer: Timer?  // CRITICAL: Prevents app from sleeping
    private var watchdogTimer: Timer?   // CRITICAL: Detects when locations actually stop
    private var forceRestartTimer: Timer?  // CRITICAL: Periodic forced GPS restart
    private var phoneCheckpointTimer: Timer?  // CRITICAL: Flushes workout data to iPhone every 10s
    private var lastPhoneCheckpointLocationCount = 0
    private var retainedLocationOffset = 0
    private let maxRetainedLocationsOnWatch = 180
    private let minRetainedLocationsOnWatch = 2
    private var lastLocationCount: Int = 0  // Track if locations are actually arriving

    @Published var isActive = false
    @Published var isPaused = false
    @Published var flight: Flight
    @Published var currentMetrics = FlightMetrics()
    @Published var lastLocationTime: Date = Date()  // Exposed for UI to monitor GPS health
    @Published var isUsingIPhoneGPSFallback = false
    @Published var fallbackDebugStatus = "GPS OK"   // live on-screen fallback state
    /// Velocity Mode. PERSISTED across workouts, matching the iPhone: it could previously only
    /// be switched on AFTER a workout had started, so the opening seconds of every test were
    /// ordinary GPS and the track was a mixture of two sources.
    @Published var forceMotionFallback = false {
        didSet {
            guard persistForceMotionFallback else { return }
            UserDefaults.standard.set(forceMotionFallback, forKey: "velocityModeEnabled")
        }
    }
    private var persistForceMotionFallback = true

    private func setForceMotionFallback(_ value: Bool, persist: Bool) {
        persistForceMotionFallback = persist
        forceMotionFallback = value
        persistForceMotionFallback = true
    }
    @Published var networkDebugMessage = "GPS active"
    @Published var networkPathStatus = "Net: pending • iPhone: disconnected"
    @Published var nativePedometerStepCount: Int = 0
    @Published var nativePedometerDistanceMeters: Double = 0.0
    @Published var nativePedometerCallbackHz: Double = 0.0
    @Published var nativePedometerCallbackAgeSeconds: TimeInterval = 0.0
    @Published var nativePedometerQueryAgeSeconds: TimeInterval = 0.0

    let locationManager = LocationManager()
    let healthKitManager = HealthKitManager()
    let pedometerManager = PedometerManager()
    private var cancellables = Set<AnyCancellable>()
    private let connectivityManager = WatchConnectivityManager.shared

    // Throttle phone sync to 1Hz (every 1.0s) to match GPS update frequency
    private var lastPhoneSyncTime: Date = .distantPast

    // Track pause/resume to prevent GPS drift distance bugs
    private var locationsToSkipAfterResume = 0
    private let LOCATIONS_TO_SKIP_AFTER_RESUME = 0  // Don't skip locations after resume - GPS is already stable

    private let saveQueue = DispatchQueue(label: "com.workout.incrementalsave", qos: .utility)

    // Track location filtering statistics
    private var skippedLocationCount = 0

    // iPhone GPS Fallback
    private var isWatchGPSFailing = false
    private var watchGPSFailureStartTime: Date?
    private let WATCH_GPS_FAILURE_THRESHOLD: TimeInterval = 30.0  // Prefer watch GPS/cellular first; use iPhone fallback only after sustained failure
    private var lastWatchGPSTime: Date = Date()
    private var lastManualRefreshRequestTime: Date?
    private var lastManualRefreshTapTime: Date = .distantPast
    private let manualRefreshCooldown: TimeInterval = 2.0
    private var latestIPhoneMotionAssist: IPhoneMotionAssist?
    private let motionAssistMaxAge: TimeInterval = 3.0
    private let motionAssistExtraAccelerationAllowance: Double = 12.0
    private let motionAssistDirectionToleranceDegrees: Double = 70.0
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.gpsapp.watch.pathmonitor")
    private var latestPathStatus: NWPath.Status = .requiresConnection
    private var latestPathInterface = "unknown"

    // Pedometer fallback for GPS gaps (tunnels, underground, poor signal)
    // When GPS is lost for >GPS_GAP_THRESHOLD seconds, use CMPedometer incremental
    // distance to keep totalDistance growing. Only for step-based activities.
    private var isUsingPedometerFallback = false
    private var pedometerDistanceAtGapStart: Double = 0.0  // pedometer.currentDistance when gap started
    private var gpsDistanceAtGapStart: Double = 0.0  // totalDistance when gap started
    private var pedometerFallbackDistanceAdded: Double = 0.0  // how much pedometer distance was added during this gap
    private var pedometerFallbackStartTime: Date?             // when pedometer fallback engaged (to detect "no steps → vehicle")
    private let GPS_GAP_THRESHOLD: TimeInterval = 5.0  // seconds without valid GPS before switching to pedometer
    /// Matched to the iPhone's ESTIMATED_LOCATION_GAP_THRESHOLD so both devices decide GPS is
    /// gone at the same moment; a watch that switched two seconds earlier reported a different
    /// distance for the same gap.
    private let WATCH_DEAD_RECKON_THRESHOLD: TimeInterval = 5.0
    private let PEDOMETER_NO_STEP_GRACE: TimeInterval = 5.0   // if pedometer adds ~nothing this long, motion takes over
    private var lastPedometerFallbackLogTime: Date = .distantPast
    private let ESTIMATED_LOCATION_HORIZONTAL_ACCURACY: Double = 250.0
    private let ESTIMATED_LOCATION_VERTICAL_ACCURACY: Double = 250.0

    // Motion (accelerometer) dead-reckoning fallback for non-step activities
    // (cycling on a trainer, train, car). Activates when GPS is lost AND pedometer
    // isn't applicable. Uses CMDeviceMotion's userAcceleration (gravity-removed).
    private let motionManager = CMMotionManager()
    private var isUsingMotionFallback = false
    private var motionFallbackSpeed: Double = 0.0          // m/s (= magnitude of the velocity vector)
    private var motionFallbackDistanceAdded: Double = 0.0   // meters this gap
    private var lastMotionFallbackTick: Date?
    private var lastMotionForwardAccel: Double = 0.0        // m/s² horizontal magnitude (iPhone-assist compat)
    // Signed WORLD-frame inertial state. We integrate an acceleration VECTOR into a
    // velocity VECTOR (X ≈ north, Y ≈ west in a Z-vertical reference frame) so that
    // deceleration SUBTRACTS and transient bumps/vibration cancel out — this is what
    // stops the old |accel|-magnitude runaway where speed could only ever climb.
    private var worldAccelX: Double = 0.0                   // m/s², gravity-free, world frame (≈ north)
    private var worldAccelY: Double = 0.0                   // m/s², world frame (≈ west)
    private var accelBiasX: Double = 0.0                    // slow DC-bias estimate (curbs drift)
    private var accelBiasY: Double = 0.0
    private var motionVelX: Double = 0.0                    // m/s velocity vector (north)
    private var motionVelY: Double = 0.0                    // m/s velocity vector (west)
    private var motionHeadingDegrees: Double = 0.0          // bearing from velocity vector, for route projection
    private var motionAttitudeReady = false                 // device-motion w/ attitude is delivering
    private var prevResidualX: Double = 0.0                 // previous bias-corrected accel (trapezoidal integration)
    private var prevResidualY: Double = 0.0
    private var lastMotionFallbackLogTime: Date = .distantPast
    private var lastFallbackTickTime: Date?                 // debounce for dual-timer fallback driver
    private var lastAnchorlessFallbackTime: Date?          // for distance-only dead reckoning
    private var lastIPhoneRelayCoord: (lat: Double, lon: Double)?  // detect frozen (stale) iPhone relay
    private var lastIPhoneRelayTime: Date?                         // freshness for anchoring
    private var frozenIPhoneRelayCount: Int = 0
    private let MOTION_FALLBACK_TICK: TimeInterval = 1.0
    /// Longest a dead-reckoned workout may go without recording a point, however little the
    /// estimator has to say. Matches the iPhone.
    private let MOTION_HEARTBEAT_SECONDS: TimeInterval = 5.0
    private var lastMotionAppendTime: Date = .distantPast
    // NOTE: there is deliberately NO speed cap anywhere in the velocity dead reckoning —
    // speed is simply the magnitude of the integrated velocity vector.
    // ZUPT state — replaces the old velocity leak and settle-to-rest damping.
    /// False when Core Motion could only supply `.xArbitraryZVertical`, i.e. world X is not
    /// north and the integrated direction carries no absolute bearing.
    private var motionFrameIsAbsolute = true
    /// World-frame heading of the watch's +Y axis from the gyro-fused attitude. Its CHANGES
    /// track turns regardless of acceleration.
    private var deviceYawHeadingDegrees: Double?
    /// Travel course − device yaw, anchored when dead reckoning engages. Travel heading =
    /// device yaw + offset; the gyro carries every turn, with no acceleration needed —
    /// which is why direction works while walking, where the velocity vector has no signal.
    private var yawHeadingOffset: Double?
    /// Pedometer cumulative-distance baseline for the PDR distance path (step activities).
    private var lastPedometerDistanceForDR: Double?
    private var smoothedPedometerSpeedWatch: Double = 0
    private var pdrAppendedDistanceWatch: Double = 0
    private var lastPedometerUpdateTimeWatch: Date?
    /// Unwrapped cumulative heading change from the watch gyro (vertical-axis integration),
    /// and the value consumed at the previous heading tick.
    private var cumulativeYawRotationDeg: Double = 0
    private var lastCumulativeYawForHeading: Double?
    /// Compass-to-travel offset learned by the iPhone and relayed; nil until known.
    private var relayedCompassMisalignment: Double?
    /// Distance measured but not yet long enough to justify a route point; carried forward.
    private var pendingMotionDistance: Double = 0
    /// Step-count tracking used to decide whether the pedometer is a VALID distance source
    /// right now (it is not, in a vehicle or aircraft, whatever the activity label says).
    private var lastPedometerStepCountForDR: Int = 0
    private var lastStepSampleTimeWatch: Date?
    private var stepCadenceWatch: Double = 0
    private var lastStepIncrementTime: Date?
    // iPhone's relayed dead-reckoning answer. The watch's own device motion is often
    // suppressed (memory pressure / power), and the old assist only arrived attached to a GPS
    // relay — so with no GPS the watch had nothing and its speed froze. The iPhone runs the
    // full ZUPT/bias/yaw pipeline, so when the watch can't integrate for itself it simply
    // ADOPTS the iPhone's speed and heading. Bluetooth/peer-WiFi: no internet required.
    /// Last speed the WATCH's own GPS measured, held when GPS goes — mirrors the iPhone's HOLD.
    private var lastMeasuredVehicleSpeedWatch: Double?
    private var iPhoneDRSpeed: Double?
    private var iPhoneDRHeading: Double?
    private var iPhoneDRVelocity: (north: Double, east: Double)?
    private var iPhoneDRTimestamp: Date?
    /// Relayed DR state older than this is stale and must not be used.
    private let IPHONE_DR_MAX_AGE: TimeInterval = 6.0
    private var zuptWindow: [(t: TimeInterval, accel: Double, rotation: Double)] = []
    private var zuptWindowFilled = false
    private var isInertialStationary = false
    private var lastMotionSampleTimestamp: TimeInterval?
    /// Tuned by simulation: above ~0.35 the detector fires during a genuine smooth cruise and
    /// destroys real velocity.
    private let ZUPT_MAX_SPEED: Double = 5.0                // m/s: normal-stop tier
    private let HARD_ZUPT_ACCEL: Double = 0.15             // prolonged-stillness tier (no speed gate)
    private let HARD_ZUPT_ROTATION: Double = 0.18
    private let HARD_ZUPT_WINDOW: TimeInterval = 2.0
    private var hardQuietDuration: TimeInterval = 0
    private var longRunMeanX: Double = 0
    private var longRunMeanY: Double = 0
    private let DR_MAX_SPEED: Double = 360.0               // m/s: divergence backstop (~1300 km/h)

    // MARK: - Step detection and held-speed correction (identical method to the iPhone)
    //
    // CMPedometer is the authority on how far a walk went but is far too slow to say WHEN it
    // started and stopped — measured on iPhone at 16-27 s late in both directions. Steps are
    // plainly visible in the vertical acceleration, so detect them here and let the pedometer
    // correct the total afterwards. Same thresholds and same structure as the iPhone so the
    // two devices cannot disagree about what they are measuring.
    private var stepDetectSlowVertical: Double = 0
    private var stepDetectArmed = true
    private var imuStepTimes: [Date] = []
    private var imuStepsPendingTick = 0
    private var learnedStrideLength: Double = 0.70
    private var walkedDistanceEstimate: Double = 0
    private var lastPedometerDistanceForStride: Double?
    private var lastStepCountForStride: Int = 0
    private let STEP_PEAK_ACCEL: Double = 1.2
    private let STEP_RESET_ACCEL: Double = 0.4
    private let STEP_MIN_INTERVAL: TimeInterval = 0.25
    private var pedestrianQuietDuration: TimeInterval = 0
    private let PEDESTRIAN_STILL_ACCEL: Double = 1.0
    private let PEDESTRIAN_STILL_ROTATION: Double = 0.5
    private let PEDESTRIAN_STILL_WINDOW: TimeInterval = 1.2
    private let VEHICLE_STOP_QUIET_WINDOW: TimeInterval = 2.5
    private let VEHICLE_STOP_CONFIRM_SPEED: Double = 2.5      // m/s (9 km/h)
    /// Velocity change measured along the direction of travel since GPS last stated the speed.
    private var heldSpeedCorrection: Double = 0
    private let HELD_SPEED_ACCEL_FLOOR: Double = 0.25
    /// A held speed above this could be an aircraft, and an aircraft at cruise is quiet — so
    /// quiet must never be read as stopped there. The iPhone uses cabin pressure for this; the
    /// watch has no barometric flight phase, so it uses the speed itself, which is safe in the
    /// only direction that matters: nothing fast is ever zeroed by stillness.
    private let MAX_GROUND_STOP_SPEED: Double = 60.0        // m/s (216 km/h)
    /// How old a fix may be and still anchor a dead-reckoned route (see iPhone: Core Location
    /// returns a cached position on the first callback after startUpdatingLocation).
    private let MAX_ANCHOR_FIX_AGE: TimeInterval = 5.0

    private var imuStepCadence: Double {
        let now = Date()
        let recent = imuStepTimes.filter { now.timeIntervalSince($0) <= 2.5 }
        guard recent.count >= 2, let first = recent.first, let last = recent.last else { return 0 }
        let span = last.timeIntervalSince(first)
        guard span > 0.2 else { return 0 }
        return Double(recent.count - 1) / span
    }

    private var imuIsStepping: Bool {
        guard let last = imuStepTimes.last, Date().timeIntervalSince(last) < 1.2 else { return false }
        return imuStepCadence >= 1.0
    }

    private var pedestrianIsStandingStill: Bool {
        guard pedestrianQuietDuration >= PEDESTRIAN_STILL_WINDOW else { return false }
        guard let last = imuStepTimes.last else { return true }
        return Date().timeIntervalSince(last) >= PEDESTRIAN_STILL_WINDOW
    }
    private let ZUPT_ACCEL_THRESHOLD: Double = 0.25         // m/s² peak residual within window
    private let ZUPT_ROTATION_THRESHOLD: Double = 0.35      // rad/s — a resting device is not rotating
    private let ZUPT_WINDOW: TimeInterval = 0.75            // s of quiet before velocity is zeroed
    private let ZUPT_BIAS_RATE: Double = 0.05               // fast bias learning during a ZUPT
    // CONTINUOUS gated bias estimation — NOT redundant with ZUPT. The dominant real-world
    // error is attitude error tilting GRAVITY into the horizontal axes (0.5° = 0.086 m/s²).
    // On a sustained cruise the device never goes stationary so ZUPT never fires, and this is
    // the only term that can cancel it. Simulated 30-min drive: with it −0.3%, without +211%.
    private let MOTION_BIAS_RATE: Double = 0.02
    private let MOTION_BIAS_GATE: Double = 1.0     // raised from 0.3: cancel gravity-leakage so standing does not diverge

    // GPS accuracy thresholds (Modern approach based on Google Maps & fitness apps research)
    private let MAX_HORIZONTAL_ACCURACY: Double = 100.0  // 100m maximum (more lenient to capture more distance points)
    private let MAX_LOCATION_AGE: TimeInterval = 15.0  // 15 seconds maximum age (more lenient for watch GPS)
    private let MAX_SPEED_MPS: Double = .greatestFiniteMagnitude  // speed limit disabled per user request
    private let MAX_DISTANCE_JUMP: Double = 150.0  // 150m maximum jump between points (more lenient to avoid rejecting valid movement)
    private let MAX_ACCELERATION_MPS2: Double = 10.0  // Reject sudden GPS-derived speed changes that exceed workout movement

    // ABSOLUTE SAFETY LIMITS - applied even in Raw GPS mode to prevent impossible physics
    private let ABSOLUTE_MAX_SPEED_MPS: Double = .greatestFiniteMagnitude  // speed limit disabled per user request
    private let ABSOLUTE_MAX_DISTANCE_JUMP: Double = 500.0  // 500m instant teleport = definitely GPS glitch

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
            // Fitness app does not display routes/distances for .other reliably.
            // Export flights as walking to count towards step distance.
            return workoutType == .other ? .walking : workoutType
        }
    }

    func setWorkoutType(_ type: HKWorkoutActivityType) {
        workoutType = type
        print("⌚ Workout type set to: \(type.rawValue)")
    }

    override init() {
        self.flight = Flight()
        super.init()
        startNetworkPathMonitoring()
        setupLocationUpdates()
        setupConnectivityObservers()
        setupPedometerObserver()
        recoverUnfinishedFlights()
    }

    /// Crash-recovery fallback: the watch persists each checkpoint to disk via
    /// mergeFlightCheckpoint, so a partial track survives a crash. On launch,
    /// finalize any unfinished flight (endDate == nil) and push it to iPhone so
    /// the trace is never lost.
    private func recoverUnfinishedFlights() {
        FlightDataStore.shared.loadFlights()
        let unfinished = FlightDataStore.shared.savedFlights.filter { $0.endDate == nil }
        guard !unfinished.isEmpty else { return }

        for summary in unfinished {
            // Skip the one we may be about to resume as the live workout.
            if isActive && summary.id == flight.id { continue }

            guard var full = FlightDataStore.shared.loadFlightDetails(id: summary.id),
                  !full.locations.isEmpty else {
                continue
            }

            // Finalize using the last recorded location's timestamp as end time.
            let endDate = full.locations.last?.timestamp ?? full.startDate
            full.endDate = endDate

            var metrics = full.metrics ?? FlightMetrics()
            let duration = max(0, endDate.timeIntervalSince(full.startDate))
            metrics.calculateAverages(duration: duration)
            metrics.finalizeSplits()
            metrics.sanitize()
            full.metrics = metrics
            if full.effort == nil { full.effort = 10 }

            // Persist finalized version locally and push the full track to iPhone.
            FlightDataStore.shared.saveFlight(full)
            connectivityManager.transferFlightToPhone(full)
            print("⌚ ♻️ Recovered unfinished flight after crash: id=\(full.id), locations=\(full.locations.count), distance=\(String(format: "%.2f", metrics.totalDistance/1000))km — saved + synced to iPhone")
        }
    }

    deinit {
        pathMonitor.cancel()
    }

    private func setupLocationUpdates() {
        locationManager.onLocationUpdate = { [weak self] location in
            self?.processNewLocation(location, source: .watchGPS)
        }
        connectivityManager.onIPhoneMotionAccelerationReceived = { [weak self] acceleration, timestamp in
            guard let self = self, self.isActive, !self.isPaused else { return }
            self.currentMetrics.updateWithMotionAcceleration(acceleration, timestamp: timestamp)
        }
        connectivityManager.onIPhoneMotionAssistReceived = { [weak self] assist in
            guard let self = self, self.isActive, !self.isPaused else { return }
            self.latestIPhoneMotionAssist = assist
        }
        // The iPhone's fully-integrated dead-reckoning answer, relayed independently of GPS.
        connectivityManager.onIPhoneDeadReckoningReceived = { [weak self] speed, heading, velN, velE, timestamp in
            guard let self = self, self.isActive, !self.isPaused else { return }
            self.iPhoneDRSpeed = speed
            self.iPhoneDRHeading = heading
            self.iPhoneDRVelocity = (velN, velE)
            self.iPhoneDRTimestamp = timestamp
        }
        locationManager.onBarometricAltitudeUpdate = { [weak self] relativeAltitude, pressure, timestamp in
            guard let self = self, self.isActive, !self.isPaused else { return }
            self.currentMetrics.updateWithBarometricAltitude(
                relativeAltitude: relativeAltitude,
                pressure: pressure,
                timestamp: timestamp
            )
        }

        // Set up iPhone GPS fallback callback
        connectivityManager.onIPhoneLocationReceived = { [weak self] location, mode in
            guard let self = self else { return }
            // Any relayed iPhone fix also supplies a HEADING for dead reckoning. This path
            // runs off the iPhone's GPS-sharing timer, so it does not depend on the iPhone
            // being in a workout or in dead-reckoning itself — which is why the watch used to
            // sit on one heading and draw a straight line. Course-over-ground from a moving
            // fix is the most reliable heading available.
            if let course = self.validCourse(location.course), location.speed > 0.5 {
                self.iPhoneDRHeading = course
                self.iPhoneDRTimestamp = Date()
            }
            switch mode {
            case .fallback:
                print("⌚ 📱 Received GPS from iPhone (fallback mode)")
                self.processNewLocation(location, source: .iphoneFallback)
            case .assist:
                self.processNewLocation(location, source: .iphoneAssist)
            }
        }
    }

    private func setupPedometerObserver() {
        // Observe native pedometer step and distance streams together.
        pedometerManager.$currentStepCount
            .combineLatest(pedometerManager.$currentDistance)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stepCount, distance in
                guard let self = self else { return }
                self.nativePedometerStepCount = stepCount
                self.nativePedometerDistanceMeters = max(0, distance)
                guard self.isActive else { return }
                self.currentMetrics.stepsCount = stepCount > 0 ? Double(stepCount) : nil
                self.currentMetrics.nativeStepDistance = distance > 0 ? distance : nil
            }
            .store(in: &cancellables)

        pedometerManager.$nativeCallbackHz
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hz in
                self?.nativePedometerCallbackHz = hz
            }
            .store(in: &cancellables)

        pedometerManager.$nativeCallbackAgeSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] age in
                self?.nativePedometerCallbackAgeSeconds = age
            }
            .store(in: &cancellables)

        pedometerManager.$queryRefreshAgeSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] age in
                self?.nativePedometerQueryAgeSeconds = age
            }
            .store(in: &cancellables)
    }

    private func setupConnectivityObservers() {
        connectivityManager.$isUsingIPhoneGPS
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isUsingFallback in
                guard let self = self else { return }
                self.isUsingIPhoneGPSFallback = isUsingFallback
                if isUsingFallback {
                    self.setNetworkDebugMessage("iPhone fallback connected - waiting for fresh GPS fix")
                } else if self.isActive && !self.connectivityManager.isIPhoneGPSRequestPending {
                    self.setNetworkDebugMessage("Watch GPS mode active")
                }
                self.refreshNetworkPathStatus()
            }
            .store(in: &cancellables)

        connectivityManager.$isIPhoneGPSRequestPending
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPending in
                guard let self = self else { return }
                if isPending, self.isActive, !self.connectivityManager.isUsingIPhoneGPS {
                    self.setNetworkDebugMessage("iPhone location requested - waiting for first fix")
                } else if self.isActive, !self.connectivityManager.isUsingIPhoneGPS {
                    self.setNetworkDebugMessage("Watch GPS mode active")
                }
                self.refreshNetworkPathStatus()
            }
            .store(in: &cancellables)

        connectivityManager.$isReachable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshNetworkPathStatus()
            }
            .store(in: &cancellables)

        connectivityManager.$shouldStartWorkout
            .sink { [weak self] shouldStart in
                if shouldStart {
                    // Check if iPhone sent a workout type
                    if let workoutTypeRaw = self?.connectivityManager.receivedWorkoutType,
                       let workoutType = HKWorkoutActivityType(rawValue: UInt(workoutTypeRaw)) {
                        print("⌚ Using workout type from iPhone: \(workoutTypeRaw)")
                        self?.setWorkoutType(workoutType)
                        self?.connectivityManager.receivedWorkoutType = nil
                    }

                    self?.startWorkout()
                    self?.connectivityManager.shouldStartWorkout = false
                }
            }
            .store(in: &cancellables)

        connectivityManager.$shouldStopWorkout
            .sink { [weak self] shouldStop in
                if shouldStop {
                    self?.stopWorkout { _ in }
                    self?.connectivityManager.shouldStopWorkout = false
                }
            }
            .store(in: &cancellables)
    }

    func startWorkout() {
        let exportType = healthKitExportType
        print("⌚ Starting workout with type: \(workoutType.rawValue) (HealthKit export: \(exportType.rawValue))")

        // Configure workout with user-selected type
        // NOTE: HKWorkoutSession automatically provides extended runtime - no additional session needed!
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = exportType
        configuration.locationType = .outdoor

        do {
            // Create workout session (watchOS supports HKWorkoutSession)
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()

            // Set delegates
            session.delegate = self
            builder.delegate = self

            // Set data source (watchOS only)
            let dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            if let walkingRunningDistance = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
                dataSource.disableCollection(for: walkingRunningDistance)
            }
            if let cyclingDistance = HKQuantityType.quantityType(forIdentifier: .distanceCycling) {
                dataSource.disableCollection(for: cyclingDistance)
            }
            builder.dataSource = dataSource

            workoutSession = session
            workoutBuilder = builder

            // Start session
            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { [weak self] success, error in
                if success {
                    print("✅ Workout session started successfully")
                    // CRITICAL: Start ALL monitoring and recovery systems
                    self?.startSessionHealthMonitoring()
                    self?.startKeepAliveTimer()
                    self?.startWatchdogTimer()
                    self?.startForceRestartTimer()
                    self?.startPhoneCheckpointTimer()
                } else {
                    print("❌ Failed to start workout session: \(error?.localizedDescription ?? "Unknown error")")
                    // Try to recover
                    self?.attemptSessionRecovery()
                }
            }

            // Initialize flight
            flight = Flight(startDate: startDate)
            flight.workoutType = workoutType.rawValue
            isActive = true

            // Reset location filtering statistics
            skippedLocationCount = 0
            // Restore the standing choice rather than forcing it off, so velocity mode can be
            // on before the first fix is recorded (see iPhone).
            setForceMotionFallback(UserDefaults.standard.bool(forKey: "velocityModeEnabled"), persist: false)
            lastLocationTime = Date()
            latestIPhoneMotionAssist = nil

            let activityType: CLActivityType = (workoutType == .other) ? .airborne : .fitness
            locationManager.updateActivityType(activityType)

            // Start location tracking
            locationManager.startTracking()

            // Start pedometer tracking for step counting
            pedometerManager.startTracking(from: startDate)

            // Start motion updates for dead-reckoning fallback during GPS gaps
            startMotionUpdates()

            // Notify iPhone
            connectivityManager.notifyWorkoutStarted()
            connectivityManager.setDualSourceAssistEnabled(true)
            connectivityManager.requestIPhoneGPS()
            print("⌚ 📱 Requested iPhone relay at workout start (dual-source mode)")

            print("⌚ ✅ Workout started with MAXIMUM REINFORCED background protection:")
            print("⌚ 🏃 HKWorkoutSession: Active (automatic extended runtime)")
            print("⌚ 💚 Health Monitor: Active (15s interval)")
            print("⌚ 💓 Keep-Alive Timer: Active (1s heartbeat)")
            print("⌚ 🔍 Watchdog Timer: Active (10s location arrival check)")
            print("⌚ 🔄 Force Restart Timer: Active (2min preventive GPS restart)")
            print("⌚ 📲 iPhone Checkpoint Timer: Active (10s transfer)")
            print("⌚ 💾 Watch local checkpoint save: Active (preserves GPS + estimated points across crashes)")
            print("⌚ 📍 GPS Tracking: Active")
            print("⌚ 👟 Pedometer: \(pedometerManager.isPedometerAvailable ? "Active (real step counting)" : "Unavailable (using GPS estimation)")")

        } catch {
            print("❌ Failed to create workout session: \(error.localizedDescription)")
            attemptSessionRecovery()
        }
    }

    func refreshCellularFallback() {
        guard isActive else {
            print("⌚ ⚠️ Manual cellular refresh ignored - workout is not active")
            return
        }

        let now = Date()
        if now.timeIntervalSince(lastManualRefreshTapTime) < manualRefreshCooldown {
            print("⌚ ⚠️ Manual cellular refresh ignored - cooldown active")
            setNetworkDebugMessage("Refresh cooldown active")
            return
        }
        lastManualRefreshTapTime = now

        print("⌚ 🔄 Manual cellular refresh triggered by user")
        lastManualRefreshRequestTime = Date()
        setNetworkDebugMessage("Manual refresh sent - waiting for new GPS fix")
        locationManager.refreshCellularFallback()

        if connectivityManager.isUsingIPhoneGPS {
            print("⌚ 📱 Keeping iPhone GPS fallback active (background process preserved)")
            setNetworkDebugMessage("Refresh sent - iPhone fallback remains active")
            return
        }

        if connectivityManager.isIPhoneGPSRequestPending {
            print("⌚ 📱 iPhone GPS fallback already requested - waiting for first fix")
            setNetworkDebugMessage("Refresh sent - waiting for iPhone fallback fix")
        } else {
            print("⌚ 📱 Starting iPhone GPS fallback in parallel (requested by user)")
            connectivityManager.requestIPhoneGPS()
            setNetworkDebugMessage("Refresh sent - iPhone location requested")
        }
    }

    /// Everything that must stop when a workout ends, regardless of HOW it ends. Runs on
    /// EVERY stop path — including the no-session/no-builder early exit, which previously
    /// stopped NOTHING: timers kept firing, the motion fallback kept appending points,
    /// isActive stayed true (so the workout could not actually stop), and forceMotionFallback
    /// stayed latched ON into the next workout.
    private func teardownActiveWorkoutState() {
        // Clear the runtime flag but keep the standing choice for the next workout.
        setForceMotionFallback(false, persist: false)
        if isUsingMotionFallback {
            endMotionFallback(reason: "workout stopped")
        }
        if isUsingPedometerFallback {
            endPedometerFallback(reason: "workout stopped")
        }
        stopSessionHealthMonitoring()
        stopKeepAliveTimer()
        stopWatchdogTimer()
        stopForceRestartTimer()
        stopPhoneCheckpointTimer()
        if connectivityManager.isUsingIPhoneGPS || connectivityManager.isIPhoneGPSRequestPending {
            print("⌚ 📱 Stopping iPhone GPS relay")
            connectivityManager.stopIPhoneGPS()
        }
        connectivityManager.setDualSourceAssistEnabled(false)
        latestIPhoneMotionAssist = nil
        locationManager.stopTracking()
    }

    func stopWorkout(completion: @escaping (Bool) -> Void) {
        guard let session = workoutSession, let builder = workoutBuilder else {
            // No HK session/builder (start raced or failed) — the workout must STILL fully
            // stop: tear down timers/fallbacks/motion and clear isActive before saving.
            print("⌚ ⚠️ Stopping workout without HK session/builder — running full teardown")
            teardownActiveWorkoutState()
            pedometerManager.stopTracking()
            stopMotionUpdates()
            flight.endDate = Date()
            flight.metrics = currentMetrics
            isActive = false
            isPaused = false
            fallbackSaveToHealthKit(locations: flight.locations, endDate: Date()) { success in
                if !success {
                    self.connectivityManager.transferFlightToPhone(self.flight)
                }
                completion(success)
            }
            return
        }

        print("⌚ Stopping workout...")
        print("⌚ 🛑 Stopping all monitoring and recovery systems...")
        teardownActiveWorkoutState()

        // Stop pedometer and get final step count
        pedometerManager.stopTracking()
        stopMotionUpdates()
        let pedometerDistance = pedometerManager.currentDistance
        nativePedometerStepCount = pedometerManager.currentStepCount
        nativePedometerDistanceMeters = max(0, pedometerDistance)
        if pedometerManager.isPedometerAvailable {
            if pedometerManager.currentStepCount > 0 {
                currentMetrics.stepsCount = Double(pedometerManager.currentStepCount)
                print("⌚ 👟 Final step count from pedometer: \(pedometerManager.currentStepCount) steps")
            } else {
                currentMetrics.stepsCount = nil
                print("⌚ 👟 Pedometer returned 0 steps - will estimate from GPS distance")
            }
            if pedometerDistance > 0 {
                currentMetrics.nativeStepDistance = pedometerDistance
            } else {
                currentMetrics.nativeStepDistance = nil
            }
            print("⌚ 👟 Final pedometer distance: \(String(format: "%.2f", pedometerDistance))m")
            print("⌚ 👟 Native step metrics snapshot: steps=\(pedometerManager.currentStepCount), distance=\(String(format: "%.2f", pedometerDistance))m")
            print("⌚ 👟 Native pedometer frequency: \(String(format: "%.2f", nativePedometerCallbackHz))Hz, callback age=\(String(format: "%.1f", nativePedometerCallbackAgeSeconds))s, query age=\(String(format: "%.1f", nativePedometerQueryAgeSeconds))s")
        }

        // CRITICAL: Proper order to avoid finishWorkout hanging
        // 1. Stop activity (not end session yet!)
        let endDate = Date()
        flight.endDate = endDate

        // SAFETY: Validate workout data before proceeding
        guard flight.locations.count > 0 else {
            print("⌚ ⚠️ WARNING: Workout has no locations - saving minimal data")
            flight.metrics = currentMetrics
            transferWorkoutCheckpointToPhone(isFinal: true)
            session.end()
            DispatchQueue.main.async {
                self.isActive = false
            }
            completion(false)
            return
        }

        // 🔒 CRITICAL: Capture distance BEFORE any further processing to ensure accuracy
        // This is the CORRECT distance that was displayed during the workout
        let displayedDistance = currentMetrics.totalDistance
        print("⌚ 🔒 DISTANCE GUARD: Captured displayed distance = \(String(format: "%.2f", displayedDistance/1000))km (\(displayedDistance)m)")
        print("⌚ 🔒 This distance was calculated incrementally during the workout from pre-filtered GPS points")
        print("⌚ 🔒 This is the CORRECT distance - will use this for HealthKit")

        // DO NOT recalculate - the displayed distance is already correct!
        // The incremental distance tracking during workout uses pre-filtered locations from processNewLocation()
        // Recalculating would apply different filters and produce incorrect results

        // Ensure distance is preserved before calculating averages
        currentMetrics.totalDistance = displayedDistance
        // Calculate final metrics
        currentMetrics.calculateAverages(duration: flight.duration)
        currentMetrics.estimateCalories(duration: flight.duration)
        currentMetrics.finalizeSplits()
        currentMetrics.sanitize()  // guard against NaN/Inf before save (local + HealthKit)
        flight.metrics = currentMetrics

        // Prepare HealthKit metrics - ALWAYS use GPS distance (more accurate than pedometer)
        var healthKitMetrics = currentMetrics
        print("⌚ 📏 Using GPS distance for HealthKit: \(String(format: "%.2f", healthKitMetrics.totalDistance))m (\(String(format: "%.3f", healthKitMetrics.totalDistance/1000))km)")
        if pedometerManager.isPedometerAvailable, pedometerDistance > 0 {
            print("⌚ 📊 Native pedometer distance captured: \(String(format: "%.2f", pedometerDistance))m")
        }
        print("⌚ 📊 Distance channels: workoutGPS=\(String(format: "%.2f", healthKitMetrics.totalDistance))m, nativeStepDistance=\(String(format: "%.2f", max(0, nativePedometerDistanceMeters)))m")
        if flight.effort == nil {
            flight.effort = 10
            print("⌚ ⚡️ Effort not set - defaulting to 10")
        }
        if let effort = flight.effort {
            print("⌚ 🧮 Effort saved for workout: \(effort)/10")
        }

        // 🔒 VERIFY: Distance should not have changed
        print("⌚ 🔒 DISTANCE GUARD: After calculateAverages = \(String(format: "%.2f", currentMetrics.totalDistance/1000))km (\(currentMetrics.totalDistance)m)")
        if abs(currentMetrics.totalDistance - displayedDistance) > 0.1 {
            print("⌚ ⚠️⚠️⚠️ CRITICAL BUG: Distance changed after calculateAverages!")
            print("   Before: \(displayedDistance)m")
            print("   After: \(currentMetrics.totalDistance)m")
            print("   Difference: \(currentMetrics.totalDistance - displayedDistance)m")
            // Force restore the correct distance
            currentMetrics.totalDistance = displayedDistance
            flight.metrics = currentMetrics
        }

        // Send one final payload so iPhone receives terminal GPS + native step channels.
        print("⌚ 📲 Sending final workout checkpoint to iPhone")
        transferWorkoutCheckpointToPhone(isFinal: true)
        sendFinalWorkoutUpdateToPhone(endDate: endDate, gpsDistance: displayedDistance)

        // Notify iPhone
        connectivityManager.notifyWorkoutStopped()

        print("⌚ 🏥 Starting HealthKit save (route checkpoints already sent to iPhone)...")
        print("⌚ 📊 Workout summary: \(flight.locations.count) locations, \(String(format: "%.2f", currentMetrics.totalDistance/1000))km")
        if healthKitMetrics.totalDistance != currentMetrics.totalDistance {
            print("⌚ 📊 HealthKit distance override: \(String(format: "%.2f", healthKitMetrics.totalDistance/1000))km")
        }

        // Ensure builder has configuration before proceeding
        guard workoutBuilder?.workoutConfiguration != nil else {
            print("⌚ ❌ CRITICAL: WorkoutBuilder has no configuration - cannot save to HealthKit")
            session.end()
            DispatchQueue.main.async {
                self.isActive = false
                print("⌚ ⚠️ Workout stopped but HealthKit save skipped (data safe locally)")
            }
            completion(false)
            return
        }

        let exportType = healthKitExportType
        print("⌚ 💾 Saving workout to HealthKit:")
        print("   Workout Type: \(exportType.rawValue) (\(exportType == .walking ? "Walking ✅" : exportType == .running ? "Running ✅" : exportType == .cycling ? "Cycling ⚠️" : "Other"))")
        print("   Duration: \(String(format: "%.0f", Date().timeIntervalSince(flight.startDate)))s")
        print("   Distance: \(String(format: "%.2f", currentMetrics.totalDistance/1000))km")

        var metadata: [String: Any] = [
            HKMetadataKeyIndoorWorkout: false,
            HKMetadataKeyTimeZone: TimeZone.current.identifier,
            "totalDistance": displayedDistance,  // 🔒 Use captured displayed distance
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
        print("⌚ 🧭 Save channels: gpsDistance=\(String(format: "%.2f", displayedDistance))m, nativeSteps=\(nativeStepCountText), nativeStepDistance=\(nativeStepDistanceText)m")

        if let effort = flight.effort {
            metadata["effort"] = effort
            print("⌚ 🧮 Adding effort to workout metadata: \(effort)/10")
        } else {
            print("⌚ ⚠️ Effort missing - no effort metadata will be saved")
        }

        if currentMetrics.totalAltitudeGain > 0 {
            metadata[HKMetadataKeyElevationAscended] = HKQuantitySafe(unit: .meter(), doubleValue: currentMetrics.totalAltitudeGain)
        }
        if currentMetrics.totalAltitudeLoss > 0 {
            metadata[HKMetadataKeyElevationDescended] = HKQuantitySafe(unit: .meter(), doubleValue: currentMetrics.totalAltitudeLoss)
        }

        builder.addMetadata(sanitizedHealthKitMetadata(metadata)) { metadataSuccess, metadataError in
            if !metadataSuccess {
                print("⌚ ⚠️ Failed to add workout metadata: \(metadataError?.localizedDescription ?? "Unknown")")
            }

            self.healthKitManager.addWorkoutSamples(
                to: builder,
                metrics: healthKitMetrics,
                activityType: exportType,
                locations: self.flight.locations
            ) {
                // Add calories and step count using our custom calculations.
                self.healthKitManager.addCaloriesAndStepsSamples(
                    to: builder,
                    metrics: healthKitMetrics,
                    startDate: self.flight.startDate,
                    endDate: endDate,
                    activityType: exportType
                ) {
                    self.healthKitManager.addWorkoutTotalDistanceSample(
                        to: builder,
                        metrics: healthKitMetrics,
                        startDate: self.flight.startDate,
                        endDate: endDate,
                        activityType: exportType
                    ) { distanceAdded in
                        if !distanceAdded {
                            print("⌚ ⚠️ GPS workout total distance sample was not added before finish")
                        }

                        // 2. End collection
                        builder.endCollection(withEnd: endDate) { [weak self] success, error in
                            guard let self = self else { return }

                            if success {
                            // 3. Finish workout (MUST be before session.end())
                            builder.finishWorkout { workout, error in
                                if let workout = workout {
                                    self.flight.workoutUUID = workout.uuid
                                    // Push the HealthKit workout UUID to the iPhone so its
                                    // locally-synced track (keyed by the watch flight UUID)
                                    // links to the workout shown in the Workouts tab — even
                                    // when the iPhone was never in a workout.
                                    self.connectivityManager.transferFlightWorkoutLink(
                                        flightID: self.flight.id,
                                        workoutUUID: workout.uuid
                                    )
                                    print("✅ Workout finished successfully")
                                    print("   UUID: \(workout.uuid)")
                                    print("   Type: \(workout.workoutActivityType.rawValue)")
                                    print("   Duration: \(workout.duration)s")
                                    if let distance = workout.totalDistance {
                                        print("   Distance: \(String(format: "%.2f", distance.doubleValue(for: .meter())/1000))km")
                                    }
                                    if let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                                        .sumQuantity()?
                                        .doubleValue(for: .kilocalorie()) {
                                        print("   Energy: \(String(format: "%.0f", energy)) kcal")
                                    }
                                    if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount),
                                       let steps = workout.statistics(for: stepType)?
                                        .sumQuantity()?
                                        .doubleValue(for: .count()) {
                                        print("   Steps (HealthKit): \(String(format: "%.0f", steps))")
                                    } else {
                                        print("   Steps (HealthKit): not available")
                                    }
                                    self.logSavedHealthKitMovementStats(for: workout)

                                    // 4. Associate GPS distance samples AFTER finishWorkout
                                    // This bypasses the HKLiveWorkoutDataSource conflict
                                    self.healthKitManager.associateDistanceSamples(
                                        to: workout,
                                        metrics: healthKitMetrics,
                                        startDate: self.flight.startDate,
                                        endDate: endDate,
                                        activityType: exportType,
                                        includeGPSDistance: !distanceAdded,
                                        includeNativeStepDistance: true
                                    ) { _, _ in
                                        // 5. Save route to the existing workout. CRITICAL: use the FULL
                                        // persisted track from disk — NOT self.flight.locations, which is
                                        // pruned down to minRetainedLocationsOnWatch (2) as points stream to
                                        // the iPhone. Rebuilding the route from the in-memory array would save
                                        // only a 2-point stub (the reported "watch doesn't save the track").
                                        // The watch's FlightDataStore accumulates EVERY point (real AND
                                        // estimated/fallback) on disk via the checkpoints, so load that.
                                        let persisted = FlightDataStore.shared.loadFlightDetails(id: self.flight.id)?.locations ?? []
                                        let routeLocations = persisted.count >= self.flight.locations.count ? persisted : self.flight.locations
                                        print("⌚ 🗺️ Preparing to save route: \(routeLocations.count) locations (in-memory=\(self.flight.locations.count), persisted=\(persisted.count))")
                                        self.healthKitManager.saveRoute(
                                            for: workout,
                                            locations: routeLocations
                                        ) { [weak self] success, error in
                                            guard let self = self else { return }

                                            if success {
                                                print("⌚ ✅ Workout route saved to HealthKit - will appear in Fitness app")
                                            } else {
                                                print("⌚ ❌ Failed to save workout route: \(error?.localizedDescription ?? "Unknown")")
                                            }

                                            if !success {
                                                self.connectivityManager.transferFlightToPhone(self.flight)
                                            }

                                            session.end()

                                            // CRITICAL FIX: Set isActive = false AFTER save completes
                                            DispatchQueue.main.async {
                                                self.isActive = false
                                                print("⌚ ✅ Workout fully stopped and saved")
                                            }
                                            completion(success)
                                        }
                                    }
                                } else {
                                    print("Failed to finish workout: \(error?.localizedDescription ?? "Unknown")")
                                    session.end()

                                    // CRITICAL FIX: Set isActive = false even on failure
                                    DispatchQueue.main.async {
                                        self.isActive = false
                                        print("⌚ ⚠️ Workout stopped with errors (but data saved locally)")
                                    }
                                    self.fallbackSaveToHealthKit(locations: self.flight.locations, endDate: endDate) { success in
                                        if !success {
                                            self.connectivityManager.transferFlightToPhone(self.flight)
                                        }
                                        completion(success)
                                    }
                                }
                            }
                            } else {
                                print("Failed to end collection: \(error?.localizedDescription ?? "Unknown")")
                                session.end()

                                // CRITICAL FIX: Set isActive = false even on failure
                                DispatchQueue.main.async {
                                    self.isActive = false
                                    print("⌚ ⚠️ Workout stopped with errors (but data saved locally)")
                                }
                                self.fallbackSaveToHealthKit(locations: self.flight.locations, endDate: endDate) { success in
                                    if !success {
                                        self.connectivityManager.transferFlightToPhone(self.flight)
                                    }
                                    completion(success)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func fallbackSaveToHealthKit(
        locations: [FlightLocation],
        endDate: Date,
        completion: @escaping (Bool) -> Void
    ) {
        print("⌚ ⚠️ Falling back to direct HealthKit save (builder path failed)")
        let doSave = {
            self.healthKitManager.saveWorkout(
                flight: self.flight,
                locations: locations,
                metrics: self.currentMetrics
            ) { success, error in
                if success {
                    print("⌚ ✅ Fallback workout saved to HealthKit")
                } else {
                    print("⌚ ❌ Fallback HealthKit save failed: \(error?.localizedDescription ?? "Unknown")")
                }
                completion(success)
            }
        }

        if healthKitManager.isAuthorized {
            doSave()
        } else {
            healthKitManager.requestAuthorization { success, error in
                if success {
                    doSave()
                } else {
                    print("⌚ ❌ HealthKit authorization failed for fallback: \(error?.localizedDescription ?? "Unknown")")
                    completion(false)
                }
            }
        }
    }

    private func logSavedHealthKitMovementStats(for workout: HKWorkout) {
        let queryList: [(HKQuantityTypeIdentifier, String)] = [
            (.distanceWalkingRunning, "distanceWalkingRunning"),
            (.distanceCycling, "distanceCycling"),
            (.stepCount, "stepCount")
        ]

        let group = DispatchGroup()
        let linesQueue = DispatchQueue(label: "com.gpsapp.watch.hkstats.log")
        var lines: [String] = []

        for (identifier, label) in queryList {
            group.enter()
            healthKitManager.fetchCumulativeQuantitySum(for: workout, identifier: identifier) { value, error in
                defer { group.leave() }
                if let error = error {
                    linesQueue.sync {
                        lines.append("   \(label): error=\(error.localizedDescription)")
                    }
                    return
                }

                guard let value else {
                    linesQueue.sync {
                        lines.append("   \(label): nil")
                    }
                    return
                }

                switch identifier {
                case .distanceWalkingRunning, .distanceCycling:
                    linesQueue.sync {
                        lines.append("   \(label): \(String(format: "%.2f", value))m (\(String(format: "%.3f", value / 1000.0))km)")
                    }
                case .stepCount:
                    linesQueue.sync {
                        lines.append("   \(label): \(String(format: "%.0f", value))")
                    }
                default:
                    linesQueue.sync {
                        lines.append("   \(label): \(value)")
                    }
                }
            }
        }

        group.notify(queue: .main) {
            let sortedLines = linesQueue.sync { lines.sorted() }
            print("⌚ 🧪 HealthKit movement totals linked to workout \(workout.uuid):")
            sortedLines.forEach { print($0) }
        }
    }

    // MARK: - Session Health Monitoring

    private func startSessionHealthMonitoring() {
        // AGGRESSIVE: Monitor session health every 15 seconds (was 30)
        sessionHealthTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.checkSessionHealth()
        }
        // CRITICAL: Add to RunLoop to ensure it runs in background
        RunLoop.main.add(sessionHealthTimer!, forMode: .common)
        print("⌚ 💚 Session health monitoring started (15s interval)")
    }

    private func stopSessionHealthMonitoring() {
        sessionHealthTimer?.invalidate()
        sessionHealthTimer = nil
        print("⌚ 💚 Session health monitoring stopped")
    }

    private func checkSessionHealth() {
        guard isActive else { return }

        // Check if we're still getting locations
        let timeSinceLastLocation = Date().timeIntervalSince(lastLocationTime)

        // AGGRESSIVE: Attempt recovery earlier (30s instead of 60s)
        if timeSinceLastLocation > 30 {
            print("⌚ ⚠️ WARNING: No location updates for \(Int(timeSinceLastLocation))s - attempting recovery")
            attemptLocationRecovery()
        }

        // Check if workout session is still valid
        guard let session = workoutSession else {
            print("⌚ ❌ CRITICAL: Workout session is nil - attempting recovery")
            attemptSessionRecovery()
            return
        }

        // Log session state
        let sessionStateText = session.state == .running ? "Running✅" : "State\(session.state.rawValue)"
        print("⌚ 💚 Health check: \(sessionStateText), Locations=\(flight.locations.count), GPS_Delay=\(Int(timeSinceLastLocation))s, Builder=\(workoutBuilder != nil ? "✅" : "❌")")
    }

    // MARK: - Keep-Alive Timer (Prevents watchOS from suspending app)

    private func startKeepAliveTimer() {
        // CRITICAL: Fire every 1 second to keep app alive
        // Updates @Published properties to force UI refresh, preventing suspension
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isActive else { return }

            // Touch @Published property to keep SwiftUI active
            // This is a legitimate watchOS technique to prevent app suspension during workouts
            self.objectWillChange.send()

            // GPS-gap fallbacks (tunnels, underground, train, plane).
            // Motion fallback runs FIRST — it's the primary fallback for all
            // activity types. Pedometer is a secondary that only kicks in if
            // motion fallback isn't adding distance.
            if !self.isPaused {
                self.runGpsGapFallbacksTick(source: "keepAlive")
            }

            // Every 10 seconds, log that we're still alive
            let elapsed = Date().timeIntervalSince(self.flight.startDate)
            if Int(elapsed).isMultiple(of: 10) {
                let gpsDelay = Date().timeIntervalSince(self.lastLocationTime)
                let fallbackStatus = self.isUsingPedometerFallback ? " [PEDOMETER FALLBACK +\(String(format: "%.1f", self.pedometerFallbackDistanceAdded))m]" : ""
                print("⌚ 💓 ALIVE: \(Int(elapsed))s elapsed, \(self.flight.locations.count) locations, GPS delay: \(Int(gpsDelay))s\(fallbackStatus)")
            }
        }
        // CRITICAL: Add to RunLoop to ensure it runs in background
        RunLoop.main.add(keepAliveTimer!, forMode: .common)
        print("⌚ 💓 Keep-alive timer started (1s heartbeat)")
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        print("⌚ 💓 Keep-alive timer stopped")
    }

    // MARK: - Watchdog Timer (CRITICAL: Detects when locations ACTUALLY stop arriving)

    private func startWatchdogTimer() {
        // AGGRESSIVE: Check every 10 seconds if locations are ACTUALLY arriving
        // This catches the case where GPS looks good but locations aren't coming through
        lastLocationCount = flight.locations.count

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.checkLocationArrival()
        }
        RunLoop.main.add(watchdogTimer!, forMode: .common)
        print("⌚ 🔍 Watchdog timer started - will detect if locations stop arriving")
    }

    private func stopWatchdogTimer() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        print("⌚ 🔍 Watchdog timer stopped")
    }

    private func checkLocationArrival() {
        guard isActive && !isPaused else { return }

        let currentCount = flight.locations.count
        let newLocations = currentCount - lastLocationCount

        if newLocations == 0 {
            // CRITICAL: No new locations in the last 10 seconds
            let timeSinceLastGPS = Date().timeIntervalSince(lastLocationTime)
            print("⌚ 🚨 WATCHDOG ALERT: ZERO locations received in last 10s! GPS delay: \(Int(timeSinceLastGPS))s")
            print("⌚ 🚨 Location count stuck at: \(currentCount)")
            print("⌚ 🚨 GPS Signal Quality: \(locationManager.gpsSignalQuality.description)")

            // Mark watch GPS as failing
            if !isWatchGPSFailing {
                isWatchGPSFailing = true
                watchGPSFailureStartTime = Date()
            }

            // Request iPhone GPS fallback if watch GPS has been failing and iPhone is available
            if timeSinceLastGPS >= WATCH_GPS_FAILURE_THRESHOLD &&
               !connectivityManager.isUsingIPhoneGPS &&
               !connectivityManager.isIPhoneGPSRequestPending {
                print("⌚ 📱 Watch GPS failed for \(Int(timeSinceLastGPS))s - requesting iPhone GPS fallback")
                connectivityManager.requestIPhoneGPS()
                setNetworkDebugMessage("Auto iPhone fallback requested after \(Int(timeSinceLastGPS))s without fix")
            }

            print("⌚ 🚨 FORCING AGGRESSIVE RECOVERY NOW...")
            // Still attempt watch GPS recovery in parallel
            forceGPSRestart()
        } else {
            // Good - locations are arriving from watch GPS
            let rate = Double(newLocations) / 10.0  // locations per second
            print("⌚ 🔍 Watchdog check: \(newLocations) new locations in 10s (rate: \(String(format: "%.1f", rate))/s) ✅")

            // Watch GPS recovered - stop iPhone GPS fallback if active
            if isWatchGPSFailing {
                isWatchGPSFailing = false
                watchGPSFailureStartTime = nil

                if connectivityManager.isUsingIPhoneGPS && !connectivityManager.isDualSourceAssistEnabled {
                    print("⌚ ✅ Watch GPS recovered - stopping iPhone GPS fallback")
                    connectivityManager.stopIPhoneGPS()
                }
            }
        }

        lastLocationCount = currentCount
    }

    // MARK: - Force Restart Timer (Preventive GPS maintenance)

    private func startForceRestartTimer() {
        // PREVENTIVE: Force restart GPS every 2 minutes to prevent drift/hanging
        // Even if everything looks fine, restart periodically as insurance
        forceRestartTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: true) { [weak self] _ in
            self?.preventiveGPSRestart()
        }
        RunLoop.main.add(forceRestartTimer!, forMode: .common)
        print("⌚ 🔄 Force restart timer started - preventive GPS restart every 2min")
    }

    private func stopForceRestartTimer() {
        forceRestartTimer?.invalidate()
        forceRestartTimer = nil
        print("⌚ 🔄 Force restart timer stopped")
    }

    // MARK: - iPhone Checkpoint Timer (Memory Crash Prevention)

    private func startPhoneCheckpointTimer() {
        lastPhoneCheckpointLocationCount = 0
        retainedLocationOffset = 0
        phoneCheckpointTimer?.invalidate()
        phoneCheckpointTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.transferWorkoutCheckpointToPhone()
        }
        RunLoop.main.add(phoneCheckpointTimer!, forMode: .common)
        print("⌚ 📲 iPhone checkpoint timer started - transfer every 10s")
    }

    private func stopPhoneCheckpointTimer() {
        phoneCheckpointTimer?.invalidate()
        phoneCheckpointTimer = nil
        print("⌚ 📲 iPhone checkpoint timer stopped")
    }

    // MARK: - Pedometer Fallback for GPS Gaps

    private func checkPedometerFallback() {
        // Defer to motion fallback when it's actively adding distance to avoid
        // double-counting (motion is the primary fallback).
        if isUsingMotionFallback && motionFallbackDistanceAdded > 0 {
            if isUsingPedometerFallback {
                endPedometerFallback(reason: "motion fallback is primary")
            }
            return
        }
        let timeSinceLastGPS = Date().timeIntervalSince(lastLocationTime)
        let isStepBasedActivity = (workoutType == .walking || workoutType == .running || workoutType == .hiking)

        // Only use pedometer fallback for step-based activities where pedometer is running
        guard isStepBasedActivity, pedometerManager.isPedometerAvailable else {
            if isUsingPedometerFallback {
                endPedometerFallback(reason: "activity not step-based or pedometer unavailable")
            }
            return
        }

        if !isUsingPedometerFallback {
            // Check if we should START pedometer fallback
            if timeSinceLastGPS >= GPS_GAP_THRESHOLD {
                startPedometerFallback()
            }
        } else {
            // Already in pedometer fallback — accumulate distance
            let currentPedometerDistance = pedometerManager.currentDistance
            let pedometerDelta = currentPedometerDistance - pedometerDistanceAtGapStart

            // Only add positive increments (pedometer should only grow)
            if pedometerDelta > pedometerFallbackDistanceAdded {
                let newDistance = pedometerDelta - pedometerFallbackDistanceAdded
                appendEstimatedPedometerFallbackLocation(distanceMeters: newDistance, timestamp: Date())
                pedometerFallbackDistanceAdded = pedometerDelta
                fallbackDebugStatus = String(format: "Steps DR +%.0fm", pedometerFallbackDistanceAdded)

                // Log every 5 seconds to avoid spam
                let now = Date()
                if now.timeIntervalSince(lastPedometerFallbackLogTime) >= 5.0 {
                    print("⌚ 🦶 PEDOMETER FALLBACK: +\(String(format: "%.1f", pedometerFallbackDistanceAdded))m added (GPS gap: \(Int(timeSinceLastGPS))s, total: \(String(format: "%.2f", currentMetrics.totalDistance/1000))km)")
                    lastPedometerFallbackLogTime = now
                }
            }
        }
    }

    private func startPedometerFallback() {
        isUsingPedometerFallback = true
        pedometerDistanceAtGapStart = pedometerManager.currentDistance
        gpsDistanceAtGapStart = currentMetrics.totalDistance
        pedometerFallbackDistanceAdded = 0.0
        pedometerFallbackStartTime = Date()
        lastPedometerFallbackLogTime = Date()

        let timeSinceLastGPS = Date().timeIntervalSince(lastLocationTime)
        print("⌚ 🦶 PEDOMETER FALLBACK STARTED: GPS lost for \(Int(timeSinceLastGPS))s")
        print("⌚ 🦶 Pedometer baseline: \(String(format: "%.2f", pedometerDistanceAtGapStart))m")
        print("⌚ 🦶 GPS distance at gap start: \(String(format: "%.2f", gpsDistanceAtGapStart/1000))km")
        print("⌚ 🦶 Will use pedometer incremental distance until GPS returns")
    }

    /// A geographic origin to dead-reckon FROM when a fallback gap begins before any GPS
    /// fix was recorded (workout started underground / in-flight). Prefers the iPhone's
    /// last-known relay position (a real-world coordinate, stale is fine), then the
    /// watch's own last-known GPS. Returns nil only if neither exists anywhere.
    private func syntheticFallbackAnchor(at timestamp: Date) -> FlightLocation? {
        // FRESHNESS IS MANDATORY: a stale last-known position (previous workout, kilometres
        // away) anchored the whole route there and then drew a long straight line to the true
        // position once it was known. No anchor is better than a wrong one.
        let coordinate: CLLocationCoordinate2D
        let altitude: Double
        if let relay = lastIPhoneRelayCoord,
           timestamp.timeIntervalSince(lastIPhoneRelayTime ?? .distantPast) < 120 {
            coordinate = CLLocationCoordinate2D(latitude: relay.lat, longitude: relay.lon)
            altitude = locationManager.currentLocation?.altitude ?? currentMetrics.currentAltitude
        } else if let known = locationManager.currentLocation,
                  timestamp.timeIntervalSince(known.timestamp) < 120,
                  known.horizontalAccuracy >= 0, known.horizontalAccuracy < 200 {
            coordinate = known.coordinate
            altitude = known.altitude
        } else {
            return nil
        }
        // Timestamp the seed slightly earlier so the first dead-reckoned point that
        // follows has a strictly-later timestamp (clean ordering for the HK route).
        let seed = CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: ESTIMATED_LOCATION_HORIZONTAL_ACCURACY,
            verticalAccuracy: ESTIMATED_LOCATION_VERTICAL_ACCURACY,
            course: 0,
            speed: 0,
            timestamp: timestamp.addingTimeInterval(-0.5)
        )
        return FlightLocation(
            from: seed,
            isFiltered: false,
            isValid: true,
            signalStrength: 20.0,
            pressure: locationManager.currentPressure,
            isEstimated: true
        )
    }

    /// Linearly warp the trailing run of dead-reckoned points so the DR path from the last
    /// real GPS anchor lands on the new GPS fix. Drift is distributed by distance travelled,
    /// preserving the path's shape while bounding error to both anchors. Distance is
    /// reconciled for the corrected geometry. Mirrors the iPhone implementation.
    private func rubberSheetEstimatedGap(onto fix: FlightLocation) {
        var start = flight.locations.count
        while start > 0 && flight.locations[start - 1].isEstimated { start -= 1 }
        let n = flight.locations.count - start
        guard n > 0, start > 0 else { return }
        let anchor = flight.locations[start - 1]

        var cumulative = [Double](repeating: 0, count: n)
        var previous = anchor
        var oldGapLength = 0.0
        for k in 0..<n {
            oldGapLength += flight.locations[start + k].distance(to: previous)
            cumulative[k] = oldGapLength
            previous = flight.locations[start + k]
        }
        guard oldGapLength > 0.5 else { return }

        let last = flight.locations[start + n - 1]
        let driftNorth = (fix.latitude - last.latitude) * 111_320.0
        let driftEast = (fix.longitude - last.longitude) * 111_320.0 * cos(last.latitude * .pi / 180)
        let driftMagnitude = sqrt(driftNorth * driftNorth + driftEast * driftEast)
        guard driftMagnitude > 3.0 else { return }

        for k in 0..<n {
            let fraction = cumulative[k] / oldGapLength
            flight.locations[start + k] = flight.locations[start + k]
                .movedHorizontally(north: driftNorth * fraction, east: driftEast * fraction)
        }

        var newGapLength = 0.0
        previous = anchor
        for k in 0..<n {
            newGapLength += flight.locations[start + k].distance(to: previous)
            previous = flight.locations[start + k]
        }
        currentMetrics.totalDistance = max(0, currentMetrics.totalDistance + (newGapLength - oldGapLength))
        print("⌚ 📍 Rubber-sheet: warped \(n) DR points onto GPS (drift \(String(format: "%.0f", driftMagnitude))m, Δdist \(String(format: "%+.0f", newGapLength - oldGapLength))m)")
    }

    private func appendEstimatedPedometerFallbackLocation(distanceMeters: Double, timestamp: Date,
                                                          speedMetersPerSecond: Double? = nil) {
        // Zero distance is allowed: a heartbeat point records "we were here and not moving",
        // which is a genuine observation and the only thing that keeps a stalled estimator from
        // producing a completely empty track.
        guard distanceMeters >= 0.0 else { return }

        // Resolve the point to dead-reckon FROM. Normally the last recorded location.
        // But a workout that STARTS with no GPS (basement / subway / airplane) has no
        // prior point — so seed the track from the best available real-world position:
        // the iPhone's last-known relay (stale is fine) or the watch's own last-known
        // GPS. This lets the velocity/step fallback lay down a real ESTIMATED track
        // instead of just a distance number. Only if NO position exists anywhere do we
        // fall back to distance-only (a coordinate is impossible with zero reference).
        let previousLocation: FlightLocation
        if let last = flight.locations.last {
            previousLocation = last
        } else if let seed = syntheticFallbackAnchor(at: timestamp) {
            flight.locations.append(seed)   // becomes the origin; we dead-reckon from it
            previousLocation = seed
            print("⌚ 🧭 Fallback seeded synthetic anchor (no GPS yet) at \(String(format: "%.5f", seed.latitude)),\(String(format: "%.5f", seed.longitude))")
        } else {
            // Truly no geographic reference anywhere — accumulate distance-only so the
            // workout still records progress (can't place a point without any anchor).
            currentMetrics.totalDistance += distanceMeters
            let dt = max(timestamp.timeIntervalSince(lastAnchorlessFallbackTime ?? timestamp), 0.5)
            let speed = distanceMeters / dt
            currentMetrics.currentSpeed = speed
            currentMetrics.smoothedSpeed = speed
            lastAnchorlessFallbackTime = timestamp
            currentMetrics.updateSplits(startDate: flight.startDate)
            let now = Date()
            if now.timeIntervalSince(lastPhoneSyncTime) >= 1.0 {
                sendWorkoutUpdateToPhone()
                lastPhoneSyncTime = now
            }
            return
        }

        // While the velocity (motion) fallback is active, steer the estimated track by
        // the heading DERIVED FROM THE VELOCITY VECTOR (it turns as you turn) instead of
        // a fixed bearing — otherwise the route is a straight line (the reported bug).
        let headingDegrees: Double
        if isUsingMotionFallback && motionFallbackSpeed > 0.1 {
            headingDegrees = normalizedHeading(motionHeadingDegrees)
        } else {
            headingDegrees = normalizedHeading(
                recentIPhoneMotionAssist(near: timestamp)?.directionDegrees
                    ?? validCourse(previousLocation.course)
                    ?? 0.0
            )
        }
        let coordinate = projectedCoordinate(
            from: CLLocationCoordinate2D(latitude: previousLocation.latitude, longitude: previousLocation.longitude),
            distanceMeters: distanceMeters,
            bearingDegrees: headingDegrees
        )
        let timeDelta = max(timestamp.timeIntervalSince(previousLocation.timestamp), 0.5)
        let location = CLLocation(
            coordinate: coordinate,
            altitude: previousLocation.altitude,
            horizontalAccuracy: ESTIMATED_LOCATION_HORIZONTAL_ACCURACY,
            verticalAccuracy: ESTIMATED_LOCATION_VERTICAL_ACCURACY,
            course: headingDegrees,
            speed: distanceMeters / timeDelta,
            timestamp: timestamp
        )
        let estimatedLocation = FlightLocation(
            from: location,
            isFiltered: false,
            isValid: true,
            signalStrength: 20.0,
            pressure: locationManager.currentPressure,
            isEstimated: true
        )

        flight.locations.append(estimatedLocation)
        let maxSpeedBeforeUpdate = currentMetrics.maxSpeed
        currentMetrics.updateWithLocation(
            estimatedLocation,
            previousLocation: previousLocation,
            elapsedTime: Date().timeIntervalSince(flight.startDate)
        )
        // The dead-reckoning speed is authoritative. FlightMetrics otherwise RE-DERIVES speed
        // from point geometry (distance ÷ timeDelta) — a different calculation from the DR
        // estimate, so the Speed display and the Velocity Mode status line disagreed. It is
        // also spiky when several ticks batch into one point, which produced absurd max
        // speeds. Never let a geometric spike raise max speed.
        if let drSpeed = speedMetersPerSecond {
            currentMetrics.currentSpeed = drSpeed
            currentMetrics.smoothedSpeed = drSpeed
            currentMetrics.maxSpeed = max(maxSpeedBeforeUpdate, drSpeed)
        }
        currentMetrics.currentPressure = locationManager.currentPressure
        currentMetrics.updateSplits(startDate: flight.startDate)
        pruneWatchMemoryIfNeeded(reason: "estimatedLocation")

        let now = Date()
        if now.timeIntervalSince(lastPhoneSyncTime) >= 1.0 {
            sendWorkoutUpdateToPhone()
            lastPhoneSyncTime = now
        }
    }

    /// Called when a valid GPS location arrives after a pedometer fallback period.
    /// Does NOT recalculate distance — just ends the fallback and resumes GPS tracking.
    private func endPedometerFallback(reason: String) {
        guard isUsingPedometerFallback else { return }

        print("⌚ 🦶 PEDOMETER FALLBACK ENDED: \(reason)")
        print("⌚ 🦶 Pedometer distance added during gap: +\(String(format: "%.1f", pedometerFallbackDistanceAdded))m")
        print("⌚ 🦶 Total distance now: \(String(format: "%.2f", currentMetrics.totalDistance/1000))km")

        isUsingPedometerFallback = false
        pedometerFallbackDistanceAdded = 0.0
        pedometerDistanceAtGapStart = 0.0
        gpsDistanceAtGapStart = 0.0
        pedometerFallbackStartTime = nil
        lastAnchorlessFallbackTime = nil
    }

    // MARK: - Motion (Accelerometer) Fallback for GPS Gaps
    //
    // For non-step activities (cycling, train, etc.) where the pedometer can't
    // help, integrate device-motion accelerometer to estimate distance during
    // GPS outages. Estimated coords are projected onto the route and counted
    // toward currentMetrics.totalDistance (the same GPS-route distance the map
    // and saved workout use).

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            print("⌚ 🧭 Device motion unavailable — motion fallback disabled")
            return
        }
        // 50 Hz: verified in simulation to cut dead-reckoning drift ~4× vs 10 Hz
        // (stationary phantom distance 24 m → 6 m over 5 min). Cost is negligible — the
        // sensors run anyway and the handler is a few multiplications per sample.
        motionManager.deviceMotionUpdateInterval = 0.02
        // Use a Z-vertical reference frame so acceleration can be rotated into a WORLD
        // frame (X/Y horizontal, Z up). Prefer magnetic north so the route heading is
        // geographically meaningful; else an arbitrary-but-consistent X axis (route
        // shape/distance still correct, orientation arbitrary).
        let available = CMMotionManager.availableAttitudeReferenceFrames()
        let refFrame: CMAttitudeReferenceFrame =
            available.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical : .xArbitraryZVertical
        // `.xArbitraryZVertical` has a vertical Z but an X axis pointing in an UNKNOWN
        // direction: route SHAPE and distance stay valid, absolute bearing does not.
        motionFrameIsAbsolute = available.contains(.xMagneticNorthZVertical)
        if !motionFrameIsAbsolute {
            print("⌚ ⚠️ Magnetic-north attitude frame unavailable — DR direction falls back to GPS course")
        }
        let handler: CMDeviceMotionHandler = { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            let a = motion.userAcceleration     // linear accel, gravity removed (g units)
            let g = motion.gravity              // gravity direction in the device frame
            let r = motion.attitude.rotationMatrix
            // Rotate the (gravity-free) acceleration from the device frame into the WORLD
            // frame. Apple's matrix convention (R·v vs Rᵀ·v) is resolved robustly: pick
            // whichever rotation makes GRAVITY vertical (its Z the largest), which is the
            // true device→world rotation. This guarantees vertical motion (an elevator)
            // lands in world-Z and is DROPPED — it can never inflate horizontal distance.
            let gRowZ = r.m31*g.x + r.m32*g.y + r.m33*g.z
            let gColZ = r.m13*g.x + r.m23*g.y + r.m33*g.z
            var axW: Double, ayW: Double
            let azW: Double
            if abs(gRowZ) >= abs(gColZ) {
                axW = (r.m11*a.x + r.m12*a.y + r.m13*a.z) * 9.81   // world X (≈ north)
                ayW = (r.m21*a.x + r.m22*a.y + r.m23*a.z) * 9.81   // world Y (≈ west)
                azW = (r.m31*a.x + r.m32*a.y + r.m33*a.z) * 9.81   // world Z (up)
            } else {
                axW = (r.m11*a.x + r.m21*a.y + r.m31*a.z) * 9.81
                ayW = (r.m12*a.x + r.m22*a.y + r.m32*a.z) * 9.81
                azW = (r.m13*a.x + r.m23*a.y + r.m33*a.z) * 9.81
            }
            // MAGNETIC -> TRUE north. The attitude reference frame is magnetic north, but GPS
            // course and every saved coordinate are true north; without this the whole
            // dead-reckoned route is rotated by the local declination (up to ~15°).
            let decl = self.locationManager.magneticDeclinationDegrees
            if decl != 0 && self.motionFrameIsAbsolute {
                // World Y is WEST, so the horizontal pair here is (north, west): rotating by
                // +declination in the north/east sense is a −declination rotation in this one.
                let dr = -decl * .pi / 180
                let c = cos(dr), s = sin(dr)
                let n = axW, w = ayW
                axW = n * c - w * s
                ayW = n * s + w * c
            }
            // Light low-pass, time-constant corrected: a fixed 0.7/0.3 blend has a different
            // corner frequency at every sample rate, so derive alpha from the real dt.
            let sampleDt: TimeInterval
            if let previous = self.lastMotionSampleTimestamp {
                sampleDt = min(max(motion.timestamp - previous, 0.0), 1.0)
            } else {
                sampleDt = 0.0
            }
            self.lastMotionSampleTimestamp = motion.timestamp
            guard sampleDt > 0 else { return }
            let tau = 0.15
            let alpha = min(sampleDt / (tau + sampleDt), 1.0)
            self.worldAccelX += (axW - self.worldAccelX) * alpha
            self.worldAccelY += (ayW - self.worldAccelY) * alpha
            self.motionAttitudeReady = true
            let hx = a.x * 9.81, hy = a.y * 9.81
            self.lastMotionForwardAccel = self.lastMotionForwardAccel * 0.7 + sqrt(hx*hx + hy*hy) * 0.3

            // SENSOR-RATE integration (correct numerical integration — NOT 1 Hz sampling).
            // Integrate the acceleration VECTOR into the velocity VECTOR every sample while
            // the velocity fallback owns distance in an accel-integrating mode (forced, or
            // any non-step activity). Signed ⇒ deceleration subtracts and bumps cancel.
            // Device +Y axis heading from the gyro-fused attitude (see yawHeadingOffset).
            // Transforming the unit vector (0,1,0) collapses the same convention branches to
            // single matrix elements: row-dominant → (m12, m22), column-dominant → (m21, m22).
            let yawN: Double, yawW: Double
            if abs(gRowZ) >= abs(gColZ) { yawN = r.m12; yawW = r.m22 }
            else { yawN = r.m21; yawW = r.m22 }
            if yawN * yawN + yawW * yawW > 0.05 {
                var yawHeading = atan2(-yawW, yawN) * 180 / .pi
                if self.motionFrameIsAbsolute { yawHeading += decl }
                if yawHeading < 0 { yawHeading += 360 } else if yawHeading >= 360 { yawHeading -= 360 }
                self.deviceYawHeadingDegrees = yawHeading
            }

            let rot = motion.rotationRate
            let rotMag = sqrt(rot.x*rot.x + rot.y*rot.y + rot.z*rot.z)
            // Heading-change from the gyro's component about the world-VERTICAL (gravity) axis
            // — no singularity, orientation-independent (see the iPhone LocationManager). Arm
            // swing oscillates and averages out; the NET rotation over a turn is the body's
            // heading change. This lets the watch turn on its OWN sensors, not only via the
            // relay.
            let gg = motion.gravity
            let ggMag = sqrt(gg.x*gg.x + gg.y*gg.y + gg.z*gg.z)
            if ggMag > 0.1 {
                let verticalRate = (rot.x*gg.x + rot.y*gg.y + rot.z*gg.z) / ggMag
                self.cumulativeYawRotationDeg += verticalRate * sampleDt * 180.0 / .pi
            }
            // The residual integration (ZUPT + gated bias + trapezoid) is factored into a
            // shared method so the synthetic-flight replay drives the EXACT same code path.
            self.integrateWorldMotionResidual(dt: sampleDt, up: azW, rotationRate: rotMag)
        }
        motionManager.startDeviceMotionUpdates(using: refFrame, to: OperationQueue.main, withHandler: handler)
        print("⌚ 🧭 Device motion updates started (world-frame dead reckoning armed, ref=\(refFrame.rawValue))")
    }

    private func stopMotionUpdates() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        isUsingMotionFallback = false
        motionFallbackSpeed = 0.0
        motionFallbackDistanceAdded = 0.0
        yawHeadingOffset = nil
        lastPedometerDistanceForDR = nil
        lastCumulativeYawForHeading = nil
        smoothedPedometerSpeedWatch = 0
        lastPedometerUpdateTimeWatch = nil
        pdrAppendedDistanceWatch = 0
        pendingMotionDistance = 0
        motionVelX = 0.0; motionVelY = 0.0
        accelBiasX = 0.0; accelBiasY = 0.0
        prevResidualX = 0.0; prevResidualY = 0.0
        zuptWindow.removeAll(); zuptWindowFilled = false; isInertialStationary = false; lastMotionSampleTimestamp = nil
        longRunMeanX = 0; longRunMeanY = 0
        worldAccelX = 0.0; worldAccelY = 0.0
        motionAttitudeReady = false
        lastMotionFallbackTick = nil
        lastMotionForwardAccel = 0.0
    }

    /// Residual integration shared by the real device-motion handler and the synthetic-flight
    /// replay: gates on forced/non-step mode, runs the ZUPT stationarity check, learns the
    /// gated bias, and trapezoidally integrates the world-frame residual into the velocity
    /// vector. Operates on the already-low-passed `worldAccelX/Y` (X≈north, Y≈west).
    /// Count footfalls in the vertical acceleration — identical to the iPhone's detector, so
    /// both devices call the same motion a step.
    private func detectStep(verticalResidual up: Double, dt: TimeInterval) {
        let tau = 0.5
        let alpha = min(dt / (tau + dt), 1.0)
        stepDetectSlowVertical += (up - stepDetectSlowVertical) * alpha
        let highPassed = up - stepDetectSlowVertical

        if stepDetectArmed, highPassed > STEP_PEAK_ACCEL {
            let now = Date()
            let sinceLast = imuStepTimes.last.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            if sinceLast >= STEP_MIN_INTERVAL {
                imuStepTimes.append(now)
                imuStepsPendingTick += 1
                if imuStepTimes.count > 12 { imuStepTimes.removeFirst() }
            }
            stepDetectArmed = false
        } else if highPassed < STEP_RESET_ACCEL {
            stepDetectArmed = true
        }
    }

    private func integrateWorldMotionResidual(dt dtS: Double, up azW: Double, rotationRate rotMag: Double) {
        guard isUsingMotionFallback else { return }

        // These run for EVERY workout type, before the vehicle-only integration guard below:
        // knowing whether the feet are moving is exactly as useful on a walk as in a car, and
        // the iPhone makes the same measurements at the same rate.
        let residualX = worldAccelX - accelBiasX
        let residualY = worldAccelY - accelBiasY
        let residualMagnitude = sqrt(residualX * residualX + residualY * residualY + azW * azW)
        if residualMagnitude < PEDESTRIAN_STILL_ACCEL && rotMag < PEDESTRIAN_STILL_ROTATION {
            pedestrianQuietDuration += dtS
        } else {
            pedestrianQuietDuration = 0
        }
        detectStep(verticalResidual: azW, dt: dtS)
        // Velocity change along the direction of travel, for the held vehicle speed. Only real
        // acceleration accumulates — below the floor this is bias (Y is WEST, hence the minus).
        let travelRadians = motionHeadingDegrees * .pi / 180
        let alongTrack = residualX * cos(travelRadians) - residualY * sin(travelRadians)
        if abs(alongTrack) > HELD_SPEED_ACCEL_FLOOR {
            heldSpeedCorrection = min(max(heldSpeedCorrection + alongTrack * dtS, -DR_MAX_SPEED), DR_MAX_SPEED)
        }

        let isStep = (workoutType == .walking || workoutType == .running || workoutType == .hiking)
        guard forceMotionFallback || !isStep else { return }

        let rX = worldAccelX - accelBiasX
        let rY = worldAccelY - accelBiasY
        let accelMag3D = sqrt(rX * rX + rY * rY + azW * azW)
        let sampleTime = (zuptWindow.last?.t ?? 0) + dtS
        zuptWindow.append((t: sampleTime, accel: accelMag3D, rotation: rotMag))
        while let first = zuptWindow.first, sampleTime - first.t > ZUPT_WINDOW {
            zuptWindow.removeFirst()
            zuptWindowFilled = true
        }
        let peakAccel = zuptWindow.map(\.accel).max() ?? 0
        let peakRotation = zuptWindow.map(\.rotation).max() ?? 0
        // Only STOPPED when also slow. A body coasting at constant velocity (cruise) has ~zero
        // accel and rotation too, so without the speed gate ZUPT zeroed real cruise velocity —
        // a plane at 900 km/h read as stopped. Above the gate, hold velocity (v = v₀ + a·dt).
        let currentSpeed = sqrt(motionVelX * motionVelX + motionVelY * motionVelY)
        // Tier 1: brief quiet + slow = normal stop.
        let softStationary = zuptWindowFilled
            && peakAccel < ZUPT_ACCEL_THRESHOLD
            && peakRotation < ZUPT_ROTATION_THRESHOLD
            && currentSpeed < ZUPT_MAX_SPEED
        // Tier 2: sustained near-total stillness zeroes REGARDLESS of the drifted speed —
        // otherwise drift above the gate while standing could never be corrected.
        if peakAccel < HARD_ZUPT_ACCEL && peakRotation < HARD_ZUPT_ROTATION {
            hardQuietDuration += dtS
        } else {
            hardQuietDuration = 0
        }
        // While the watch's own workout context says we are moving in a vehicle, quiet does not
        // mean stopped — a smooth cruise is quiet. This removes the 0 km/h-while-driving reads.
        let drivingNow = self.workoutType == .other && self.motionFallbackSpeed > 8.0
        let stationary = !drivingNow && (softStationary || hardQuietDuration >= HARD_ZUPT_WINDOW)
        isInertialStationary = stationary
        if stationary {
            motionVelX = 0
            motionVelY = 0
            accelBiasX += rX * ZUPT_BIAS_RATE
            accelBiasY += rY * ZUPT_BIAS_RATE
            prevResidualX = 0
            prevResidualY = 0
            return
        }
        // VERTICAL-MOTION GUARD (elevator / lift / stairs): an elevator's large genuine
        // vertical acceleration leaks a fraction into the horizontal axes through attitude
        // error, and ZUPT cannot suppress it because the 3-axis residual is genuinely large.
        // When vertical clearly dominates horizontal, the horizontal part is leakage, not
        // travel, so it must not be integrated. Walking/driving is the opposite.
        let horizontalResidual = sqrt(rX * rX + rY * rY)
        if abs(azW) > 0.3 && abs(azW) > 2.5 * horizontalResidual {
            prevResidualX = 0
            prevResidualY = 0
            return
        }

        // VIOLENT-ROTATION GUARD: whipping the device around makes the attitude lag, leaking
        // gravity into the horizontal axes and integrating into absurd speed.
        //
        // THRESHOLD HISTORY: this was 1.5 rad/s and broke recording — ordinary walking (arm
        // swing especially, on a WRIST) exceeds that constantly, so integration froze on
        // nearly every sample and no route point was ever produced. Body motion is
        // ~1–3 rad/s, so the freeze must sit above it; the residual clamp handles everyday
        // spikes.
        if rotMag > 4.0 {
            prevResidualX = 0
            prevResidualY = 0
            return
        }
        // LONG-WINDOW MEAN REMOVAL: over ~90 s any vehicle's mean horizontal acceleration is
        // ~0, so the long-run mean IS bias + gravity leakage and can be removed
        // unconditionally. The gated estimator freezes during traffic and cannot do this,
        // which let a car diverge without bound.
        let meanTau = 90.0
        let meanAlpha = min(dtS / (meanTau + dtS), 1.0)
        longRunMeanX += (worldAccelX - longRunMeanX) * meanAlpha
        longRunMeanY += (worldAccelY - longRunMeanY) * meanAlpha

        if sqrt(rX * rX + rY * rY) < MOTION_BIAS_GATE {
            accelBiasX += rX * MOTION_BIAS_RATE
            accelBiasY += rY * MOTION_BIAS_RATE
        }
        // Residual CLAMPED to a physical bound (no vehicle sustains |a| > 6 m/s²; a jet
        // takeoff is ~3) so attitude/sensor spikes clip instead of integrating.
        func clamped(_ v: Double) -> Double { Swift.max(-4.0, Swift.min(4.0, v)) }
        let iX = clamped(worldAccelX - accelBiasX - longRunMeanX)
        let iY = clamped(worldAccelY - accelBiasY - longRunMeanY)
        motionVelX += ((prevResidualX + iX) / 2.0) * dtS
        motionVelY += ((prevResidualY + iY) / 2.0) * dtS
        prevResidualX = iX
        prevResidualY = iY
        // NO SPEED CAP — see iPhone WorkoutSession: correctness by construction, not clamping.
    }

    // MARK: - DEBUG: synthetic flight replay (simulator has no Core Motion)
    // Mirrors the iPhone hook: pushes a synthesized flight's WORLD-frame acceleration through
    // the low-pass + the shared integrateWorldMotionResidual + the 1 Hz motion-fallback tick,
    // so the reconstructed route can be seen on the watch simulator (which supplies no
    // Core Motion). Reached ONLY via the `-replayFlight` launch argument — inert otherwise.
    private var debugReplayTimer: Timer?
    private var debugReplayT: Double = 0

    private func debugFlightHeadingSpeed(_ t: Double) -> (spd: Double, hdg: Double) {
        let legs: [(Double, Double, Double)] = [
            (8, 60, 90), (25, 60, 90),
            (33, 60, 180), (50, 60, 180),
            (58, 60, 90), (66, 60, 90),
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
        print("⌚ 🧪 DEBUG: synthetic flight replay starting (simulator has no Core Motion)")
        workoutType = .other
        let startDate = Date()
        flight = Flight(startDate: startDate)
        flight.workoutType = workoutType.rawValue
        isActive = true
        isPaused = false
        lastLocationTime = startDate

        let seed = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5645),
            altitude: 3000, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 90, speed: 0, timestamp: startDate)
        flight.locations.append(FlightLocation(from: seed, isValid: true))

        forceMotionFallback = true
        motionFrameIsAbsolute = true
        motionAttitudeReady = true
        motionHeadingDegrees = 90
        startMotionFallback()          // sets isUsingMotionFallback, seeds velocity (0)

        debugReplayT = 0
        var lastTick = -1.0
        debugReplayTimer?.invalidate()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let s = self.debugFlightSample(self.debugReplayT)
            // Feed world-frame (north, west=-east) through the same low-pass the handler uses.
            let dt = 0.02, tau = 0.15, alpha = min(dt / (tau + dt), 1.0)
            self.worldAccelX += (s.north - self.worldAccelX) * alpha
            self.worldAccelY += ((-s.east) - self.worldAccelY) * alpha
            self.integrateWorldMotionResidual(dt: dt, up: 0, rotationRate: s.rot)
            if self.debugReplayT - lastTick >= 1.0 {
                lastTick = self.debugReplayT
                self.checkMotionFallback()   // velocity → distance → appended route point
            }
            self.debugReplayT += dt
            if self.debugReplayT >= 66 {
                self.debugReplayTimer?.invalidate(); self.debugReplayTimer = nil
                print("⌚ 🧪 DEBUG replay complete: \(self.flight.locations.count) pts, " +
                      "\(String(format: "%.2f", self.currentMetrics.totalDistance / 1000))km")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        debugReplayTimer = timer
    }

    /// Debounced driver for the GPS-gap fallbacks. Called from BOTH the session's
    /// keep-alive timer AND the live view's 1 s timer, because on watchOS the always-on
    /// / throttled state can suspend one while the other keeps ticking. Whichever fires
    /// first each second does the work; the other is a no-op. This guarantees the
    /// accel/velocity dead reckoning actually RUNS even when the session's RunLoop timer
    /// is starved — the exact cause of the elevator/basement "stuck on GPS OK" bug (the
    /// UI counter kept climbing off the view's own timer while the fallbacks never ran).
    func runGpsGapFallbacksTick(source: String) {
        guard isActive, !isPaused else { return }
        let now = Date()
        if let last = lastFallbackTickTime, now.timeIntervalSince(last) < 0.5 {
            return  // already ran this second (the other timer beat us to it)
        }
        lastFallbackTickTime = now
        // ONE STRATEGY, whether the user forced it or GPS simply went away.
        //
        // The separate pedometer fallback used to own walking gaps, so the AUTOMATIC switch —
        // the one a real flight, tunnel or basement actually uses — ran a weaker method than
        // Velocity Mode: CMPedometer distance only, with none of the accelerometer step
        // detection, cadence-and-stride speed, standing-still zeroing, held vehicle speed or
        // heading work that went into the shared chain.
        //
        // That chain already routes to the pedometer the moment steps are detected, so nothing
        // is lost by retiring the separate path — and keeping both alive after removing the
        // yield would have had them BOTH adding distance for the same steps.
        if isUsingPedometerFallback {
            endPedometerFallback(reason: "motion fallback owns the gap")
        }
        checkMotionFallback()
    }

    private func checkMotionFallback() {
        // The watch's OWN accelerometer + velocity is the PRIMARY GPS-loss fallback.
        // It engages FAST and UNCONDITIONALLY the moment GPS goes quiet — it NEVER
        // waits on the iPhone relay, and NEVER waits on the pedometer to "warm up".
        // (Both are dead in a basement / airplane / elevator, which is exactly when
        // the fallback is needed.) This is the required behavior: "when no data from
        // iPhone, immediately switch to acceleration/velocity."
        //
        // The OLD logic gated motion behind the pedometer with a grace window, so a
        // dead pedometer (0 Hz, 0 steps — an elevator/vehicle/plane) left the watch
        // stuck forever on "GPS OK" with a frozen track. Motion now owns the gap by
        // default; the pedometer only takes over while it is genuinely counting steps.
        let isStepBased = (workoutType == .walking || workoutType == .running || workoutType == .hiking)
        let timeSinceLastGPS = Date().timeIntervalSince(lastLocationTime)

        // MANUAL OVERRIDE: when the user forces velocity (motion) mode ON from the
        // workout UI, dead reckoning runs UNCONDITIONALLY — it does not wait for a GPS
        // gap and does not yield to the pedometer. GPS fixes are ignored for distance
        // while forced (see processNewLocation), so there is no double-counting.
        if !forceMotionFallback {
            guard timeSinceLastGPS >= WATCH_DEAD_RECKON_THRESHOLD else {
                if isUsingMotionFallback {
                    endMotionFallback(reason: "GPS returned")
                }
                return
            }

            // NO LONGER YIELDING THE GAP TO A SEPARATE PEDOMETER PATH.
            //
            // This handed every walking GPS gap to an older, simpler fallback that only
            // accumulates CMPedometer distance — so the automatic switch, which is what a real
            // flight or basement actually uses, ran a different and weaker strategy than
            // Velocity Mode does, and none of the work that made Velocity Mode good reached it:
            // no accelerometer step detection, no cadence-and-stride speed, no standing-still
            // zeroing, no held vehicle speed obeying measured braking, no heading datum.
            //
            // The reason it existed was that step counting beats accelerometer integration for
            // a walk. That is still true and is no longer an argument for a separate path: the
            // shared chain routes to the pedometer itself the moment steps are detected, and
            // falls through to the vehicle sources only when there are none. One strategy,
            // reached the same way whether the user forced it or GPS simply went away.
        }

        if !isUsingMotionFallback {
            startMotionFallback()
        }

        let now = Date()
        let previousTick = lastMotionFallbackTick ?? now.addingTimeInterval(-MOTION_FALLBACK_TICK)
        let dt = min(max(now.timeIntervalSince(previousTick), 0.5), 2.0)
        lastMotionFallbackTick = now

        // Inertial dead reckoning: integrate acceleration → velocity → distance.
        //  • Sustained acceleration (e.g. airplane takeoff, train pulling away)
        //    BUILDS velocity: v += a·dt.
        //  • Near-zero acceleration (cruise / constant velocity) MAINTAINS velocity
        //    with a slow decay so we keep covering distance (tunnels/trains) instead
        //    of wrongly deciding "stopped".
        //  • Truly stationary (accel below deadband for a while) → slow bleed to 0.
        //
        // Source of the acceleration: the WATCH's own accelerometer normally. If the
        // watch can't run device-motion (memory pressure / suppressed), fall back to
        // the acceleration RELAYED FROM THE IPHONE (it feels the same vehicle motion).
        // NOTE: the velocity vector is integrated at SENSOR RATE inside the device-motion
        // handler (correct numerical integration). This 1 Hz tick only applies the leak,
        // the settle-to-rest check, and converts velocity → distance.
        var accelSource = "watch"
        if !motionManager.isDeviceMotionAvailable || !motionAttitudeReady {
            // Watch device motion is suppressed, so there is no sensor-rate integration here.
            // PREFER the iPhone's fully-integrated DR state when it is fresh: adopting its
            // velocity vector outright is strictly better than re-integrating a relayed
            // acceleration magnitude, and it keeps arriving with no GPS (which is exactly
            // when the watch used to freeze).
            if let speed = iPhoneDRSpeed, let heading = iPhoneDRHeading,
               let ts = iPhoneDRTimestamp, now.timeIntervalSince(ts) <= IPHONE_DR_MAX_AGE {
                accelSource = "iPhone-DR"
                if let v = iPhoneDRVelocity, v.north != 0 || v.east != 0 {
                    motionVelX = v.north          // world X = north
                    motionVelY = -v.east          // world Y = west (east = −Y)
                } else {
                    let h = heading * .pi / 180
                    motionVelX = speed * cos(h)
                    motionVelY = -speed * sin(h)
                }
                motionHeadingDegrees = normalizedHeading(heading)
            } else if forceMotionFallback || !isStepBased,
                      let assist = recentIPhoneMotionAssist(near: now) {
                // Legacy path: only a relayed acceleration magnitude is available.
                accelSource = "iPhone-accel"
                let mag = max(assist.forwardAcceleration.map { abs($0) } ?? 0.0,
                              assist.horizontalAcceleration ?? 0.0)
                let h = motionHeadingDegrees * .pi / 180
                motionVelX += mag * cos(h) * dt          // north component
                motionVelY += -mag * sin(h) * dt         // west component (east = −Y)
            } else {
                accelSource = "no-motion"
            }
        }

        // Drift correction lives entirely in the sensor-rate ZUPT inside the device-motion
        // handler. There is deliberately NO velocity leak and no settle-to-rest damping here
        // any more: both decayed genuine cruise velocity (a steady cruise has ~zero
        // acceleration, so it looks exactly like drift to a magnitude test) and made distance
        // read low the longer the trip ran.

        // Speed is the magnitude of the velocity vector — NO speed limit is applied.
        let nextSpeed = sqrt(motionVelX * motionVelX + motionVelY * motionVelY)
        // HEADING: attitude yaw + anchored offset is PRIMARY — the gyro-fused attitude tracks
        // turns with no dependence on acceleration (walking has ~zero net accel, so the
        // velocity-vector bearing has no signal there). The velocity vector only slowly
        // re-calibrates the offset during strong sustained acceleration (vehicle/takeoff),
        // where its bearing is actually informative.
        let velHeading: Double? = nextSpeed > 0.1
            ? normalizedHeading(atan2(-motionVelY, motionVelX) * 180 / .pi)  // north=+X, east=−Y
            : nil
        // Device ORIENTATION is deliberately NOT used as a proxy for travel direction: a watch
        // rides a swinging wrist, so nothing holds it at a fixed angle to the body and
        // "travel = yaw + offset" is invalid. Heading comes only from motion measurements —
        // the velocity vector when there is genuine sustained acceleration (vehicle/aircraft).
        //
        // NOTE: no PCA walking-axis path on the WRIST. Measured in simulation, arm swing makes
        // lateral sway dominate the forward push, so the principal axis lands roughly
        // PERPENDICULAR to the true direction (~88° error). Holding the last known course is
        // far better than confidently drawing a right angle. The iPhone (trunk/pocket carry,
        // ~1° error) does use it.
        let rXh = worldAccelX - accelBiasX
        let rYh = worldAccelY - accelBiasY
        let horizAccelMag = sqrt(rXh * rXh + rYh * rYh)
        // TURN with the watch's own gyro (vertical-axis integration) every tick, so the route
        // is no longer a straight line even between absolute-heading corrections.
        if let prev = lastCumulativeYawForHeading {
            let dYaw = cumulativeYawRotationDeg - prev
            motionHeadingDegrees = normalizedHeading(motionHeadingDegrees + dYaw)
        }
        lastCumulativeYawForHeading = cumulativeYawRotationDeg
        // Correct the ABSOLUTE heading toward the best available reference (the gyro only gives
        // relative turn). Velocity vector under real acceleration is best; else the iPhone's
        // relayed heading (it recovers absolute direction the watch cannot).
        // A diverged velocity vector is not a trustworthy bearing — require a plausible speed.
        if let vh = velHeading, nextSpeed > 3.0, nextSpeed < 60.0, horizAccelMag > 0.4, motionFrameIsAbsolute {
            motionHeadingDegrees = vh
        } else if let relayedHeading = iPhoneDRHeading, let ts = iPhoneDRTimestamp,
                  now.timeIntervalSince(ts) <= IPHONE_DR_MAX_AGE {
            motionHeadingDegrees = normalizedHeading(relayedHeading)
        }
        // ABSOLUTE DATUM, ALWAYS: applied outside the branches so a diverged velocity vector
        // can never lock the heading away from the only drift-free reference available.
        // The compass measures where the WATCH points, not where the body travels; on a wrist
        // those differ. Only the iPhone can measure the body's travel axis (PCA), so when its
        // relayed heading is available we prefer that (handled above) and otherwise fall back
        // to the compass with whatever misalignment the phone has taught us.
        if let compass = locationManager.currentCompassHeading {
            let target = normalizedHeading(compass + (relayedCompassMisalignment ?? 0))
            var err = target - motionHeadingDegrees
            if err > 180 { err -= 360 } else if err < -180 { err += 360 }
            motionHeadingDegrees = normalizedHeading(motionHeadingDegrees + 0.08 * err)
        }
        // else: gyro-propagated heading stands (turns preserved even with no relay).
        // DISTANCE: for step-based activities use the PEDOMETER (already tracking since
        // workout start — step detection + Apple's stride model is accurate to a few %,
        // whereas steps sum to ~zero net acceleration and defeat the integrator). The
        // accelerometer integration is the distance source only for vehicle/flight types.
        // Decide by what the sensors ACTUALLY detect, never by the activity label. The user
        // selects "Walking" while sitting in an aircraft, where the pedometer counts zero
        // steps — routing on the label alone produced zero distance and NO TRACK AT ALL.
        // Steps are only a valid distance source while steps are genuinely being counted.
        let steps = pedometerManager.currentStepCount
        // CADENCE, not "any step": vehicle vibration produces sporadic phantom steps, which
        // locked the watch into pedometer distance and reported ~3 km/h while driving.
        if steps > lastPedometerStepCountForDR {
            let added = steps - lastPedometerStepCountForDR
            if let prev = lastStepSampleTimeWatch {
                let elapsed = now.timeIntervalSince(prev)
                if elapsed > 0.5 {
                    // Attribute steps to when they happened, not to the whole gap: steps that
                    // arrive after a silence were taken in the last seconds of it, and
                    // dividing by the full elapsed time diluted a real 2 steps/s to 0.5 after
                    // any pause (see iPhone — it cost 27 s of walking reported as 0.0 km/h).
                    let cadence = Double(added) / min(elapsed, 5.0)
                    // Seed on the first measurement rather than smoothing up from zero, which
                    // delayed PDR by several sparse pedometer updates (see iPhone version).
                    if stepCadenceWatch <= 0 || elapsed > 5.0 {
                        stepCadenceWatch = cadence
                    } else {
                        stepCadenceWatch = stepCadenceWatch * 0.5 + cadence * 0.5
                    }
                    if stepCadenceWatch >= 1.0 { lastStepIncrementTime = now }
                }
            }
            lastStepSampleTimeWatch = now
        }
        lastPedometerStepCountForDR = steps
        let pedometerIsCounting = lastStepIncrementTime.map { now.timeIntervalSince($0) < 20.0 } ?? false  // long: CMPedometer updates are sparse

        // Route by DETECTED stepping, not the activity label: if steps are being counted you
        // are walking and the pedometer is right; integrating walking accel diverges.
        let distance: Double
        // The vehicle guard the iPhone gets from vehicleContextIsCurrent: a wrist in a moving
        // car can swing rhythmically, and a held vehicle speed is proof we are in one.
        if imuIsStepping, (lastMeasuredVehicleSpeedWatch ?? 0) < 8.0 {
            // FIRST CHOICE: STEPS SEEN BY THE ACCELEROMETER (identical to the iPhone).
            // Speed is measured cadence x stride, where the stride is learned from
            // CMPedometer's own distance / steps rather than assumed. The pedometer stays the
            // authority on total distance; it no longer decides when we are walking.
            let stepsThisTick = imuStepsPendingTick
            imuStepsPendingTick = 0
            let cadenceSpeed = imuStepCadence * learnedStrideLength
            walkedDistanceEstimate = max(walkedDistanceEstimate, pdrAppendedDistanceWatch)
            walkedDistanceEstimate += Double(stepsThisTick) * learnedStrideLength
            if pedometerManager.isDistanceAvailable {
                let pedometerTotal = pedometerManager.currentDistance
                // Learn this wearer's stride from the pedometer's own distance and steps.
                if let prevD = lastPedometerDistanceForStride, steps > lastStepCountForStride {
                    let stride = (pedometerTotal - prevD) / Double(steps - lastStepCountForStride)
                    if stride > 0.30, stride < 1.20 {
                        learnedStrideLength += (stride - learnedStrideLength) * 0.3
                    }
                }
                if steps > lastStepCountForStride {
                    lastPedometerDistanceForStride = pedometerTotal
                    lastStepCountForStride = steps
                }
                walkedDistanceEstimate = max(walkedDistanceEstimate, pedometerTotal)
                lastPedometerDistanceForDR = pedometerTotal
            }
            let owed = max(0, walkedDistanceEstimate - pdrAppendedDistanceWatch)
            distance = min(owed, max(cadenceSpeed * dt * 2.0, 1.0))
            pdrAppendedDistanceWatch += distance
            motionFallbackSpeed = cadenceSpeed
            smoothedPedometerSpeedWatch = cadenceSpeed
            accelSource = "PDR(step)"
            let hr = motionHeadingDegrees * .pi / 180
            motionVelX = motionFallbackSpeed * cos(hr)
            motionVelY = -motionFallbackSpeed * sin(hr)
        } else if pedometerIsCounting, pedestrianIsStandingStill, motionFallbackSpeed < MAX_GROUND_STOP_SPEED {
            // STANDING STILL — SAY SO IMMEDIATELY. pedometerIsCounting stays true for 20 s
            // after the last step to bridge sparse distance updates, and during that window a
            // stale pedometer speed kept drawing route that was never walked.
            distance = 0
            smoothedPedometerSpeedWatch = 0
            motionFallbackSpeed = 0
            motionVelX = 0
            motionVelY = 0
            accelSource = "PDR(still)"
        } else if pedometerManager.isDistanceAvailable, pedometerIsCounting {
            let pedometerTotal = pedometerManager.currentDistance
            // Smooth speed from cumulative-distance updates, and lay distance down PER TICK
            // along the CURRENT heading — not the raw cumulative delta, whose sparse jumps
            // drew one long straight segment ignoring the turns walked during the gap.
            if let last = lastPedometerDistanceForDR, let lastT = lastPedometerUpdateTimeWatch {
                let elapsed = now.timeIntervalSince(lastT)
                if elapsed > 0.5, pedometerTotal > last {
                    let instant = (pedometerTotal - last) / elapsed
                    // Time-constant smoothing, not a fixed 50/50 blend per update (see the
                    // iPhone WorkoutSession for why a fixed ratio under sparse, irregular
                    // updates reads as sluggish acceleration/deceleration).
                    let alpha = min(elapsed / (2.0 + elapsed), 1.0)
                    smoothedPedometerSpeedWatch += (instant - smoothedPedometerSpeedWatch) * alpha
                }
            }
            if pedometerTotal != (lastPedometerDistanceForDR ?? -1) { lastPedometerUpdateTimeWatch = now }
            lastPedometerDistanceForDR = pedometerTotal
            // Catch-up toward the cumulative, capped per tick (see iPhone comment) so a sparse
            // pedometer jump spreads over ticks along the heading instead of one straight line.
            let owed = max(0, pedometerTotal - pdrAppendedDistanceWatch)

            // THE 1.5 m FLOOR MUST NOT APPLY ONCE THE STEPS HAVE STOPPED.
            //
            // It exists so a sparse CMPedometer update can be bled out over several ticks
            // instead of drawn as one long straight segment. But it was a FLOOR, so it kept
            // emitting 1.5 m every tick regardless of speed — and pedometerIsCounting stays
            // true for 20 s after the last step, so standing still could lay down tens of
            // metres of route that were never walked. Logged live while stationary:
            //
            //     speed 0.77 km/h -> distance 1.50 m
            //     speed 0.31 km/h -> distance 1.50 m
            //     speed 0.10 km/h -> distance 1.50 m
            //     speed 0.03 km/h -> distance 1.50 m
            //
            // The speed decay added earlier was working; the distance simply ignored it. Steps
            // land at 1.5-3 per second, so a gap over 2 s means stepping has stopped and there
            // is nothing left to catch up on.
            let stepsAreCurrent = (lastStepIncrementTime.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude) < 2.0
            let perTickCap = stepsAreCurrent ? max(smoothedPedometerSpeedWatch * dt * 1.5, 1.5)
                                             : smoothedPedometerSpeedWatch * dt
            distance = min(owed, perTickCap)
            pdrAppendedDistanceWatch += distance
            motionFallbackSpeed = smoothedPedometerSpeedWatch
            // Peg the integrator to the real speed so it cannot diverge while walking (heading
            // = +X north, west = −Y).
            let hr = motionHeadingDegrees * .pi / 180
            motionVelX = motionFallbackSpeed * cos(hr)
            motionVelY = -motionFallbackSpeed * sin(hr)
        } else {
            // Not stepping: vehicle, aircraft or stationary. Drop the stale pedometer baseline
            // so a later walk re-anchors cleanly.
            lastPedometerDistanceForDR = nil
            lastCumulativeYawForHeading = nil
            smoothedPedometerSpeedWatch = 0
            lastPedometerUpdateTimeWatch = nil
            pdrAppendedDistanceWatch = 0
            walkedDistanceEstimate = 0
            lastPedometerDistanceForStride = nil

            // SAME PRIORITY CHAIN AS THE IPHONE, and for the same measured reasons.
            //
            // This used to integrate the watch's own acceleration. That is exactly the method
            // deleted from the iPhone once it was measured: accelerometer bias is
            // indistinguishable from real sustained acceleration, so integrating it produces an
            // error that grows without bound — a stationary phone read 81 km/h in 35 s, and an
            // 8-minute drive fabricated 7.6 km of route. A watch has the same class of sensor
            // on a swinging wrist, so it has the same failure and worse.
            //
            // Order: the iPhone's own estimate first, since the phone runs the learned speed
            // model, holds the GPS-measured speed, and sees far steadier motion than a wrist;
            // then the watch's own last GPS-measured speed, held; then nothing at all. Never
            // integration.
            if let relayed = iPhoneDRSpeed, let ts = iPhoneDRTimestamp,
               now.timeIntervalSince(ts) <= IPHONE_DR_MAX_AGE {
                motionFallbackSpeed = relayed
                accelSource = "iPhone-DR"
            } else if let held = lastMeasuredVehicleSpeedWatch {
                // A HELD SPEED MUST STILL OBEY THE ACCELEROMETER (identical to the iPhone).
                // Freezing it meant braking to a stop kept reporting the pre-stop speed and
                // pulling away kept reporting zero, while cruise in between was accurate. So
                // hold the GPS-measured speed and correct it by the along-track velocity
                // change actually measured since: v = v0 + integral a dt. Only samples above a
                // noise floor accumulate, so a quiet cruise adds nothing and the held value
                // survives exactly — which is the flight case.
                let corrected = max(0, held + heldSpeedCorrection)
                // QUIET ALONE MUST NOT ZERO A MOVING VEHICLE (see iPhone). A phone resting on a
                // leg on a smooth road is quiet, and treating that as stopped made the speed
                // drop 30 -> 0 -> 30. Quiet may only confirm a stop the along-track integral
                // has already measured — braking swings it by the whole speed, so it cannot be
                // missed — and never above a speed that could be an aircraft.
                let stoppedOnGround = corrected < MAX_GROUND_STOP_SPEED
                    && corrected < VEHICLE_STOP_CONFIRM_SPEED
                    && pedestrianQuietDuration >= VEHICLE_STOP_QUIET_WINDOW
                motionFallbackSpeed = stoppedOnGround ? 0 : corrected
                if stoppedOnGround { heldSpeedCorrection = -held }
                accelSource = stoppedOnGround ? "HOLD(stopped)" : "HOLD"
            } else {
                motionFallbackSpeed = 0
                accelSource = "waiting"
            }
            distance = motionFallbackSpeed * dt
            // Peg the integrator so it cannot diverge in the background and reappear later.
            let hr = motionHeadingDegrees * .pi / 180
            motionVelX = motionFallbackSpeed * cos(hr)
            motionVelY = -motionFallbackSpeed * sin(hr)
        }

        // Keep the DISPLAYED speed in sync every tick, not only when a point is appended, so
        // it matches the DR status and reflects ZUPT zeroing while standing still.
        currentMetrics.currentSpeed = motionFallbackSpeed
        currentMetrics.smoothedSpeed = motionFallbackSpeed

        // Live diagnostic: computed travel heading (→) vs compass, so a ground test can
        // confirm in real time whether the inertial direction tracks the real one.
        if pedometerIsCounting, !accelSource.hasPrefix("PDR") { accelSource = "PDR" }
        let compassText = locationManager.currentCompassHeading.map { String(format: "%.0f", $0) } ?? "--"
        fallbackDebugStatus = String(
            format: "DR[%@]%@ %.0fkm/h →%.0f° cmp%@° +%.0fm",
            accelSource,
            forceMotionFallback ? " FORCED" : "",
            motionFallbackSpeed * 3.6,
            motionHeadingDegrees,
            compassText,
            motionFallbackDistanceAdded
        )

        // Accumulate rather than discard: a sub-threshold tick used to be dropped outright
        // even though the pedometer baseline had already advanced, permanently losing that
        // distance.
        pendingMotionDistance += distance

        // ALWAYS RECORD SOMETHING — the guarantee the iPhone already makes and the watch did
        // not. Below the threshold this returned outright, so whenever the estimator produced
        // no distance — standing still, the model declining, waiting for evidence — the watch
        // recorded NO POINTS AT ALL and the workout came back with an empty track. A recording
        // that captures nothing cannot be reviewed, exported or debugged; it is the one outcome
        // with no recovery, and a stationary point is a real observation ("we were here, not
        // moving"). So append on distance as before, or on a heartbeat if too long has passed.
        let sinceLastAppend = now.timeIntervalSince(lastMotionAppendTime)
        let heartbeatDue = sinceLastAppend >= MOTION_HEARTBEAT_SECONDS
        guard pendingMotionDistance >= 0.1 || heartbeatDue else { return }
        lastMotionAppendTime = now
        let appendDistance = pendingMotionDistance
        pendingMotionDistance = 0

        appendEstimatedPedometerFallbackLocation(distanceMeters: appendDistance, timestamp: now,
                                                 speedMetersPerSecond: motionFallbackSpeed)
        motionFallbackDistanceAdded += appendDistance

        let now2 = Date()
        if now2.timeIntervalSince(lastMotionFallbackLogTime) >= 5.0 {
            print("⌚ 🧭 MOTION FALLBACK: +\(String(format: "%.1f", motionFallbackDistanceAdded))m (speed ≈ \(String(format: "%.1f", motionFallbackSpeed * 3.6))km/h, GPS gap: \(Int(timeSinceLastGPS))s, total: \(String(format: "%.2f", currentMetrics.totalDistance/1000))km)")
            lastMotionFallbackLogTime = now2
        }
    }

    private func startMotionFallback() {
        isUsingMotionFallback = true
        motionFallbackDistanceAdded = 0.0
        // Ask the iPhone to start sharing the moment dead reckoning engages. It is the watch's
        // only usable source of HEADING here — a watch cannot resolve walking direction by
        // itself. This works with the iPhone merely nearby: sharing does not require an iPhone
        // workout, and it relays motion-derived heading even with no GPS (aircraft, tunnel).
        // Without this, Force Velocity never triggers the GPS-failure path that requests it,
        // so the watch held one heading and drew a straight line.
        if !connectivityManager.isUsingIPhoneGPS && !connectivityManager.isIPhoneGPSRequestPending {
            print("⌚ 📱 DR engaged — requesting iPhone as motion/heading source")
            connectivityManager.requestIPhoneGPS()
        }
        // Seed from the best available speed so we keep moving through the gap:
        // smoothed speed → last GPS point's speed → average speed.
        let lastPointSpeed = flight.locations.last.map { max($0.speed, 0.0) } ?? 0.0
        let seed = max(currentMetrics.smoothedSpeed, max(lastPointSpeed, currentMetrics.averageSpeed))
        let seedSpeed = max(seed, 0.0)   // no speed limit
        // Seed the velocity VECTOR along the last known GPS course so cruise is
        // maintained in the correct direction (a moving car keeps its speed & heading).
        let courseDeg = flight.locations.last.flatMap { validCourse($0.course) } ?? motionHeadingDegrees
        let c = courseDeg * .pi / 180
        motionVelX = seedSpeed * cos(c)      // north component
        motionVelY = -seedSpeed * sin(c)     // west component (east = −Y)
        motionHeadingDegrees = courseDeg
        // Anchor the yaw-relative heading: travel heading = device yaw + offset from here on.
        yawHeadingOffset = deviceYawHeadingDegrees.map { normalizedHeading(courseDeg - $0) }
        motionFallbackSpeed = seedSpeed
        accelBiasX = 0; accelBiasY = 0
        prevResidualX = 0; prevResidualY = 0
        zuptWindow.removeAll(); zuptWindowFilled = false; isInertialStationary = false; lastMotionSampleTimestamp = nil
        longRunMeanX = 0; longRunMeanY = 0
        lastMotionFallbackTick = nil
        lastMotionFallbackLogTime = Date()
        let gap = Date().timeIntervalSince(lastLocationTime)
        print("⌚ 🧭 MOTION FALLBACK STARTED: GPS lost for \(Int(gap))s, seed=\(String(format: "%.1f", seedSpeed * 3.6))km/h @ \(Int(courseDeg))°")
    }

    private func endMotionFallback(reason: String) {
        guard isUsingMotionFallback else { return }
        print("⌚ 🧭 MOTION FALLBACK ENDED: \(reason)")
        print("⌚ 🧭 Motion distance added during gap: +\(String(format: "%.1f", motionFallbackDistanceAdded))m")
        isUsingMotionFallback = false
        motionFallbackSpeed = 0.0
        motionFallbackDistanceAdded = 0.0
        yawHeadingOffset = nil
        lastPedometerDistanceForDR = nil
        lastCumulativeYawForHeading = nil
        smoothedPedometerSpeedWatch = 0
        lastPedometerUpdateTimeWatch = nil
        pdrAppendedDistanceWatch = 0
        pendingMotionDistance = 0
        motionVelX = 0.0; motionVelY = 0.0
        accelBiasX = 0.0; accelBiasY = 0.0
        prevResidualX = 0.0; prevResidualY = 0.0
        zuptWindow.removeAll(); zuptWindowFilled = false; isInertialStationary = false; lastMotionSampleTimestamp = nil
        longRunMeanX = 0; longRunMeanY = 0
        lastMotionFallbackTick = nil
        lastAnchorlessFallbackTime = nil
    }

    private func preventiveGPSRestart() {
        guard isActive && !isPaused else { return }

        let elapsed = Date().timeIntervalSince(flight.startDate)
        let locationCount = flight.locations.count

        print("⌚ 🔄 PREVENTIVE GPS RESTART (scheduled maintenance)")
        print("⌚ 🔄 Workout time: \(Int(elapsed))s, Locations: \(locationCount)")
        print("⌚ 🔄 This is NORMAL - preventive restart to ensure continued recording")

        // Quick restart
        locationManager.stopTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.locationManager.startTracking()
            print("⌚ 🔄 Preventive restart complete - GPS re-enabled")
        }
    }

    private func forceGPSRestart() {
        print("⌚ 🚨 FORCE GPS RESTART - locations stopped arriving!")

        // AGGRESSIVE: Stop and restart with longer delay
        locationManager.stopTracking()

        // Wait 2 seconds for full reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }

            self.locationManager.startTracking()
            print("⌚ 🚨 Force restart complete - monitoring location arrival...")

            // Check again in 15 seconds if restart worked
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
                guard let self = self else { return }

                let newCount = self.flight.locations.count
                if newCount == self.lastLocationCount {
                    print("⌚ ⚠️⚠️⚠️ CRITICAL: Force restart FAILED - still no locations!")
                    print("⌚ ⚠️⚠️⚠️ Attempting EMERGENCY recovery...")
                    self.emergencyRecovery()
                } else {
                    print("⌚ ✅ Force restart SUCCESSFUL - \(newCount - self.lastLocationCount) new locations")
                }
            }
        }
    }

    private func emergencyRecovery() {
        print("⌚ 🆘 EMERGENCY RECOVERY INITIATED")

        // Try to restart the entire location manager setup
        locationManager.stopTracking()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.locationManager.requestAuthorization()
            self?.locationManager.startTracking()
            print("⌚ 🆘 Emergency recovery complete - full location manager reset")
        }
    }

    private func attemptLocationRecovery() {
        print("⌚ 🔄 Attempting location recovery...")

        // Restart location manager
        locationManager.stopTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.locationManager.startTracking()
            print("⌚ 🔄 Location manager restarted")
        }
    }

    private func attemptSessionRecovery() {
        print("⌚ 🔄 Attempting session recovery...")

        // Don't attempt recovery if not active
        guard isActive else {
            print("⌚ ⚠️ Not attempting recovery - workout not active")
            return
        }

        // Log the issue but continue - HKWorkoutSession is robust
        print("⌚ ⚠️ Session issue detected but continuing - HealthKit will preserve data")
    }

    private func setNetworkDebugMessage(_ message: String) {
        if Thread.isMainThread {
            networkDebugMessage = message
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.networkDebugMessage = message
            }
        }
    }

    private func startNetworkPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            self.latestPathStatus = path.status
            if path.status == .satisfied {
                if path.usesInterfaceType(.cellular) {
                    self.latestPathInterface = "cellular"
                } else if path.usesInterfaceType(.wifi) {
                    self.latestPathInterface = "Wi-Fi"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.latestPathInterface = "wired"
                } else {
                    self.latestPathInterface = "other"
                }
            } else {
                self.latestPathInterface = "unavailable"
            }

            self.refreshNetworkPathStatus()
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func refreshNetworkPathStatus() {
        let updateBlock = { [weak self] in
            guard let self = self else { return }

            let directNetworkStatus: String
            switch self.latestPathStatus {
            case .satisfied:
                directNetworkStatus = self.latestPathInterface
            case .requiresConnection:
                directNetworkStatus = "needs-connect"
            case .unsatisfied:
                directNetworkStatus = "unavailable"
            @unknown default:
                directNetworkStatus = "unknown"
            }

            let iphoneRelayStatus: String
            if self.connectivityManager.isUsingIPhoneGPS {
                iphoneRelayStatus = "streaming"
            } else if self.connectivityManager.isIPhoneGPSRequestPending {
                iphoneRelayStatus = "requested"
            } else {
                iphoneRelayStatus = self.connectivityManager.isReachable ? "connected" : "disconnected"
            }

            let fallbackTag: String
            if self.connectivityManager.isUsingIPhoneGPS {
                fallbackTag = " • fallback:on"
            } else if self.connectivityManager.isIPhoneGPSRequestPending {
                fallbackTag = " • fallback:pending"
            } else {
                fallbackTag = ""
            }
            self.networkPathStatus = "Net: \(directNetworkStatus) • iPhone: \(iphoneRelayStatus)\(fallbackTag)"
        }

        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async(execute: updateBlock)
        }
    }

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

    private func recentIPhoneMotionAssist(near timestamp: Date) -> IPhoneMotionAssist? {
        guard let assist = latestIPhoneMotionAssist else { return nil }
        return abs(timestamp.timeIntervalSince(assist.timestamp)) <= motionAssistMaxAge ? assist : nil
    }

    private func bearingDegrees(from start: FlightLocation, to end: FlightLocation) -> Double {
        let startLat = start.latitude * .pi / 180
        let startLon = start.longitude * .pi / 180
        let endLat = end.latitude * .pi / 180
        let endLon = end.longitude * .pi / 180
        let deltaLon = endLon - startLon
        let y = sin(deltaLon) * cos(endLat)
        let x = cos(startLat) * sin(endLat) - sin(startLat) * cos(endLat) * cos(deltaLon)
        return normalizedDegrees(atan2(y, x) * 180 / .pi)
    }

    private func normalizedDegrees(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value >= 0 ? value : value + 360
    }

    private func angleDifferenceDegrees(_ first: Double, _ second: Double) -> Double {
        let difference = abs(normalizedDegrees(first) - normalizedDegrees(second))
        return min(difference, 360 - difference)
    }

    private func motionAssistAccelerationThreshold(
        baseThreshold: Double,
        gpsAcceleration: Double,
        previousLocation: FlightLocation,
        currentLocation: FlightLocation
    ) -> Double {
        guard let assist = recentIPhoneMotionAssist(near: currentLocation.timestamp) else {
            return baseThreshold
        }

        let routeBearing = bearingDegrees(from: previousLocation, to: currentLocation)
        if let direction = assist.directionDegrees,
           angleDifferenceDegrees(routeBearing, direction) > motionAssistDirectionToleranceDegrees {
            return baseThreshold
        }

        let forwardAcceleration = assist.forwardAcceleration ?? 0
        let horizontalAcceleration = assist.horizontalAcceleration ?? assist.acceleration ?? 0
        let sameDirection = gpsAcceleration == 0 || forwardAcceleration == 0 || (gpsAcceleration > 0) == (forwardAcceleration > 0)
        guard sameDirection || abs(horizontalAcceleration) >= 2.0 else {
            return baseThreshold
        }

        let motionAllowance = min(
            motionAssistExtraAccelerationAllowance,
            max(abs(forwardAcceleration) * 2.0, abs(horizontalAcceleration))
        )
        return baseThreshold + motionAllowance
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

    private func processNewLocation(_ location: FlightLocation, source: LocationInputSource) {
        // FORCED VELOCITY MODE: the user has manually forced motion (velocity) dead
        // reckoning as the SOLE distance/track source from the workout UI. Ignore GPS
        // fixes entirely so they can't double-count against the motion distance. The
        // watch's LocationManager still updates its own last-known coordinate
        // independently, so when the toggle is turned OFF the next real fix reanchors
        // cleanly (via the "GPS RETURN AFTER A DEAD-RECKONING GAP" block below).
        if forceMotionFallback {
            // ONE RECENT FIX AS THE ORIGIN, exactly as the iPhone does. Dead reckoning gives
            // the SHAPE of the route but cannot know where it starts, and without an anchor
            // the watch fell back to whatever position happened to be last known — which may
            // be stale or missing. Core Location returns a CACHED position on its first
            // callback, so age is checked as well as accuracy: a cached fix reports the good
            // accuracy it had when it was taken, and pins the whole route where you were
            // before you pressed start.
            let fixAge = Date().timeIntervalSince(location.timestamp)
            if flight.locations.isEmpty,
               location.horizontalAccuracy >= 0,
               location.horizontalAccuracy <= MAX_HORIZONTAL_ACCURACY,
               fixAge < MAX_ANCHOR_FIX_AGE {
                flight.locations.append(location)
                currentMetrics.currentAltitude = location.altitude
                print("⌚ 🧭 Velocity mode anchored to GPS ±\(Int(location.horizontalAccuracy))m — all later points are dead-reckoned")
            }
            return
        }

        // Check user setting for raw GPS mode
        let useRawGPS = UserDefaults.standard.bool(forKey: "useRawGPS")
        let isFlight = workoutType == .other
        let sourceLabel: String = {
            switch source {
            case .watchGPS:
                return "watch"
            case .iphoneAssist:
                return "iphone-assist"
            case .iphoneFallback:
                return "iphone-fallback"
            }
        }()
        let isIPhoneSource = (source == .iphoneAssist || source == .iphoneFallback)
        let maxSpeedMps = isFlight ? (10000.0 / 3.6) : MAX_SPEED_MPS
        let maxDistanceJump = isFlight ? 500.0 : MAX_DISTANCE_JUMP
        let absoluteMaxSpeedMps = isFlight ? (10000.0 / 3.6) : ABSOLUTE_MAX_SPEED_MPS
        let absoluteMaxDistanceJump = isFlight ? 2000.0 : ABSOLUTE_MAX_DISTANCE_JUMP
        let sourceAccuracyThreshold = isIPhoneSource ? 2000.0 : MAX_HORIZONTAL_ACCURACY
        let sourceAgeThreshold: TimeInterval = isIPhoneSource ? 30.0 : MAX_LOCATION_AGE
        let sourceSpeedThreshold = isIPhoneSource ? max(maxSpeedMps, 65.0) : maxSpeedMps
        let sourceDistanceJumpThreshold = isIPhoneSource ? max(maxDistanceJump, 500.0) : maxDistanceJump
        let sourceAccelerationThreshold = isIPhoneSource ? max(MAX_ACCELERATION_MPS2, 15.0) : MAX_ACCELERATION_MPS2
        let reanchorGap: TimeInterval = isFlight ? 10.0 : 15.0

        func reanchorLocation(_ reason: String) {
            print("⌚ ⚠️ [\(sourceLabel)] \(reason) - reanchoring to new fix")
            flight.locations.append(location)
            currentMetrics.currentAltitude = location.altitude
            if location.altitude > currentMetrics.maxAltitude {
                currentMetrics.maxAltitude = location.altitude
            }
            lastLocationTime = Date()
        }

        // ═══════════════════════════════════════════════════════════════════════
        // STEP 1: ABSOLUTE SAFETY CHECKS - Always applied, even in Raw GPS mode
        // These catch physically impossible GPS glitches that would corrupt data
        // ═══════════════════════════════════════════════════════════════════════

        // 1a. Always reject invalid GPS (negative accuracy = no fix)
        if location.horizontalAccuracy < 0 {
            print("⌚ 🚫 [\(sourceLabel)] INVALID location (no fix) - REJECTED")
            return
        }

        // Remember a genuine measured speed so it can be HELD once GPS goes, matching the
        // iPhone. Vehicle speed changes slowly, so the last measured value is exact at the
        // moment of signal loss and degrades gracefully — unlike integration, which diverges.
        if location.speed >= 0, location.horizontalAccuracy < 35.0 {
            lastMeasuredVehicleSpeedWatch = location.speed
            heldSpeedCorrection = 0
        }

        // FROZEN iPHONE RELAY GUARD: "connected to iPhone" does NOT mean the iPhone
        // has real GPS data. In a basement/airplane the iPhone relays its last-known
        // position, re-timestamped as fresh. Accepting those keeps resetting the GPS
        // gap and blocks the watch's own accelerometer dead reckoning. If the relayed
        // iPhone position isn't actually moving, treat it as NO DATA and drop it so
        // the gap grows and the watch switches to accel/velocity.
        if isIPhoneSource {
            if let last = lastIPhoneRelayCoord {
                let moved = CLLocation(latitude: last.lat, longitude: last.lon)
                    .distance(from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                // Real GPS always jitters (>1m even when stationary); a re-sent cached
                // position is essentially identical (~0m) → that's a stale relay.
                if moved < 1.0 {
                    frozenIPhoneRelayCount += 1
                    if frozenIPhoneRelayCount >= 2 {
                        // Stale relay confirmed — do NOT update lastLocationTime/status.
                        skippedLocationCount += 1
                        return
                    }
                } else {
                    frozenIPhoneRelayCount = 0
                }
            }
            lastIPhoneRelayCoord = (location.latitude, location.longitude)
            lastIPhoneRelayTime = Date()
        }

        // GPS RETURN AFTER A DEAD-RECKONING GAP (pedometer OR motion fallback).
        // While a fallback runs, the last appended point is a DRIFTED ESTIMATE, so the
        // normal speed/jump glitch filters below would see the returning real fix as a
        // "teleport" and reject it — leaving lastLocationTime frozen and the watch STUCK
        // in fallback forever (reported bug: it never switches back to real GPS). Fix:
        // when ANY fallback is active, sanity-check the incoming fix (accuracy + age),
        // then REANCHOR to it — end the fallback, append the real position, reset the
        // GPS clock — bypassing the glitch filters that assume a continuous real track.
        if isUsingPedometerFallback || isUsingMotionFallback {
            if !useRawGPS {
                if location.horizontalAccuracy > sourceAccuracyThreshold {
                    print("⌚ ⚠️ [\(sourceLabel)] GPS reanchor still poor: ±\(String(format: "%.0f", location.horizontalAccuracy))m - waiting")
                    skippedLocationCount += 1
                    return
                }

                let locationAge = Date().timeIntervalSince(location.timestamp)
                if locationAge > sourceAgeThreshold {
                    print("⌚ ⚠️ [\(sourceLabel)] GPS reanchor stale: \(String(format: "%.1f", locationAge))s old - waiting")
                    skippedLocationCount += 1
                    return
                }
            }

            let reanchorReason = "GPS returned (±\(String(format: "%.0f", location.horizontalAccuracy))m, src=\(sourceLabel))"
            if isUsingMotionFallback { endMotionFallback(reason: reanchorReason) }
            if isUsingPedometerFallback { endPedometerFallback(reason: reanchorReason) }
            frozenIPhoneRelayCount = 0
            // Rubber-sheet the dead-reckoned gap onto the returning GPS fix so it is pinned to
            // GPS at both ends rather than left drifted.
            rubberSheetEstimatedGap(onto: location)
            flight.locations.append(location)
            lastLocationTime = Date()
            // Real fix is back → clear the dead-reckoning status so the UI shows GPS OK.
            switch source {
            case .iphoneFallback: fallbackDebugStatus = "GPS OK (iPhone relay)"
            case .iphoneAssist:   fallbackDebugStatus = "GPS OK (watch+iPhone)"
            case .watchGPS:       fallbackDebugStatus = "GPS OK (watch)"
            }
            currentMetrics.currentAltitude = location.altitude
            if location.altitude > currentMetrics.maxAltitude {
                currentMetrics.maxAltitude = location.altitude
            }
            print("⌚ 🧭→📡 GPS reanchor after dead-reckoning gap — position updated, distance skipped for this point")
            return
        }

        // 1b. Always check for impossible teleportation (GPS glitch)
        if let lastLocation = flight.locations.last {
            let distance = location.distance(to: lastLocation)
            let timeDelta = location.timestamp.timeIntervalSince(lastLocation.timestamp)

            if timeDelta >= reanchorGap && distance > absoluteMaxDistanceJump {
                reanchorLocation("Large jump after \(String(format: "%.1f", timeDelta))s gap")
                return
            }

            // Reject obvious teleportation (>500m instant jump)
            if distance > absoluteMaxDistanceJump {
                print("⌚ 🚫 [\(sourceLabel)] GPS TELEPORT: \(String(format: "%.0f", distance))m jump (max: \(String(format: "%.0f", absoluteMaxDistanceJump))m) - REJECTED")
                return
            }

            // Reject impossible speed (>540 km/h)
            if timeDelta > 0.1 {  // Need at least 100ms between points
                let instantSpeed = distance / timeDelta
                if instantSpeed > absoluteMaxSpeedMps {
                    print("⌚ 🚫 [\(sourceLabel)] IMPOSSIBLE SPEED: \(String(format: "%.0f", instantSpeed * 3.6))km/h (max: \(String(format: "%.0f", absoluteMaxSpeedMps * 3.6))km/h) - REJECTED")
                    return
                }
            }

            // Skip locations that are too close in time (should be ~1 second apart now)
            // Allow some tolerance for timer precision
            if timeDelta < 1.0 {
                print("⌚ ⚠️ [\(sourceLabel)] Location too close in time (Δt=\(String(format: "%.3f", timeDelta))s) - SKIPPING")
                return
            }
        }

        // ═══════════════════════════════════════════════════════════════════════
        // STEP 2: NORMAL FILTERING - Applied unless Raw GPS mode is enabled
        // Thresholds optimized to capture more valid distance points while filtering obvious GPS glitches:
        // - MAX_HORIZONTAL_ACCURACY: 100m (lenient to avoid rejecting valid points in areas with poor signal)
        // - MAX_LOCATION_AGE: 15s (more lenient for watch GPS which can lag)
        // - MAX_DISTANCE_JUMP: 150m with 2.0x dynamic buffer (allows for gaps in GPS recording)
        // ═══════════════════════════════════════════════════════════════════════

        if !useRawGPS {
            // 2a. Check for poor GPS signal quality
            if location.horizontalAccuracy > sourceAccuracyThreshold {
                print("⌚ ⚠️ [\(sourceLabel)] Poor signal: ±\(String(format: "%.0f", location.horizontalAccuracy))m (threshold: \(String(format: "%.0f", sourceAccuracyThreshold))m) - SKIPPING")
                skippedLocationCount += 1
                return
            }

            // 2b. Check for cached/old location (reject stale data)
            let locationAge = Date().timeIntervalSince(location.timestamp)
            if locationAge > sourceAgeThreshold {
                print("⌚ ⚠️ [\(sourceLabel)] Stale location: \(String(format: "%.1f", locationAge))s old (threshold: \(String(format: "%.0f", sourceAgeThreshold))s) - SKIPPING")
                skippedLocationCount += 1
                return
            }

            // 2c. Check for suspicious speed or distance jumps
            if let lastLocation = flight.locations.last {
                let distance = location.distance(to: lastLocation)
                let timeDelta = location.timestamp.timeIntervalSince(lastLocation.timestamp)
                let dynamicMaxJump = max(sourceDistanceJumpThreshold, sourceSpeedThreshold * max(timeDelta, 1.0) * 2.0)  // 2.0x buffer for more lenient filtering

                // Check for unrealistic distance jump
                if distance > dynamicMaxJump {
                    if timeDelta >= reanchorGap {
                        reanchorLocation("Distance jump after \(String(format: "%.1f", timeDelta))s gap")
                        return
                    }
                    print("⌚ ⚠️ [\(sourceLabel)] GPS glitch: distance jump \(String(format: "%.0f", distance))m (threshold: \(String(format: "%.0f", dynamicMaxJump))m) - SKIPPING")
                    skippedLocationCount += 1
                    return
                }

                // Check for unrealistic speed
                if timeDelta > 0 {
                    let instantSpeed = distance / timeDelta
                    if instantSpeed > sourceSpeedThreshold {
                        if timeDelta >= reanchorGap {
                            reanchorLocation("Speed spike after \(String(format: "%.1f", timeDelta))s gap")
                            return
                        }
                        print("⌚ ⚠️ [\(sourceLabel)] GPS glitch: speed \(String(format: "%.0f", instantSpeed * 3.6))km/h (threshold: \(String(format: "%.0f", sourceSpeedThreshold * 3.6))km/h) - SKIPPING")
                        skippedLocationCount += 1
                        return
                    }
                }

                if flight.locations.count >= 2 && timeDelta > 0.5 {
                    let instantSpeed = distance / timeDelta
                    let gpsAcceleration = (instantSpeed - currentMetrics.currentSpeed) / timeDelta
                    let acceleration = abs(gpsAcceleration)
                    let assistedAccelerationThreshold = motionAssistAccelerationThreshold(
                        baseThreshold: sourceAccelerationThreshold,
                        gpsAcceleration: gpsAcceleration,
                        previousLocation: lastLocation,
                        currentLocation: location
                    )
                    if acceleration > assistedAccelerationThreshold {
                        if timeDelta >= reanchorGap {
                            reanchorLocation("Acceleration spike after \(String(format: "%.1f", timeDelta))s gap")
                            return
                        }
                        print("⌚ ⚠️ [\(sourceLabel)] GPS glitch: acceleration \(String(format: "%.1f", acceleration))m/s² (threshold: \(String(format: "%.1f", assistedAccelerationThreshold))m/s²) - SKIPPING")
                        skippedLocationCount += 1
                        return
                    } else if assistedAccelerationThreshold > sourceAccelerationThreshold && acceleration > sourceAccelerationThreshold {
                        print("⌚ 📱 Motion assist allowed GPS acceleration \(String(format: "%.1f", acceleration))m/s² (base \(String(format: "%.1f", sourceAccelerationThreshold)) → \(String(format: "%.1f", assistedAccelerationThreshold))m/s²)")
                    }
                }
            }
        } else {
            // Raw GPS mode - only log once at start
            if flight.locations.isEmpty {
                print("⌚ 🟡 RAW GPS MODE - Only absolute safety checks applied (no signal quality filtering)")
            }
        }

        // Check if we need to skip locations after resume from pause
        if locationsToSkipAfterResume > 0 {
            print("⌚ ⏭️ Skipping location (\(LOCATIONS_TO_SKIP_AFTER_RESUME - locationsToSkipAfterResume + 1)/\(LOCATIONS_TO_SKIP_AFTER_RESUME)) to let GPS stabilize")
            locationsToSkipAfterResume -= 1

            // Add location but don't calculate distance
            flight.locations.append(location)
            lastLocationTime = Date()  // Track location received

            // Update current altitude and other non-distance metrics
            currentMetrics.currentAltitude = location.altitude
            if location.altitude > currentMetrics.maxAltitude {
                currentMetrics.maxAltitude = location.altitude
            }

            return
        }

        // Add to flight (after GPS filtering passed)
        flight.locations.append(location)
        lastLocationTime = Date()  // Track location received
        // A real fix arrived → dead reckoning no longer needed.
        switch source {
        case .iphoneFallback: fallbackDebugStatus = "GPS OK (iPhone relay)"
        case .iphoneAssist: fallbackDebugStatus = "GPS OK (watch+iPhone)"
        case .watchGPS: fallbackDebugStatus = "GPS OK (watch)"
        }
        if let refreshTime = lastManualRefreshRequestTime {
            let delay = Date().timeIntervalSince(refreshTime)
            setNetworkDebugMessage("Fresh fix received in \(String(format: "%.1f", delay))s (±\(String(format: "%.1f", location.horizontalAccuracy))m)")
            lastManualRefreshRequestTime = nil
        } else if source == .iphoneFallback {
            setNetworkDebugMessage("Receiving fallback GPS fixes (iPhone)")
        } else if source == .iphoneAssist {
            setNetworkDebugMessage("Receiving assist GPS fixes (watch+iPhone)")
        } else {
            setNetworkDebugMessage("Receiving GPS fixes (watch)")
        }

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

            print("⌚ GPS #\(flight.locations.count) [\(timeString).\(String(format: "%03d", milliseconds))] src=\(sourceLabel) Δt=\(String(format: "%.2f", timeDelta))s | lat=\(String(format: "%.6f", location.latitude)), lon=\(String(format: "%.6f", location.longitude)) | alt=\(String(format: "%.1f", location.altitude))m | acc=±\(String(format: "%.1f", location.horizontalAccuracy))m")
        }

        // Calculate elapsed time since workout started
        let elapsedTime = Date().timeIntervalSince(flight.startDate)

        // Update metrics with elapsed time for accurate speed calculation
        currentMetrics.updateWithLocation(location, previousLocation: previousLocation, elapsedTime: elapsedTime)

        // Update pressure from LocationManager
        currentMetrics.currentPressure = locationManager.currentPressure

        // Update splits
        currentMetrics.updateSplits(startDate: flight.startDate)
        pruneWatchMemoryIfNeeded(reason: "locationTick")

        // Performance: Throttle iPhone sync to 1Hz (every 1.0s) to match GPS frequency
        let now = Date()
        if now.timeIntervalSince(lastPhoneSyncTime) >= 1.0 {
            sendWorkoutUpdateToPhone()
            lastPhoneSyncTime = now
        }

        // Log summary every 50 locations
        if flight.locations.count % 50 == 0 {
            let totalProcessed = flight.locations.count + skippedLocationCount
            let acceptanceRate = totalProcessed > 0 ? Double(flight.locations.count) / Double(totalProcessed) * 100.0 : 100.0
            print("⌚ Summary: \(flight.locations.count) locations (\(skippedLocationCount) skipped, \(String(format: "%.1f", acceptanceRate))% accepted), Distance: \(String(format: "%.2f", currentMetrics.totalDistance/1000))km, Speed: \(String(format: "%.1f", currentMetrics.smoothedSpeed * 3.6))km/h (smoothed), Avg: \(String(format: "%.1f", currentMetrics.averageSpeed * 3.6))km/h")
        }
    }

    private func transferWorkoutCheckpointToPhone() {
        transferWorkoutCheckpointToPhone(isFinal: false)
    }

    private func transferWorkoutCheckpointToPhone(isFinal: Bool) {
        guard isActive else { return }

        let startIndex = lastPhoneCheckpointLocationCount
        let totalLocationCount = retainedLocationOffset + flight.locations.count
        guard totalLocationCount > startIndex || isFinal else { return }

        let localStartIndex = max(0, startIndex - retainedLocationOffset)
        guard localStartIndex < flight.locations.count || isFinal else { return }

        let newLocations = localStartIndex < flight.locations.count
            ? Array(flight.locations[localStartIndex..<flight.locations.count])
            : []
        var checkpointMetrics = currentMetrics
        checkpointMetrics.clearCheckpointedHistories()

        let payload = FlightCheckpointPayload(
            flightID: flight.id,
            startDate: flight.startDate,
            endDate: flight.endDate,
            locations: newLocations,
            locationStartIndex: startIndex,
            totalLocationCount: totalLocationCount,
            metrics: checkpointMetrics,
            effort: flight.effort,
            workoutType: flight.workoutType,
            isFinal: isFinal,
            workoutUUID: flight.workoutUUID   // links iPhone's local track to the HealthKit workout
        )

        FlightDataStore.shared.mergeFlightCheckpoint(payload)

        saveQueue.async { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let queued = self.connectivityManager.transferFlightCheckpointToPhone(payload)
                if queued {
                    self.lastPhoneCheckpointLocationCount = totalLocationCount
                    self.pruneCheckpointedWorkoutData()
                    print("⌚ 📲 \(isFinal ? "Final" : "10s") checkpoint sent to iPhone - newLocations=\(newLocations.count), total=\(totalLocationCount), retained=\(self.flight.locations.count)")
                }
            }
        }
    }

    private func pruneCheckpointedWorkoutData() {
        let locationsToKeep = minRetainedLocationsOnWatch
        if flight.locations.count > locationsToKeep {
            let removeCount = flight.locations.count - locationsToKeep
            flight.locations.removeFirst(removeCount)
            retainedLocationOffset += removeCount
        }
        currentMetrics.clearCheckpointedHistories()
    }

    private func pruneWatchMemoryIfNeeded(reason: String) {
        guard flight.locations.count > maxRetainedLocationsOnWatch else { return }

        // CRITICAL: never silently discard locations that haven't been sent to iPhone yet.
        // If there are unsent locations, flush a checkpoint first so the data has a chance
        // to reach the phone (and is also persisted to watch disk via mergeFlightCheckpoint).
        let totalLocations = retainedLocationOffset + flight.locations.count
        let unsentCount = max(0, totalLocations - lastPhoneCheckpointLocationCount)
        if unsentCount > 0 {
            print("⌚ 🚨 Emergency prune triggered with \(unsentCount) unsent locations — flushing checkpoint first")
            transferWorkoutCheckpointToPhone(isFinal: false)
        }

        // Only prune locations that have already been sent to phone.
        // This may leave the watch above its memory target if the phone is unreachable,
        // but losing GPS data is worse than memory pressure.
        let sentInMemory = max(0, lastPhoneCheckpointLocationCount - retainedLocationOffset)
        let desiredRemove = flight.locations.count - minRetainedLocationsOnWatch
        let removeCount = max(0, min(desiredRemove, sentInMemory))
        guard removeCount > 0 else {
            print("⌚ 🛑 Emergency prune (\(reason)) skipped — \(flight.locations.count) locations all still unsent")
            return
        }
        flight.locations.removeFirst(removeCount)
        retainedLocationOffset += removeCount
        // DO NOT advance lastPhoneCheckpointLocationCount here — it already reflects sent data.
        currentMetrics.clearCheckpointedHistories()
        print("⌚ 🧹 Emergency memory prune (\(reason)): removed=\(removeCount) sent locations, retained=\(flight.locations.count), offset=\(retainedLocationOffset)")
    }

    private func sendWorkoutUpdateToPhone() {
        let nativeStepCount = nativePedometerStepCount > 0 ? Double(nativePedometerStepCount) : nil
        let nativeStepDistance = nativePedometerDistanceMeters > 0 ? nativePedometerDistanceMeters : nil
        let syncData = WorkoutSyncData(
            isActive: isActive,
            startDate: flight.startDate,
            duration: Date().timeIntervalSince(flight.startDate),
            distance: currentMetrics.totalDistance,
            gpsWorkoutDistance: currentMetrics.totalDistance,
            nativeStepDistance: nativeStepDistance,
            nativeStepCount: nativeStepCount,
            currentSpeed: currentMetrics.smoothedSpeed,  // Send smoothed speed for better display
            averageSpeed: currentMetrics.averageSpeed,
            maxSpeed: currentMetrics.maxSpeed,
            currentAltitude: currentMetrics.currentAltitude,
            maxAltitude: currentMetrics.maxAltitude,
            heartRate: currentMetrics.currentHeartRate,
            averageHeartRate: currentMetrics.averageHeartRate,
            maxHeartRate: currentMetrics.maxHeartRate,
            calories: currentMetrics.caloriesBurned,
            locationCount: flight.locations.count
        )
        print("⌚ 📤 Sync payload: gpsDistance=\(String(format: "%.2f", currentMetrics.totalDistance))m, nativeSteps=\(nativeStepCount.map { String(format: "%.0f", $0) } ?? "nil"), nativeStepDistance=\(nativeStepDistance.map { String(format: "%.2f", $0) } ?? "nil")m")
        connectivityManager.sendWorkoutUpdate(syncData)
    }

    private func sendFinalWorkoutUpdateToPhone(endDate: Date, gpsDistance: Double) {
        let nativeStepCount = nativePedometerStepCount > 0
            ? Double(nativePedometerStepCount)
            : currentMetrics.stepsCount
        let nativeStepDistance = nativePedometerDistanceMeters > 0
            ? nativePedometerDistanceMeters
            : currentMetrics.nativeStepDistance

        let syncData = WorkoutSyncData(
            isActive: false,
            startDate: flight.startDate,
            duration: max(0, endDate.timeIntervalSince(flight.startDate)),
            distance: gpsDistance,
            gpsWorkoutDistance: gpsDistance,
            nativeStepDistance: nativeStepDistance,
            nativeStepCount: nativeStepCount,
            currentSpeed: currentMetrics.smoothedSpeed,
            averageSpeed: currentMetrics.averageSpeed,
            maxSpeed: currentMetrics.maxSpeed,
            currentAltitude: currentMetrics.currentAltitude,
            maxAltitude: currentMetrics.maxAltitude,
            heartRate: currentMetrics.currentHeartRate,
            averageHeartRate: currentMetrics.averageHeartRate,
            maxHeartRate: currentMetrics.maxHeartRate,
            calories: currentMetrics.caloriesBurned,
            locationCount: flight.locations.count
        )

        print("⌚ 📤 Final sync payload: gpsDistance=\(String(format: "%.2f", gpsDistance))m, nativeSteps=\(nativeStepCount.map { String(format: "%.0f", $0) } ?? "nil"), nativeStepDistance=\(nativeStepDistance.map { String(format: "%.2f", $0) } ?? "nil")m")
        connectivityManager.sendWorkoutUpdate(syncData)
    }

    func pauseWorkout() {
        print("⌚ 🎯 pauseWorkout() called - current state: isActive=\(isActive), isPaused=\(isPaused)")

        guard isActive else {
            print("⌚ ⚠️ Cannot pause - workout not active")
            return
        }

        guard !isPaused else {
            print("⌚ ⚠️ Cannot pause - already paused")
            return
        }

        print("⌚ ⏸️ Pausing workout...")

        // End pedometer fallback if active (pause stops movement tracking)
        if isUsingPedometerFallback {
            endPedometerFallback(reason: "workout paused")
        }

        // Update state IMMEDIATELY on main thread for UI responsiveness
        isPaused = true
        print("⌚ ✅ isPaused set to true - UI should update immediately")

        // Log current step count
        if pedometerManager.isPedometerAvailable {
            print("⌚ 👟 Steps at pause: \(pedometerManager.currentStepCount)")
        }

        // Mark to skip multiple locations after resume to let GPS stabilize
        locationsToSkipAfterResume = LOCATIONS_TO_SKIP_AFTER_RESUME

        // Pause HealthKit session and stop GPS on background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Pause HealthKit workout session
            self.workoutSession?.pause()
            print("⌚ 🏥 HealthKit session pause requested")

            // Stop location tracking to save battery
            self.locationManager.stopTracking()
            print("⌚ 📍 GPS tracking stopped")

            DispatchQueue.main.async {
                print("⌚ ✅ Workout paused successfully - will skip \(self.LOCATIONS_TO_SKIP_AFTER_RESUME) locations after resume")
            }
        }
    }

    func resumeWorkout() {
        print("⌚ 🎯 resumeWorkout() called - current state: isActive=\(isActive), isPaused=\(isPaused)")

        guard isActive else {
            print("⌚ ⚠️ Cannot resume - workout not active")
            return
        }

        guard isPaused else {
            print("⌚ ⚠️ Cannot resume - workout not paused")
            return
        }

        print("⌚ ▶️ Resuming workout...")

        // Update state IMMEDIATELY on main thread for UI responsiveness
        isPaused = false
        print("⌚ ✅ isPaused set to false - UI should update immediately")

        // RE-ANCHOR THE GYRO HEADING ACROSS THE PAUSE (same reason as the iPhone). Heading is
        // propagated by the CHANGE in cumulative yaw since the last tick, and ticks stop while
        // paused — so a wrist that turned while stopped had every degree of it applied as one
        // body turn on resume, rotating the whole remaining route. Nothing about how the arm
        // moved while stopped says which way the walk continues.
        lastCumulativeYawForHeading = nil
        // Stale gait evidence describes a walk that has already ended.
        imuStepTimes = []
        imuStepsPendingTick = 0

        // Log current step count
        if pedometerManager.isPedometerAvailable {
            print("⌚ 👟 Steps at resume: \(pedometerManager.currentStepCount)")
        }

        // Resume HealthKit session and restart GPS on background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Resume HealthKit workout session
            self.workoutSession?.resume()
            print("⌚ 🏥 HealthKit session resume requested")

            // Restart location tracking
            self.locationManager.startTracking()
            print("⌚ 📍 GPS tracking restarted")

            DispatchQueue.main.async {
                print("⌚ ✅ Workout resumed successfully - next \(self.locationsToSkipAfterResume) locations will be skipped to allow GPS to stabilize")
            }
        }
    }

    func reset() {
        workoutSession = nil
        workoutBuilder = nil
        flight = Flight()
        currentMetrics = FlightMetrics()
        locationManager.reset()
        pedometerManager.reset()
        isActive = false
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutSession: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async {
            switch toState {
            case .notStarted:
                print("⏸️ Workout session not started")
            case .running:
                print("✅ Workout session is running")
            case .ended:
                print("✅ Workout session ended")
            case .paused:
                print("⏸️ Workout session paused")
            case .prepared:
                print("✅ Workout session prepared")
            case .stopped:
                print("⏹️ Workout session stopped")
            @unknown default:
                print("⚠️ Unknown workout session state")
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("❌ Workout session failed: \(error.localizedDescription)")
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutSession: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // Update heart rate if available
        if collectedTypes.contains(HKQuantityType.quantityType(forIdentifier: .heartRate)!) {
            if let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate),
               let statistics = workoutBuilder.statistics(for: heartRateType),
               let heartRate = statistics.mostRecentQuantity() {

                let heartRateValue = heartRate.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))

                DispatchQueue.main.async {
                    self.currentMetrics.updateWithHeartRate(heartRateValue)
                }
            }
        }

        // Update calories if available
        if collectedTypes.contains(HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!) {
            if let caloriesType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
               let statistics = workoutBuilder.statistics(for: caloriesType),
               let calories = statistics.sumQuantity() {

                let caloriesValue = calories.doubleValue(for: .kilocalorie())

                DispatchQueue.main.async {
                    self.currentMetrics.caloriesBurned = caloriesValue
                }
            }
        }

        // Update resting energy if available
        if collectedTypes.contains(HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned)!) {
            if let basalType = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned),
               let statistics = workoutBuilder.statistics(for: basalType),
               let basal = statistics.sumQuantity() {

                let basalValue = basal.doubleValue(for: .kilocalorie())

                DispatchQueue.main.async {
                    self.currentMetrics.restingEnergyBurned = basalValue
                }
            }
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Handle workout events if needed
    }
}

#endif
