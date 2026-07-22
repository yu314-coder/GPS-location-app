import Foundation
import HealthKit
import CoreLocation
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
    private let MOTION_BIAS_RATE: Double = 0.01    // learning rate during quiet periods
    private let MOTION_BIAS_GATE: Double = 0.3     // m/s²: above this = REAL accel → freeze

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

    func startWorkout() {
        guard !isActive else {
            print("⚠️ startWorkout ignored: workout already active")
            NotificationCenter.default.post(name: .openLiveSessionRequested, object: nil)
            return
        }

        print("🚀 Starting workout session...")
        clearActiveWorkoutSnapshot(reason: "newWorkoutStart")

        // Initialize flight first
        let startDate = Date()
        flight = Flight(startDate: startDate)
        flight.workoutType = workoutType.rawValue
        isActive = true
        lastRealLocationTime = startDate
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
        isInertialStationary = zuptWindowFilled
            && peakAccel < ZUPT_ACCEL_THRESHOLD
            && peakRotation < ZUPT_ROTATION_THRESHOLD

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

        // Moving: keep learning the bias whenever residual acceleration is small (this is what
        // cancels gravity leakage during a long cruise), but FREEZE it during genuine
        // acceleration or braking so it cannot absorb real motion.
        if sqrt(rN * rN + rE * rE) < MOTION_BIAS_GATE {
            accelBiasNorth += rN * MOTION_BIAS_RATE
            accelBiasEast += rE * MOTION_BIAS_RATE
        }

        // Honest trapezoidal integration — no leak, no cap, no damping.
        let iN = worldAccelNorth - accelBiasNorth
        let iE = worldAccelEast - accelBiasEast
        motionVelNorth += ((prevResidualNorth + iN) / 2.0) * dt
        motionVelEast += ((prevResidualEast + iE) / 2.0) * dt
        prevResidualNorth = iN
        prevResidualEast = iE
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
            guard anchor != nil else { return }
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
        if nextSpeed > 0.1 {
            motionHeadingDegrees = normalizedHeading(atan2(motionVelEast, motionVelNorth) * 180 / .pi)
        }
        // The integrated velocity vector only gives a real bearing when the attitude frame is
        // anchored to magnetic north. With `.xArbitraryZVertical` the world X axis points in
        // an unknown direction, so the SPEED (and hence distance) is still usable but the
        // direction is not — fall back to compass/GPS course for the bearing in that case.
        let canUseInertialHeading = nextSpeed > 0.1 && locationManager.motionReferenceFrameIsAbsolute
        let headingDegrees = canUseInertialHeading
            ? normalizedHeading(motionHeadingDegrees)
            : normalizedHeading(
                // Prefer GPS COURSE (true direction of travel) over the compass: inside a
                // vehicle — especially an aircraft — the magnetometer reads the metal shell
                // and local EMI, not the heading, so course-over-ground is far more reliable.
                anchor.flatMap { validCourse($0.course) }
                    ?? locationManager.currentCompassHeading
                    ?? locationManager.currentMotionDirectionDegrees
                    ?? 0.0
              )

        let distance = ((estimatedFallbackSpeed + nextSpeed) / 2.0) * dt
        estimatedFallbackSpeed = nextSpeed
        motionFallbackStatus = String(format: "DR%@ %.0fkm/h +%.0fm",
                                      forceMotionFallback ? " FORCED" : "",
                                      nextSpeed * 3.6,
                                      estimatedFallbackDistanceAdded)

        guard distance >= 0.25 else { return }
        appendEstimatedLocation(distanceMeters: distance, headingDegrees: headingDegrees, timestamp: now)
        estimatedFallbackDistanceAdded += distance
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
        let course = anchor.flatMap { validCourse($0.course) }
            ?? locationManager.currentCompassHeading
            ?? locationManager.currentMotionDirectionDegrees
            ?? 0.0
        resetInertialState(seedSpeed: seed, courseDegrees: course)
        print("📍 Estimated-location fallback started after \(String(format: "%.1f", gapSeconds))s without GPS (seed \(String(format: "%.1f", seed * 3.6))km/h @ \(Int(course))°)")
    }

    private func endEstimatedLocationFallback(reason: String) {
        guard isUsingEstimatedLocationFallback else { return }
        print("📍 Estimated-location fallback ended: \(reason)")
        isUsingEstimatedLocationFallback = false
        lastEstimatedFallbackTick = nil
        estimatedFallbackSpeed = 0.0
        estimatedFallbackDistanceAdded = 0.0
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

    private func appendEstimatedLocation(distanceMeters: Double, headingDegrees: Double, timestamp: Date) {
        guard let previousLocation = flight.locations.last else { return }
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
        )

        flight.locations.append(estimatedLocation)
        NotificationCenter.default.post(
            name: .workoutLocationUpdated,
            object: nil,
            userInfo: ["location": estimatedLocation.toCLLocation()]
        )
        currentMetrics.updateWithLocation(estimatedLocation, previousLocation: previousLocation, elapsedTime: activeDuration)
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
            return
        }

        // Accept every usable Core Location GPS fix on iPhone/iPad. Distance is
        // calculated from the recorded track without speed, jump, acceleration,
        // stale-time, or accuracy caps.
        if location.horizontalAccuracy < 0 {
            print("🚫 INVALID GPS (no satellite fix) - REJECTED")
            return
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

        // Add to flight (after GPS filtering passed)
        flight.locations.append(location)
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
