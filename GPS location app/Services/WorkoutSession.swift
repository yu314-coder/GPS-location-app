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
    private let LIVE_ACTIVITY_UPDATE_INTERVAL: TimeInterval = 2.0 // Update every 2 seconds
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var didAttemptSnapshotRestore = false
    private var lastSnapshotSaveDate: Date?
    private let ACTIVE_WORKOUT_AUTOSAVE_INTERVAL: TimeInterval = 20.0
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

    // GPS accuracy thresholds (Modern approach based on Google Maps & fitness apps research)
    private let MAX_HORIZONTAL_ACCURACY: Double = 50.0  // 50m maximum (Apple's recommended threshold)
    private let MAX_LOCATION_AGE: TimeInterval = 10.0  // 10 seconds maximum age (reject cached locations)
    private let DEFAULT_MAX_SPEED_MPS: Double = 20.0
    private let DEFAULT_MAX_DISTANCE_JUMP: Double = 80.0

    // ABSOLUTE SAFETY LIMITS - applied even in Raw GPS mode to prevent impossible physics
    private let ABSOLUTE_MAX_SPEED_MPS: Double = 150.0  // 150 m/s = 540 km/h (no human activity exceeds this)
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
            return "Flight"
        default:
            return "Workout"
        }
    }

    private func maxSpeedThresholdMps(for type: HKWorkoutActivityType) -> Double {
        switch type {
        case .walking:
            return 8.5   // 30.6 km/h
        case .running:
            return 12.5  // 45.0 km/h
        case .hiking:
            return 8.0   // 28.8 km/h
        case .cycling:
            return 30.0  // 108.0 km/h
        case .traditionalStrengthTraining:
            return 6.0   // 21.6 km/h
        case .other:
            // Flight mode handled separately.
            return DEFAULT_MAX_SPEED_MPS
        default:
            return DEFAULT_MAX_SPEED_MPS
        }
    }

    private func maxDistanceJumpThreshold(for type: HKWorkoutActivityType) -> Double {
        switch type {
        case .walking:
            return 45.0
        case .running:
            return 65.0
        case .hiking:
            return 50.0
        case .cycling:
            return 120.0
        case .traditionalStrengthTraining:
            return 35.0
        case .other:
            // Flight mode handled separately.
            return DEFAULT_MAX_DISTANCE_JUMP
        default:
            return DEFAULT_MAX_DISTANCE_JUMP
        }
    }

    private init() {
        self.flight = Flight()
        setupLocationUpdates()
        setupWatchConnectivity()
        setupAppLifecycleObservers()
    }

    private func setupLocationUpdates() {
        locationManager.onLocationUpdate = { [weak self] location in
            self?.processNewLocation(location)
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
            clearActiveWorkoutSnapshot(reason: "snapshotAlreadyEnded", shouldLog: true)
            return
        }

        let age = Date().timeIntervalSince(snapshot.savedAt)
        if age > ACTIVE_WORKOUT_MAX_RESTORE_AGE {
            print("⚠️ Ignoring stale active workout snapshot (\(Int(age/3600))h old)")
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
        NotificationCenter.default.post(name: .workoutDidStart, object: nil)

        print("✅ Flight initialized at: \(startDate)")
        persistActiveWorkoutSnapshot(force: true, reason: "startWorkout", shouldLog: true)

        let activityType: CLActivityType = (workoutType == .other) ? .airborne : .fitness
        locationManager.updateActivityType(activityType)

        if workoutType != .other {
            let speedThresholdKmh = maxSpeedThresholdMps(for: workoutType) * 3.6
            let jumpThreshold = maxDistanceJumpThreshold(for: workoutType)
            print("📏 Movement thresholds: maxSpeed=\(String(format: "%.1f", speedThresholdKmh))km/h, maxJump=\(String(format: "%.0f", jumpThreshold))m")
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
            print("   Settings → Privacy & Security → Location Services → Flight GPS Tracker")
        } else {
            // Already have permission - start tracking immediately
            print("📍 Starting location tracking...")
            locationManager.startTracking()
            print("📍 GPS tracking active - locations will be collected")
        }

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
        print("📊 Smoothed Speed: \(String(format: "%.1f", currentMetrics.smoothedSpeed * 3.6))km/h (\(currentMetrics.smoothedSpeed)m/s)")
        print("📊 Current Speed: \(String(format: "%.1f", currentMetrics.currentSpeed * 3.6))km/h (\(currentMetrics.currentSpeed)m/s)")
        print("📊 Avg Pace: \(currentMetrics.formattedAveragePace)")
        print("📊 Max Altitude: \(String(format: "%.1f", currentMetrics.maxAltitude))m")
        print("📊 Min Altitude: \(String(format: "%.1f", currentMetrics.minAltitude))m")
        print("📊 Altitude Gain: \(String(format: "%.1f", currentMetrics.totalAltitudeGain))m")
        print("📊 Altitude Loss: \(String(format: "%.1f", currentMetrics.totalAltitudeLoss))m")
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
            "maxAltitude": currentMetrics.maxAltitude,
            "minAltitude": currentMetrics.minAltitude,
            "altitudeGain": currentMetrics.totalAltitudeGain,
            "altitudeLoss": currentMetrics.totalAltitudeLoss,
            "averagePace": currentMetrics.averagePacePerKm,
            "gpsPoints": currentMetrics.totalPoints,
            "validPoints": currentMetrics.validPoints,
            "averageAccuracy": currentMetrics.averageAccuracy
        ]
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
            metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: currentMetrics.totalAltitudeGain)
        }
        if currentMetrics.totalAltitudeLoss > 0 {
            metadata[HKMetadataKeyElevationDescended] = HKQuantity(unit: .meter(), doubleValue: currentMetrics.totalAltitudeLoss)
        }

        builder.addMetadata(metadata) { metadataSuccess, metadataError in
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
                            quantity: HKQuantity(unit: .meter(), doubleValue: source.value),
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

                    let energyQuantity = HKQuantity(unit: .kilocalorie(), doubleValue: activeEnergyValue)
                    let energySample = HKCumulativeQuantitySample(
                        type: energyType,
                        quantity: energyQuantity,
                        start: self.flight.startDate,
                        end: endDate
                    )

                    var samples: [HKSample] = distanceSamples
                    samples.append(energySample)

                    if basalEnergyValue > 0, let basalType = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned) {
                        let basalQuantity = HKQuantity(unit: .kilocalorie(), doubleValue: basalEnergyValue)
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

    private func processNewLocation(_ location: FlightLocation) {
        // Check user setting for raw GPS mode
        let useRawGPS = UserDefaults.standard.bool(forKey: "useRawGPS")
        let isFlight = workoutType == .other
        let maxSpeedMps = isFlight ? (10000.0 / 3.6) : maxSpeedThresholdMps(for: workoutType)
        let maxDistanceJump = isFlight ? 500.0 : maxDistanceJumpThreshold(for: workoutType)
        let absoluteMaxSpeedMps = isFlight ? (10000.0 / 3.6) : ABSOLUTE_MAX_SPEED_MPS
        let absoluteMaxDistanceJump = isFlight ? 2000.0 : ABSOLUTE_MAX_DISTANCE_JUMP
        let reanchorGap: TimeInterval = isFlight ? 10.0 : 15.0

        func reanchorLocation(_ reason: String) {
            print("⚠️ \(reason) - reanchoring to new GPS fix")
            flight.locations.append(location)
            NotificationCenter.default.post(
                name: .workoutLocationUpdated,
                object: nil,
                userInfo: ["location": location.toCLLocation()]
            )
            currentMetrics.currentAltitude = location.altitude
            if location.altitude > currentMetrics.maxAltitude {
                currentMetrics.maxAltitude = location.altitude
            }
        }

        // ═══════════════════════════════════════════════════════════════════════
        // STEP 1: ABSOLUTE SAFETY CHECKS - Always applied, even in Raw GPS mode
        // These catch physically impossible GPS glitches that would corrupt data
        // ═══════════════════════════════════════════════════════════════════════

        // 1a. Always reject invalid GPS (negative accuracy = no fix)
        if location.horizontalAccuracy < 0 {
            print("🚫 INVALID GPS (no satellite fix) - REJECTED")
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
                print("🚫 GPS TELEPORT: \(String(format: "%.0f", distance))m jump (max: \(String(format: "%.0f", absoluteMaxDistanceJump))m) - REJECTED")
                return
            }

            // Reject impossible speed (>540 km/h)
            if timeDelta > 0.1 {  // Need at least 100ms between points
                let instantSpeed = distance / timeDelta
                if instantSpeed > absoluteMaxSpeedMps {
                    print("🚫 IMPOSSIBLE SPEED: \(String(format: "%.0f", instantSpeed * 3.6))km/h (max: \(String(format: "%.0f", absoluteMaxSpeedMps * 3.6))km/h) - REJECTED")
                    return
                }
            }
        }

        // ═══════════════════════════════════════════════════════════════════════
        // STEP 2: NORMAL FILTERING - Applied unless Raw GPS mode is enabled
        // ═══════════════════════════════════════════════════════════════════════

        if !useRawGPS {
            // 2a. Check for poor GPS signal quality
            if location.horizontalAccuracy > MAX_HORIZONTAL_ACCURACY {
                print("⚠️ Poor GPS signal: ±\(String(format: "%.0f", location.horizontalAccuracy))m (threshold: \(String(format: "%.0f", MAX_HORIZONTAL_ACCURACY))m) - SKIPPING")
                return
            }

            // 2b. Check for cached/old location (reject stale data)
            let locationAge = Date().timeIntervalSince(location.timestamp)
            if locationAge > MAX_LOCATION_AGE {
                print("⚠️ Stale GPS location: \(String(format: "%.1f", locationAge))s old (threshold: \(String(format: "%.0f", MAX_LOCATION_AGE))s) - SKIPPING")
                return
            }

            // 2c. Check for suspicious speed or distance jumps
            if let lastLocation = flight.locations.last {
                let distance = location.distance(to: lastLocation)
                let timeDelta = location.timestamp.timeIntervalSince(lastLocation.timestamp)
                let dynamicMaxJump = max(maxDistanceJump, maxSpeedMps * max(timeDelta, 1.0) * 1.2)

                // Check for unrealistic distance jump
                if distance > dynamicMaxJump {
                    if timeDelta >= reanchorGap {
                        reanchorLocation("Distance jump after \(String(format: "%.1f", timeDelta))s gap")
                        return
                    }
                    print("⚠️ GPS glitch: distance jump \(String(format: "%.0f", distance))m (threshold: \(String(format: "%.0f", dynamicMaxJump))m) - SKIPPING")
                    return
                }

                // Check for unrealistic speed
                if timeDelta > 0 {
                    let instantSpeed = distance / timeDelta
                    if instantSpeed > maxSpeedMps {
                        if timeDelta >= reanchorGap {
                            reanchorLocation("Speed spike after \(String(format: "%.1f", timeDelta))s gap")
                            return
                        }
                        print("⚠️ GPS glitch: speed \(String(format: "%.0f", instantSpeed * 3.6))km/h (threshold: \(String(format: "%.0f", maxSpeedMps * 3.6))km/h) - SKIPPING")
                        return
                    }
                }
            }
        } else {
            // Raw GPS mode - only log once at start
            if flight.locations.isEmpty {
                print("🟡 RAW GPS MODE - Only absolute safety checks applied (no signal quality filtering)")
            }
        }

        // ═══════════════════════════════════════════════════════════════════════
        // STEP 3: TIME-BASED FILTERING - Ensure minimum 1 second between points
        // ═══════════════════════════════════════════════════════════════════════
        if let lastLocation = flight.locations.last {
            let timeDelta = location.timestamp.timeIntervalSince(lastLocation.timestamp)

            // Skip locations that are too close in time (should be ~1 second apart)
            // Allow some tolerance for timer precision
            if timeDelta < 1.0 {
                print("⏱️ Location too close in time (Δt=\(String(format: "%.3f", timeDelta))s) - SKIPPING")
                return
            }
        }

        // Check if we need to skip locations after resume from pause
        if locationsToSkipAfterResume > 0 {
            print("⏭️ Skipping location (\(LOCATIONS_TO_SKIP_AFTER_RESUME - locationsToSkipAfterResume + 1)/\(LOCATIONS_TO_SKIP_AFTER_RESUME)) to let GPS stabilize")
            locationsToSkipAfterResume -= 1

            // Add location but don't calculate distance
            flight.locations.append(location)
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
