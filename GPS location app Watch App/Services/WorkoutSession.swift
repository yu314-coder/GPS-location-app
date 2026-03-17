import Foundation
import HealthKit
import CoreLocation
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
    private var lastLocationCount: Int = 0  // Track if locations are actually arriving

    @Published var isActive = false
    @Published var isPaused = false
    @Published var flight: Flight
    @Published var currentMetrics = FlightMetrics()
    @Published var lastLocationTime: Date = Date()  // Exposed for UI to monitor GPS health
    @Published var isUsingIPhoneGPSFallback = false
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

    // CRITICAL: Incremental save to prevent memory overflow
    private let INCREMENTAL_SAVE_BATCH_SIZE = 10  // Save every 10 locations
    private var unsavedLocationCount = 0
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
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.gpsapp.watch.pathmonitor")
    private var latestPathStatus: NWPath.Status = .requiresConnection
    private var latestPathInterface = "unknown"

    // GPS accuracy thresholds (Modern approach based on Google Maps & fitness apps research)
    private let MAX_HORIZONTAL_ACCURACY: Double = 100.0  // 100m maximum (more lenient to capture more distance points)
    private let MAX_LOCATION_AGE: TimeInterval = 15.0  // 15 seconds maximum age (more lenient for watch GPS)
    private let MAX_SPEED_MPS: Double = 50.0  // 50 m/s = 180 km/h (realistic maximum for cycling/running)
    private let MAX_DISTANCE_JUMP: Double = 150.0  // 150m maximum jump between points (more lenient to avoid rejecting valid movement)

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
    }

    deinit {
        pathMonitor.cancel()
    }

    private func setupLocationUpdates() {
        locationManager.onLocationUpdate = { [weak self] location in
            self?.processNewLocation(location, source: .watchGPS)
        }

        // Set up iPhone GPS fallback callback
        connectivityManager.onIPhoneLocationReceived = { [weak self] location, mode in
            guard let self = self else { return }
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
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )

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
            lastLocationTime = Date()
            unsavedLocationCount = 0  // Reset unsaved location counter

            let activityType: CLActivityType = (workoutType == .other) ? .airborne : .fitness
            locationManager.updateActivityType(activityType)

            // Start location tracking
            locationManager.startTracking()

            // Start pedometer tracking for step counting
            pedometerManager.startTracking(from: startDate)

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
            print("⌚ 💾 Incremental Save: Active (saves every \(INCREMENTAL_SAVE_BATCH_SIZE) locations)")
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

    func stopWorkout(completion: @escaping (Bool) -> Void) {
        guard let session = workoutSession, let builder = workoutBuilder else {
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

        // Stop ALL timers and monitoring
        stopSessionHealthMonitoring()
        stopKeepAliveTimer()
        stopWatchdogTimer()
        stopForceRestartTimer()

        // Stop iPhone relay/fallback commands
        if connectivityManager.isUsingIPhoneGPS || connectivityManager.isIPhoneGPSRequestPending {
            print("⌚ 📱 Stopping iPhone GPS relay")
            connectivityManager.stopIPhoneGPS()
        }
        connectivityManager.setDualSourceAssistEnabled(false)

        // Stop location tracking
        locationManager.stopTracking()

        // Stop pedometer and get final step count
        pedometerManager.stopTracking()
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
            // Try to save what we have
            FlightDataStore.shared.saveFlight(flight)
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

        // CRITICAL FIX: Save any remaining unsaved locations
        // Since we save incrementally every 10 locations, there may be < 10 unsaved at the end
        print("⌚ 💾 Saving final workout data (incremental save already saved \(flight.locations.count - unsavedLocationCount) locations)...")
        if unsavedLocationCount > 0 {
            print("⌚ 💾 Saving final \(unsavedLocationCount) unsaved locations...")
        }

        // Create a copy to avoid reference issues
        var flightCopy = flight
        let metricsCopy = currentMetrics
        flightCopy.metrics = metricsCopy

        // Save on background queue to avoid blocking
        DispatchQueue.global(qos: .userInitiated).async {
            FlightDataStore.shared.saveFlightIncremental(flightCopy, metrics: metricsCopy)
            DispatchQueue.main.async {
                print("⌚ ✅ Flight saved to local storage - data is safe! Total locations: \(flightCopy.locations.count)")
            }
        }

        unsavedLocationCount = 0
        print("⌚ ✅ Local save initiated successfully")

        // Send one final payload so iPhone receives terminal GPS + native step channels.
        sendFinalWorkoutUpdateToPhone(endDate: endDate, gpsDistance: displayedDistance)

        // Notify iPhone
        connectivityManager.notifyWorkoutStopped()

        // IMPORTANT: Data is already safe on disk from incremental saves
        // HealthKit save is a bonus - if it fails, we still have the data locally
        print("⌚ 🏥 Starting HealthKit save (data already safe on disk)...")
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
        print("⌚ 🧭 Save channels: gpsDistance=\(String(format: "%.2f", displayedDistance))m, nativeSteps=\(nativeStepCountText), nativeStepDistance=\(nativeStepDistanceText)m")

        if let effort = flight.effort {
            metadata["effort"] = effort
            print("⌚ 🧮 Adding effort to workout metadata: \(effort)/10")
        } else {
            print("⌚ ⚠️ Effort missing - no effort metadata will be saved")
        }

        if currentMetrics.totalAltitudeGain > 0 {
            metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: currentMetrics.totalAltitudeGain)
        }
        if currentMetrics.totalAltitudeLoss > 0 {
            metadata[HKMetadataKeyElevationDescended] = HKQuantity(unit: .meter(), doubleValue: currentMetrics.totalAltitudeLoss)
        }

        builder.addMetadata(metadata) { metadataSuccess, metadataError in
            if !metadataSuccess {
                print("⌚ ⚠️ Failed to add workout metadata: \(metadataError?.localizedDescription ?? "Unknown")")
            }

            self.healthKitManager.addWorkoutSamples(
                to: builder,
                metrics: healthKitMetrics,
                activityType: exportType,
                locations: self.flight.locations
            ) {
                // Prefer HKLiveWorkoutDataSource distance, but backfill a manual sample if HealthKit has none.
                // We still add calories and step count using our custom calculations.
                self.healthKitManager.addCaloriesAndStepsSamples(
                    to: builder,
                    metrics: healthKitMetrics,
                    startDate: self.flight.startDate,
                    endDate: endDate,
                    activityType: exportType
                ) {
                    self.healthKitManager.addDistanceSamplesIfMissing(
                        to: builder,
                        metrics: healthKitMetrics,
                        startDate: self.flight.startDate,
                        endDate: endDate,
                        activityType: exportType
                    ) {
                        // 2. End collection
                        builder.endCollection(withEnd: endDate) { [weak self] success, error in
                            guard let self = self else { return }

                            if success {
                                // 3. Finish workout (MUST be before session.end())
                                builder.finishWorkout { workout, error in
                                    if let workout = workout {
                                        self.flight.workoutUUID = workout.uuid
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

                                        // 4. Save route to the existing workout using filtered flight locations
                                        print("⌚ 🗺️ Preparing to save route with \(self.flight.locations.count) filtered locations")
                                        self.healthKitManager.saveRoute(
                                            for: workout,
                                            locations: self.flight.locations
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

            // Every 10 seconds, log that we're still alive
            let elapsed = Date().timeIntervalSince(self.flight.startDate)
            if Int(elapsed).isMultiple(of: 10) {
                let gpsDelay = Date().timeIntervalSince(self.lastLocationTime)
                print("⌚ 💓 ALIVE: \(Int(elapsed))s elapsed, \(self.flight.locations.count) locations, GPS delay: \(Int(gpsDelay))s")
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

    private func processNewLocation(_ location: FlightLocation, source: LocationInputSource) {
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

        // Performance: Throttle iPhone sync to 1Hz (every 1.0s) to match GPS frequency
        let now = Date()
        if now.timeIntervalSince(lastPhoneSyncTime) >= 1.0 {
            sendWorkoutUpdateToPhone()
            lastPhoneSyncTime = now
        }

        // CRITICAL: Incremental save every 10 locations to prevent memory overflow
        unsavedLocationCount += 1
        if unsavedLocationCount >= INCREMENTAL_SAVE_BATCH_SIZE {
            print("⌚ 💾 Triggering incremental save (\(unsavedLocationCount) unsaved locations)")
            saveIncrementally()
        }

        // Log summary every 50 locations
        if flight.locations.count % 50 == 0 {
            let totalProcessed = flight.locations.count + skippedLocationCount
            let acceptanceRate = totalProcessed > 0 ? Double(flight.locations.count) / Double(totalProcessed) * 100.0 : 100.0
            print("⌚ Summary: \(flight.locations.count) locations (\(skippedLocationCount) skipped, \(String(format: "%.1f", acceptanceRate))% accepted), Distance: \(String(format: "%.2f", currentMetrics.totalDistance/1000))km, Speed: \(String(format: "%.1f", currentMetrics.smoothedSpeed * 3.6))km/h (smoothed), Avg: \(String(format: "%.1f", currentMetrics.averageSpeed * 3.6))km/h")
        }
    }

    // MARK: - Incremental Save (Memory Overflow Prevention)

    private func saveIncrementally() {
        // Save on background queue to avoid blocking GPS processing
        saveQueue.async { [weak self] in
            guard let self = self else { return }

            // Create a snapshot of current state
            var flightSnapshot = self.flight
            let metricsSnapshot = self.currentMetrics
            flightSnapshot.metrics = metricsSnapshot

            // Validate data before saving
            guard flightSnapshot.locations.count > 0 else {
                print("⌚ ⚠️ Skipping incremental save - no locations yet")
                return
            }

            // Save to disk
            FlightDataStore.shared.saveFlightIncremental(flightSnapshot, metrics: metricsSnapshot)

            // Reset counter only on success
            DispatchQueue.main.async {
                self.unsavedLocationCount = 0
                print("⌚ ✅ Incremental save completed - \(flightSnapshot.locations.count) total locations on disk")
            }
        }
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
