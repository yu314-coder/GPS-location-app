import Foundation
import HealthKit
import CoreLocation

class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()

    private var healthStore = HKHealthStore()
    private let saveQueue = DispatchQueue(label: "com.flightgps.healthkit.save", qos: .userInitiated)
    private let debugWorkoutMetadataKey = "com.exmstc.gps.debugWorkout"
    private let debugStepOnlyMetadataKey = "com.exmstc.gps.debugStepOnly"
    @Published var isAuthorized = false

    // HealthKit types we need permission for
    private let typesToShare: Set<HKSampleType> = [
        HKObjectType.workoutType(),
        HKSeriesType.workoutRoute(),
        HKQuantityType.quantityType(forIdentifier: .heartRate)!,
        HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
        HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned)!,
        HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!,
        HKQuantityType.quantityType(forIdentifier: .distanceCycling)!,
        // Speed/Pace
        HKQuantityType.quantityType(forIdentifier: .runningSpeed)!,
        HKQuantityType.quantityType(forIdentifier: .cyclingSpeed)!,
        // ADVANCED METRICS: Running dynamics
        HKQuantityType.quantityType(forIdentifier: .runningPower)!,
        HKQuantityType.quantityType(forIdentifier: .runningStrideLength)!,
        HKQuantityType.quantityType(forIdentifier: .walkingStepLength)!,
        HKQuantityType.quantityType(forIdentifier: .runningVerticalOscillation)!,
        HKQuantityType.quantityType(forIdentifier: .runningGroundContactTime)!,
        // ADVANCED METRICS: Cadence
        HKQuantityType.quantityType(forIdentifier: .stepCount)!,
        HKQuantityType.quantityType(forIdentifier: .cyclingCadence)!
    ]

    private let typesToRead: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKSeriesType.workoutRoute(),
        HKQuantityType.quantityType(forIdentifier: .heartRate)!,
        HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
        HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned)!,
        HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!,
        HKQuantityType.quantityType(forIdentifier: .distanceCycling)!,
        // Speed/Pace
        HKQuantityType.quantityType(forIdentifier: .runningSpeed)!,
        HKQuantityType.quantityType(forIdentifier: .cyclingSpeed)!,
        // ADVANCED METRICS: Running dynamics
        HKQuantityType.quantityType(forIdentifier: .runningPower)!,
        HKQuantityType.quantityType(forIdentifier: .runningStrideLength)!,
        HKQuantityType.quantityType(forIdentifier: .walkingStepLength)!,
        HKQuantityType.quantityType(forIdentifier: .runningVerticalOscillation)!,
        HKQuantityType.quantityType(forIdentifier: .runningGroundContactTime)!,
        // ADVANCED METRICS: Cadence
        HKQuantityType.quantityType(forIdentifier: .stepCount)!,
        HKQuantityType.quantityType(forIdentifier: .cyclingCadence)!
    ]

    /// Check if HealthKit is already authorized without requesting permission
    /// IMPORTANT: Only call this ONCE at app startup to avoid overwhelming HealthKit
    /// Authorisation as a label, computed on the spot rather than via the published flag.
    ///
    /// `checkAuthorizationStatus()` updates `isAuthorized` on the main queue ASYNCHRONOUSLY, and
    /// the settings screen read the flag on the line after calling it — so it always rendered
    /// the PREVIOUS value, which on first appearance is false. The screen said "Not Authorized"
    /// while Health was fully authorised. This is synchronous, so there is nothing to race.
    ///
    /// Note that HealthKit only ever reports SHARING (write) permission. Read permission is
    /// deliberately unknowable — Apple hides it so an app cannot infer what a person declined to
    /// share — so this reports what can be answered, and says so.
    var writeAuthorizationLabel: String {
        guard HKHealthStore.isHealthDataAvailable() else { return "Unavailable" }
        switch healthStore.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: return "Authorized"
        case .sharingDenied: return "Denied"
        case .notDetermined: return "Not Determined"
        @unknown default: return "Unknown"
        }
    }

    func checkAuthorizationStatus() {
        guard HKHealthStore.isHealthDataAvailable() else {
            DispatchQueue.main.async {
                self.isAuthorized = false
            }
            return
        }

        // Check authorization status for a sample type
        let workoutType = HKObjectType.workoutType()
        let status = healthStore.authorizationStatus(for: workoutType)

        DispatchQueue.main.async {
            // sharingAuthorized means we can write workouts
            let wasAuthorized = self.isAuthorized
            self.isAuthorized = (status == .sharingAuthorized)

            // Only log if status changed or first check
            if !wasAuthorized || !self.isAuthorized {
                print("🏥 HealthKit authorization status: \(self.isAuthorized ? "✅ Authorized" : "❌ Not Authorized")")
            }

            if !self.isAuthorized {
                print("⚠️ HealthKit shows as not authorized")
                print("💡 TIP: Open Settings → Health → Data Access & Devices → Your App")
                print("💡 The permission toggle may appear OFF until you visit that page")
            }
        }
    }

    /// Verify HealthKit connection is working by performing a test query
    /// This catches the case where permissions appear granted but connection fails
    func verifyHealthKitConnection(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("🏥 HealthKit not available on this device")
            completion(false)
            return
        }

        let workoutType = HKObjectType.workoutType()
        let status = healthStore.authorizationStatus(for: workoutType)

        guard status == .sharingAuthorized else {
            print("🏥 HealthKit not authorized (status: \(status.rawValue))")
            print("💡 IMPORTANT: If you just granted permission, please:")
            print("   1. Open the Health app")
            print("   2. Go to Settings → Health → Data Access & Devices")
            print("   3. Tap on this app to activate the connection")
            completion(false)
            return
        }

        // Perform a test query to verify connection is working
        print("🏥 Testing HealthKit connection...")
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-60), end: Date(), options: .strictEndDate)
        let query = HKSampleQuery(sampleType: workoutType, predicate: predicate, limit: 1, sortDescriptors: nil) { query, samples, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ HealthKit connection test FAILED: \(error.localizedDescription)")
                    print("💡 This usually means the permission isn't fully activated")
                    print("💡 Please open Settings → Health and visit this app's permissions page")
                    completion(false)
                } else {
                    print("✅ HealthKit connection test PASSED - ready to save workouts")
                    completion(true)
                }
            }
        }

        healthStore.execute(query)
    }

    /// Smoke test: create a tiny workout and delete it to verify write access.
    func verifyHealthKitWriteAccess(completion: @escaping (Bool, String?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, "HealthKit not available")
            return
        }
        guard isAuthorized else {
            completion(false, "Not authorized")
            return
        }

        let start = Date().addingTimeInterval(-5)
        let end = Date()

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: .local())
        builder.beginCollection(withStart: start) { success, error in
            guard success else {
                DispatchQueue.main.async {
                    completion(false, error?.localizedDescription ?? "Begin collection failed")
                }
                return
            }

            builder.endCollection(withEnd: end) { success, error in
                guard success else {
                    DispatchQueue.main.async {
                        completion(false, error?.localizedDescription ?? "End collection failed")
                    }
                    return
                }

                builder.finishWorkout { workout, error in
                    guard let workout = workout else {
                        DispatchQueue.main.async {
                            completion(false, error?.localizedDescription ?? "Finish workout failed")
                        }
                        return
                    }

                    self.deleteWorkout(workout) { success, deleteError in
                        DispatchQueue.main.async {
                            if success {
                                completion(true, nil)
                            } else {
                                completion(false, deleteError?.localizedDescription ?? "Delete failed")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Save a debug workout that writes only step-count samples and no route/distance.
    func saveStepOnlyDebugWorkout(
        stepsCount: Double,
        at timestamp: Date = Date(),
        completion: @escaping (Bool, Error?, HKWorkout?) -> Void
    ) {
        saveQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isAuthorized else {
                completion(
                    false,
                    NSError(
                        domain: "HealthKit",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "HealthKit not authorized"]
                    ),
                    nil
                )
                return
            }

            let startDate = timestamp
            let endDate = timestamp.addingTimeInterval(1)
            let metadata: [String: Any] = [
                "origin": "Debug",
                "destination": "Step Only",
                self.debugWorkoutMetadataKey: true,
                self.debugStepOnlyMetadataKey: true,
                "com.exmstc.gps.nativeStepCount": stepsCount,
                HKMetadataKeyTimeZone: TimeZone.current.identifier
            ]

            let workout = HKWorkout(
                activityType: .walking,
                start: startDate,
                end: endDate,
                workoutEvents: nil,
                totalEnergyBurned: nil,
                totalDistance: nil,
                device: .local(),
                metadata: sanitizedHealthKitMetadata(metadata)
            )

            self.healthStore.save(workout) { success, error in
                guard success else {
                    let finalError = error ?? NSError(
                        domain: "HealthKit",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Debug workout save failed with nil error"]
                    )
                    completion(false, finalError, nil)
                    return
                }

                guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
                    completion(
                        false,
                        NSError(
                            domain: "HealthKit",
                            code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "Step count type unavailable"]
                        ),
                        workout
                    )
                    return
                }

                let stepSamples: [HKSample] = [
                    HKQuantitySample(
                        type: stepType,
                        quantity: HKQuantitySafe(unit: .count(), doubleValue: stepsCount),
                        start: startDate,
                        end: endDate,
                        metadata: [
                            self.debugWorkoutMetadataKey: true,
                            self.debugStepOnlyMetadataKey: true,
                            HKMetadataKeyTimeZone: TimeZone.current.identifier
                        ]
                    )
                ]

                self.associateSamples(stepSamples, to: workout, label: "debug step") { sampleSuccess, sampleError in
                    if sampleSuccess {
                        print("✅ Step-only debug workout saved: \(stepsCount) steps @ \(timestamp)")
                    } else {
                        print("⚠️ Step-only debug step sample save failed: \(sampleError?.localizedDescription ?? "Unknown")")
                    }
                    completion(sampleSuccess, sampleError, workout)
                }
            }
        }
    }

    func deleteStepOnlyDebugEntries(completion: @escaping (_ deletedWorkouts: Int, _ deletedStepSamples: Int, _ error: Error?) -> Void) {
        guard isAuthorized else {
            completion(
                0,
                0,
                NSError(
                    domain: "HealthKit",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "HealthKit not authorized"]
                )
            )
            return
        }

        let allowedValues = [NSNumber(value: true)]
        let workoutPredicate = HKQuery.predicateForObjects(withMetadataKey: debugStepOnlyMetadataKey, allowedValues: allowedValues)
        let stepPredicate = HKQuery.predicateForObjects(withMetadataKey: debugStepOnlyMetadataKey, allowedValues: allowedValues)
        let workoutType = HKObjectType.workoutType()
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            completion(0, 0, NSError(domain: "HealthKit", code: -3, userInfo: [NSLocalizedDescriptionKey: "Step count type unavailable"]))
            return
        }

        let queryGroup = DispatchGroup()
        var debugWorkouts: [HKWorkout] = []
        var debugStepSamples: [HKSample] = []
        var queryError: Error?

        queryGroup.enter()
        let workoutQuery = HKSampleQuery(
            sampleType: workoutType,
            predicate: workoutPredicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { _, results, error in
            if let error {
                queryError = error
            } else {
                debugWorkouts = results as? [HKWorkout] ?? []
            }
            queryGroup.leave()
        }
        healthStore.execute(workoutQuery)

        queryGroup.enter()
        let stepQuery = HKSampleQuery(
            sampleType: stepType,
            predicate: stepPredicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { _, results, error in
            if let error {
                queryError = error
            } else {
                debugStepSamples = results ?? []
            }
            queryGroup.leave()
        }
        healthStore.execute(stepQuery)

        queryGroup.notify(queue: .main) {
            if let queryError {
                completion(0, 0, queryError)
                return
            }

            if debugWorkouts.isEmpty && debugStepSamples.isEmpty {
                completion(0, 0, nil)
                return
            }

            let deleteGroup = DispatchGroup()
            var deletedWorkoutCount = 0
            var deletedStepSampleCount = 0
            var deleteError: Error?

            if !debugStepSamples.isEmpty {
                deleteGroup.enter()
                self.healthStore.delete(debugStepSamples) { success, error in
                    if success {
                        deletedStepSampleCount = debugStepSamples.count
                    } else if let error {
                        deleteError = error
                    }
                    deleteGroup.leave()
                }
            }

            if !debugWorkouts.isEmpty {
                deleteGroup.enter()
                self.healthStore.delete(debugWorkouts) { success, error in
                    if success {
                        deletedWorkoutCount = debugWorkouts.count
                    } else if let error {
                        deleteError = error
                    }
                    deleteGroup.leave()
                }
            }

            deleteGroup.notify(queue: .main) {
                completion(deletedWorkoutCount, deletedStepSampleCount, deleteError)
            }
        }
    }

    private func associateSamples(
        _ samples: [HKSample],
        to workout: HKWorkout,
        label: String,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        guard !samples.isEmpty else {
            completion(true, nil)
            return
        }

        healthStore.add(samples, to: workout) { success, error in
            if success {
                print("✅ Associated \(samples.count) \(label) sample(s) with workout \(workout.uuid)")
            } else {
                print("⚠️ Failed to associate \(label) sample(s) with workout \(workout.uuid): \(error?.localizedDescription ?? "Unknown")")
            }
            completion(success, error)
        }
    }

    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            let error = NSError(domain: "HealthKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "HealthKit is not available on this device"])
            DispatchQueue.main.async {
                completion(false, error)
            }
            return
        }

        print("🏥 Requesting HealthKit authorization...")

        // CRITICAL: requestAuthorization completion runs on BACKGROUND THREAD
        // Must dispatch all UI updates to main thread to avoid crashes
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { [weak self] success, error in
            print("🏥 HealthKit authorization result: \(success ? "✅ Success" : "❌ Failed")")
            if let error = error {
                print("🏥 HealthKit error: \(error.localizedDescription)")
            }

            // MUST run on main thread to update @Published properties
            DispatchQueue.main.async {
                self?.isAuthorized = success
                completion(success, error)
            }
        }
    }

    func saveWorkout(
        flight: Flight,
        locations: [FlightLocation],
        metrics: FlightMetrics,
        completion: @escaping (Bool, Error?, HKWorkout?) -> Void
    ) {
        print("🏥 [HealthKit] Save requested: flight=\(flight.id), locations=\(locations.count), distance=\(String(format: "%.2f", metrics.totalDistance/1000))km")
        let nativeStepsText = metrics.stepsCount.map { String(format: "%.0f", $0) } ?? "nil"
        let nativeDistanceText = metrics.nativeStepDistance.map { String(format: "%.2f", $0) } ?? "nil"
        print("🏥 [HealthKit] Channels: gpsDistance=\(String(format: "%.2f", metrics.totalDistance))m, nativeSteps=\(nativeStepsText), nativeStepDistance=\(nativeDistanceText)m")
        saveQueue.async { [weak self] in
            self?.attemptSaveWorkout(
                flight: flight,
                locations: locations,
                metrics: metrics,
                attempt: 0,
                completion: completion
            )
        }
    }

    /// Public direct-save path (no builder state machine).
    func saveWorkoutDirectly(
        flight: Flight,
        locations: [FlightLocation],
        metrics: FlightMetrics,
        completion: @escaping (Bool, Error?, HKWorkout?) -> Void
    ) {
        saveQueue.async { [weak self] in
            self?.saveWorkoutDirectlyInternal(
                flight: flight,
                locations: locations,
                metrics: metrics,
                completion: completion
            )
        }
    }

    private func attemptSaveWorkout(
        flight: Flight,
        locations: [FlightLocation],
        metrics: FlightMetrics,
        attempt: Int,
        completion: @escaping (Bool, Error?, HKWorkout?) -> Void
    ) {
        print("🏥 [HealthKit] Save attempt \(attempt + 1) starting (authorized=\(isAuthorized))")
        guard isAuthorized else {
            completion(false, NSError(domain: "HealthKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "HealthKit not authorized"]), nil)
            return
        }

        let endDate = flight.endDate ?? flight.startDate.addingTimeInterval(max(metrics.duration, 0))

        // Create workout configuration
        let configuration = HKWorkoutConfiguration()
        if let rawValue = flight.workoutType,
           let activityType = HKWorkoutActivityType(rawValue: rawValue) {
            configuration.activityType = exportActivityType(activityType)
        } else {
            configuration.activityType = .walking // Fallback for older data
        }
        configuration.locationType = .outdoor

        // Create workout builder
        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: .local())

        // Begin collection
        builder.beginCollection(withStart: flight.startDate) { [weak self] success, error in
            guard let self = self else { return }
            guard success else {
                self.handleSaveFailure(
                    flight: flight,
                    locations: locations,
                    metrics: metrics,
                    attempt: attempt,
                    error: error,
                    completion: completion
                )
                return
            }

            // Add metadata including HealthKit standard elevation keys
            var metadata: [String: Any] = [
                "origin": flight.origin ?? "Unknown",
                "destination": flight.destination ?? "Unknown",
                "maxAltitude": metrics.maxAltitude,
                "minAltitude": metrics.minAltitude,
                "maxSpeed": metrics.maxSpeed,
                "maxAcceleration": metrics.maxAcceleration ?? 0,
                "maxDeceleration": metrics.maxDeceleration ?? 0,
                "averageAcceleration": metrics.averageAcceleration ?? 0,
                "maxMotionAcceleration": metrics.maxMotionAcceleration ?? 0,
                "averageMotionAcceleration": metrics.averageMotionAcceleration ?? 0,
                "barometricAltitudeGain": metrics.barometricAltitudeGain ?? 0,
                "barometricAltitudeLoss": metrics.barometricAltitudeLoss ?? 0,
                "maxClimbRate": metrics.maxClimbRate ?? 0,
                "maxDescentRate": metrics.maxDescentRate ?? 0,
                "averageAccuracy": metrics.averageAccuracy,
                "averageGPSQualityScore": metrics.averageGPSQualityScore ?? 0,
                "worstGPSQualityScore": metrics.worstGPSQualityScore ?? 0
            ]
            metrics.healthKitSensorMetadata.forEach { metadata[$0.key] = $0.value }
            if let effort = flight.effort {
                metadata["effort"] = effort
            }
            metadata["com.exmstc.gps.gpsDistanceMeters"] = metrics.totalDistance
            if let nativeStepDistance = metrics.nativeStepDistance, nativeStepDistance > 0 {
                metadata["com.exmstc.gps.nativeStepDistanceMeters"] = nativeStepDistance
            }
            if let stepCount = metrics.stepsCount, stepCount > 0 {
                metadata["com.exmstc.gps.nativeStepCount"] = stepCount
            }
            metadata[HKMetadataKeyTimeZone] = TimeZone.current.identifier

            // Add average speed metadata (HealthKit standard key)
            if metrics.averageSpeed > 0 {
                let avgSpeedQuantity = HKQuantitySafe(unit: HKUnit.meter().unitDivided(by: .second()), doubleValue: metrics.averageSpeed)
                metadata[HKMetadataKeyAverageSpeed] = avgSpeedQuantity
            }

            // Add max speed metadata
            if metrics.maxSpeed > 0 {
                let maxSpeedQuantity = HKQuantitySafe(unit: HKUnit.meter().unitDivided(by: .second()), doubleValue: metrics.maxSpeed)
                metadata[HKMetadataKeyMaximumSpeed] = maxSpeedQuantity
            }

            // Add HealthKit standard elevation metadata (required for Fitness app)
            if metrics.totalAltitudeGain > 0 {
                metadata[HKMetadataKeyElevationAscended] = HKQuantitySafe(unit: .meter(), doubleValue: metrics.totalAltitudeGain)
            }
            if metrics.totalAltitudeLoss > 0 {
                metadata[HKMetadataKeyElevationDescended] = HKQuantitySafe(unit: .meter(), doubleValue: metrics.totalAltitudeLoss)
            }

            builder.addMetadata(sanitizedHealthKitMetadata(metadata)) { [weak self] success, error in
                guard let self = self else { return }
                guard success else {
                    self.handleSaveFailure(
                        flight: flight,
                        locations: locations,
                        metrics: metrics,
                        attempt: attempt,
                        error: error,
                        completion: completion
                    )
                    return
                }

                self.addWorkoutSamples(
                    to: builder,
                    metrics: metrics,
                    activityType: configuration.activityType,
                    locations: locations,
                    startDate: flight.startDate,
                    endDate: endDate
                ) {
                    // Note: Altitude is included automatically in CLLocation route data
                    // HealthKit extracts altitude from the workout route we save later
                    // Heart rate data is automatically included from HKWorkoutSession

                    // End collection
                    builder.endCollection(withEnd: endDate) { [weak self] success, error in
                        guard let self = self else { return }
                        guard success else {
                            self.handleSaveFailure(
                                flight: flight,
                                locations: locations,
                                metrics: metrics,
                                attempt: attempt,
                                error: error,
                                completion: completion
                            )
                            return
                        }

                        // Finish workout
                        builder.finishWorkout { [weak self] workout, error in
                            guard let self = self else { return }
                            if let workout = workout {
                                print("✅ Workout created: \(workout.uuid)")
                                print("   Duration: \(workout.duration)s")
                                print("   Activity: \(workout.workoutActivityType.rawValue)")

                                guard self.shouldSaveRoute(for: locations) else {
                                    print("ℹ️ Skipping route save: not enough valid route points")
                                    completion(true, nil, workout)
                                    return
                                }

                                // Now save the route - this provides distance and pace data
                                self.saveRoute(for: workout, locations: locations) { success, routeError in
                                    completion(success, routeError, workout)
                                }
                            } else {
                                self.handleSaveFailure(
                                    flight: flight,
                                    locations: locations,
                                    metrics: metrics,
                                    attempt: attempt,
                                    error: error,
                                    completion: completion
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleSaveFailure(
        flight: Flight,
        locations: [FlightLocation],
        metrics: FlightMetrics,
        attempt: Int,
        error: Error?,
        completion: @escaping (Bool, Error?, HKWorkout?) -> Void
    ) {
        if attempt == 0, shouldRetrySave(for: error) {
            resetHealthStoreForRecovery()
            saveQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.attemptSaveWorkout(
                    flight: flight,
                    locations: locations,
                    metrics: metrics,
                    attempt: 1,
                    completion: completion
                )
            }
            return
        }

        print("🏥 [HealthKit] Builder failed - attempting direct workout save")
        saveQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.saveWorkoutDirectlyInternal(
                flight: flight,
                locations: locations,
                metrics: metrics,
                completion: completion
            )
        }
        return

        let finalError = error ?? NSError(
            domain: "HealthKit",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Unknown HealthKit error (nil error)"]
        )
        completion(false, finalError, nil)
    }

    private func shouldRetrySave(for error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }

        if error.domain == NSCocoaErrorDomain && (error.code == 4097 || error.code == 4099) {
            return true
        }

        if error.domain == "com.apple.healthkit" && error.code == 3 {
            return true
        }

        return false
    }

    private func shouldFallbackToDirectSave(for error: Error?) -> Bool {
        return shouldRetrySave(for: error)
    }

    private func saveWorkoutDirectlyInternal(
        flight: Flight,
        locations: [FlightLocation],
        metrics: FlightMetrics,
        completion: @escaping (Bool, Error?, HKWorkout?) -> Void
    ) {
        let endDate = flight.endDate ?? flight.startDate.addingTimeInterval(max(metrics.duration, 0))
        let activityType = flight.workoutType.flatMap { HKWorkoutActivityType(rawValue: $0) } ?? .walking

        var metadata: [String: Any] = [
            "origin": flight.origin ?? "Unknown",
            "destination": flight.destination ?? "Unknown",
            "maxAltitude": metrics.maxAltitude,
            "minAltitude": metrics.minAltitude,
            "maxSpeed": metrics.maxSpeed,
            "maxAcceleration": metrics.maxAcceleration ?? 0,
            "maxDeceleration": metrics.maxDeceleration ?? 0,
            "averageAcceleration": metrics.averageAcceleration ?? 0,
            "maxMotionAcceleration": metrics.maxMotionAcceleration ?? 0,
            "averageMotionAcceleration": metrics.averageMotionAcceleration ?? 0,
            "barometricAltitudeGain": metrics.barometricAltitudeGain ?? 0,
            "barometricAltitudeLoss": metrics.barometricAltitudeLoss ?? 0,
            "maxClimbRate": metrics.maxClimbRate ?? 0,
            "maxDescentRate": metrics.maxDescentRate ?? 0,
            "averageAccuracy": metrics.averageAccuracy,
            "averageGPSQualityScore": metrics.averageGPSQualityScore ?? 0,
            "worstGPSQualityScore": metrics.worstGPSQualityScore ?? 0,
            "com.exmstc.gps.gpsDistanceMeters": metrics.totalDistance,
            HKMetadataKeyTimeZone: TimeZone.current.identifier
        ]
        metrics.healthKitSensorMetadata.forEach { metadata[$0.key] = $0.value }

        if let effort = flight.effort {
            metadata["effort"] = effort
        }
        if let nativeStepDistance = metrics.nativeStepDistance, nativeStepDistance > 0 {
            metadata["com.exmstc.gps.nativeStepDistanceMeters"] = nativeStepDistance
        }
        if let stepCount = metrics.stepsCount, stepCount > 0 {
            metadata["com.exmstc.gps.nativeStepCount"] = stepCount
        }

        let totalDistance = metrics.totalDistance > 0
            ? HKQuantitySafe(unit: .meter(), doubleValue: metrics.totalDistance)
            : nil
        let totalEnergy = metrics.caloriesBurned > 0
            ? HKQuantitySafe(unit: .kilocalorie(), doubleValue: metrics.caloriesBurned)
            : nil

        let workout = HKWorkout(
            activityType: exportActivityType(activityType),
            start: flight.startDate,
            end: endDate,
            workoutEvents: nil,
            totalEnergyBurned: totalEnergy,
            totalDistance: totalDistance,
            device: .local(),
            metadata: sanitizedHealthKitMetadata(metadata)
        )

        healthStore.save(workout) { success, error in
            if success {
                print("✅ Direct workout saved: \(workout.uuid)")

                let exportType = self.exportActivityType(activityType)
                let supplementalSamples = self.buildDirectSaveSupplementalSamples(
                    metrics: metrics,
                    activityType: exportType,
                    startDate: flight.startDate,
                    endDate: endDate
                )

                let continueWithRoute: (Bool, Error?) -> Void = { sampleSuccess, sampleError in
                    guard self.shouldSaveRoute(for: locations) else {
                        print("ℹ️ Skipping route save: not enough valid route points")
                        completion(sampleSuccess, sampleError, workout)
                        return
                    }

                    self.saveRoute(for: workout, locations: locations) { routeSuccess, routeError in
                        let finalSuccess = sampleSuccess && routeSuccess
                        let finalError = routeError ?? sampleError
                        completion(finalSuccess, finalError, workout)
                    }
                }

                guard !supplementalSamples.isEmpty else {
                    continueWithRoute(true, nil)
                    return
                }

                print("✅ Direct save adding \(supplementalSamples.count) supplemental samples")
                self.associateSamples(supplementalSamples, to: workout, label: "supplemental") { sampleSuccess, sampleError in
                    if sampleSuccess {
                        print("✅ Direct save supplemental samples associated")
                    } else {
                        print("⚠️ Direct save supplemental sample association failed: \(sampleError?.localizedDescription ?? "Unknown")")
                    }
                    continueWithRoute(sampleSuccess, sampleError)
                }
            } else {
                let finalError = error ?? NSError(
                    domain: "HealthKit",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Direct save failed with nil error"]
                )
                completion(false, finalError, nil)
            }
        }
    }

    private func resetHealthStoreForRecovery() {
        print("🏥 HealthKit connection reset for retry")
        healthStore = HKHealthStore()
    }

    func saveWorkout(
        flight: Flight,
        locations: [FlightLocation],
        metrics: FlightMetrics,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        saveWorkout(flight: flight, locations: locations, metrics: metrics) { success, error, _ in
            completion(success, error)
        }
    }

    func fetchEnergyStats(
        startDate: Date,
        endDate: Date,
        completion: @escaping (_ activeEnergy: Double?, _ basalEnergy: Double?) -> Void
    ) {
        let activeType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
        let basalType = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned)!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        let group = DispatchGroup()
        var active: Double?
        var basal: Double?

        group.enter()
        let activeQuery = HKStatisticsQuery(quantityType: activeType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, _ in
            if let quantity = result?.sumQuantity() {
                active = quantity.doubleValue(for: .kilocalorie())
            }
            group.leave()
        }
        healthStore.execute(activeQuery)

        group.enter()
        let basalQuery = HKStatisticsQuery(quantityType: basalType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, _ in
            if let quantity = result?.sumQuantity() {
                basal = quantity.doubleValue(for: .kilocalorie())
            }
            group.leave()
        }
        healthStore.execute(basalQuery)

        group.notify(queue: .main) {
            completion(active, basal)
        }
    }

    private func exportActivityType(_ activityType: HKWorkoutActivityType) -> HKWorkoutActivityType {
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
            return activityType == .other ? .walking : activityType
        }
    }

    private func shouldSaveRoute(for locations: [FlightLocation]) -> Bool {
        var validRoutePointCount = 0

        for location in locations where location.isValid {
            let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
            if isCoordinateValid(coordinate) {
                validRoutePointCount += 1
                if validRoutePointCount >= 2 {
                    return true
                }
            }
        }

        return false
    }

    // Public method to save route to an existing workout
    func saveRoute(
        for workout: HKWorkout,
        locations: [FlightLocation],
        completion: @escaping (Bool, Error?) -> Void
    ) {
        print("🗺️ Saving workout route...")
        print("   Total locations received: \(locations.count)")

        let startBound = workout.startDate.addingTimeInterval(-5)
        let endBound = workout.endDate.addingTimeInterval(5)
        let filteredFlightLocations = locations.filter { location in
            location.isValid &&
            location.timestamp >= startBound &&
            location.timestamp <= endBound
        }

        // Convert FlightLocations to CLLocations and drop invalid points
        let clLocations = filteredFlightLocations.map { $0.toCLLocation() }
        let filteredLocations = clLocations.filter { location in
            isCoordinateValid(location.coordinate) && location.horizontalAccuracy >= 0
        }
        let sortedLocations = filteredLocations.sorted { $0.timestamp < $1.timestamp }

        // MEMORY OPTIMIZATION: Process in batches to manage memory efficiently
        // GPS updates at ~1 Hz (1 point per second) - iOS CoreLocation standard
        guard sortedLocations.count >= 2 else {
            print("❌ Not enough valid locations for route (need at least 2, got \(sortedLocations.count))")
            completion(false, NSError(domain: "HealthKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough locations for route"]))
            return
        }

        // Create route builder
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())

        // Insert route data in batches with memory management
        let batchSize = 50  // Reduced from 100 to 50 for better reliability with long workouts
        var currentIndex = 0

        func insertNextBatch() {
            let endIndex = min(currentIndex + batchSize, sortedLocations.count)

            // Convert batch to CLLocations within autoreleasepool to free memory after each batch
            var batchCLLocations: [CLLocation] = []
            autoreleasepool {
                batchCLLocations = Array(sortedLocations[currentIndex..<endIndex])
            }

            print("   Inserting batch \(currentIndex/batchSize + 1): locations \(currentIndex+1) to \(endIndex)")

            routeBuilder.insertRouteData(batchCLLocations) { success, error in
                if success {
                    currentIndex = endIndex
                    if currentIndex < sortedLocations.count {
                        // Insert next batch
                        insertNextBatch()
                    } else {
                        // All batches inserted, finish the route
                        print("   All \(sortedLocations.count) locations inserted, finishing route...")
                        routeBuilder.finishRoute(with: workout, metadata: nil) { route, error in
                            if let route = route {
                                print("✅ Route saved successfully to HealthKit!")
                                print("   Route UUID: \(route.uuid)")
                                print("   Associated with workout: \(workout.uuid)")
                                print("   Total points saved: \(sortedLocations.count)")
                                print("   📱 Route will appear in Fitness app for this workout")
                                print("   📍 Open Fitness app → Show All Data → Workouts → Select this workout to see route map")
                                completion(true, nil)
                            } else {
                                print("❌ Failed to finish route: \(error?.localizedDescription ?? "Unknown")")
                                completion(false, error)
                            }
                        }
                    }
                } else {
                    print("❌ Failed to insert route batch: \(error?.localizedDescription ?? "Unknown")")
                    completion(false, error)
                }
            }
        }

        // Start inserting batches
        insertNextBatch()
    }

    private func isCoordinateValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        return lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
    }

    func fetchWorkouts(completion: @escaping ([HKWorkout]?, Error?) -> Void) {
        fetchWorkouts(limit: HKObjectQueryNoLimit, beforeDate: nil, completion: completion)
    }

    func fetchWorkout(uuid: UUID, completion: @escaping (HKWorkout?, Error?) -> Void) {
        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForObject(with: uuid)
        let query = HKSampleQuery(
            sampleType: workoutType,
            predicate: predicate,
            limit: 1,
            sortDescriptors: nil
        ) { _, results, error in
            let workout = results?.first as? HKWorkout
            completion(workout, error)
        }
        healthStore.execute(query)
    }

    func syncWorkoutsWithAnchor(completion: @escaping ([HKWorkout], [UUID], HKQueryAnchor?) -> Void) {
        let workoutType = HKObjectType.workoutType()
        let anchor = WorkoutCacheStore.shared.loadAnchor()

        let query = HKAnchoredObjectQuery(
            type: workoutType,
            predicate: nil,
            anchor: anchor,
            limit: HKObjectQueryNoLimit
        ) { _, samples, deletedObjects, newAnchor, error in
            if let error = error {
                print("❌ Anchored workout sync failed: \(error.localizedDescription)")
            }
            let workouts = samples as? [HKWorkout] ?? []
            let deletedUUIDs = deletedObjects?.map { $0.uuid } ?? []
            if let newAnchor = newAnchor {
                WorkoutCacheStore.shared.saveAnchor(newAnchor)
            }
            completion(workouts, deletedUUIDs, newAnchor)
        }

        healthStore.execute(query)
    }

    func fetchWorkouts(limit: Int = HKObjectQueryNoLimit, beforeDate: Date? = nil, completion: @escaping ([HKWorkout]?, Error?) -> Void) {
        let workoutType = HKObjectType.workoutType()
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let predicate: NSPredicate?
        if let beforeDate = beforeDate {
            predicate = HKQuery.predicateForSamples(withStart: nil, end: beforeDate, options: .strictEndDate)
        } else {
            predicate = nil
        }

        let query = HKSampleQuery(
            sampleType: workoutType,
            predicate: predicate,
            limit: limit, // Use provided limit to prevent loading too many workouts
            sortDescriptors: [sortDescriptor]
        ) { _, results, error in
            guard let workouts = results as? [HKWorkout] else {
                completion(nil, error)
                return
            }

            let beforeText = beforeDate == nil ? "latest" : "before \(beforeDate!)"
            print("📊 Fetched \(workouts.count) workouts from HealthKit (\(beforeText), limit: \(limit == HKObjectQueryNoLimit ? "none" : "\(limit)"))")
            completion(workouts, nil)
        }

        healthStore.execute(query)
    }

    func deleteWorkout(_ workout: HKWorkout, completion: @escaping (Bool, Error?) -> Void) {
        healthStore.delete(workout) { success, error in
            completion(success, error)
        }
    }

    // MARK: - Add Workout Samples (Speed + Running Dynamics)

    func addWorkoutSamples(
        to builder: HKWorkoutBuilder,
        metrics: FlightMetrics,
        activityType: HKWorkoutActivityType,
        locations: [FlightLocation],
        startDate: Date,
        endDate: Date,
        includeDistanceSamples: Bool = true,
        completion: @escaping () -> Void
    ) {
        let speedSamples = buildSpeedSamples(metrics: metrics, activityType: activityType)
        let advancedSamples = buildAdvancedMetricSamples(metrics: metrics, activityType: activityType, locations: locations)
        let energySamples = buildActiveEnergySamples(metrics: metrics, startDate: startDate, endDate: endDate)
        let basalSamples = buildBasalEnergySamples(metrics: metrics, startDate: startDate, endDate: endDate)
        let distanceSamples = includeDistanceSamples
            ? buildDistanceSamples(metrics: metrics, activityType: activityType, startDate: startDate, endDate: endDate)
            : []
        let stepSamples = buildStepCountSamples(metrics: metrics, activityType: activityType, startDate: startDate, endDate: endDate)
        let heartRateSamples = buildHeartRateSamples(metrics: metrics, startDate: startDate, endDate: endDate)
        let allSamples = speedSamples + advancedSamples + energySamples + basalSamples + distanceSamples + stepSamples + heartRateSamples

        guard !allSamples.isEmpty else {
            completion()
            return
        }

        print("📊 Adding \(speedSamples.count) speed, \(advancedSamples.count) advanced, \(energySamples.count) active energy, \(basalSamples.count) resting energy, \(distanceSamples.count) distance, \(stepSamples.count) step, \(heartRateSamples.count) heart rate samples")

        // Add samples in batches for better reliability with long workouts
        let batchSize = 50
        var currentIndex = 0

        func addNextBatch() {
            let endIndex = min(currentIndex + batchSize, allSamples.count)
            let batch = Array(allSamples[currentIndex..<endIndex])

            let batchNumber = currentIndex/batchSize + 1
            let totalBatches = (allSamples.count + batchSize - 1) / batchSize

            if totalBatches > 1 {
                print("   Adding sample batch \(batchNumber)/\(totalBatches): samples \(currentIndex+1) to \(endIndex)")
            }

            builder.add(batch) { success, error in
                if success {
                    currentIndex = endIndex
                    if currentIndex < allSamples.count {
                        // Add next batch
                        addNextBatch()
                    } else {
                        // All batches added
                        print("✅ All workout samples added successfully - enhanced Fitness app display")
                        completion()
                    }
                } else {
                    print("⚠️ Failed to add workout sample batch \(batchNumber): \(error?.localizedDescription ?? "Unknown")")
                    // Continue anyway - don't fail the entire workout
                    completion()
                }
            }
        }

        addNextBatch()
    }

    private func buildSpeedSamples(metrics: FlightMetrics, activityType: HKWorkoutActivityType) -> [HKQuantitySample] {
        let speedTypeIdentifier: HKQuantityTypeIdentifier
        switch activityType {
        case .running, .walking, .hiking:
            speedTypeIdentifier = .runningSpeed
        case .cycling:
            speedTypeIdentifier = .cyclingSpeed
        default:
            speedTypeIdentifier = .cyclingSpeed
        }

        guard let speedType = HKQuantityType.quantityType(forIdentifier: speedTypeIdentifier) else {
            print("⚠️ Speed type not available")
            return []
        }

        let samplingInterval = max(1, metrics.speedHistory.count / 100) // Max 100 samples
        var speedSamples: [HKQuantitySample] = []

        for (index, speedSample) in metrics.speedHistory.enumerated() where index % samplingInterval == 0 {
            let speedQuantity = HKQuantitySafe(unit: HKUnit.meter().unitDivided(by: .second()), doubleValue: speedSample.speed)

            let sample = HKQuantitySample(
                type: speedType,
                quantity: speedQuantity,
                start: speedSample.timestamp,
                end: speedSample.timestamp.addingTimeInterval(1.0)
            )

            speedSamples.append(sample)
        }

        return speedSamples
    }

    private func buildAdvancedMetricSamples(
        metrics: FlightMetrics,
        activityType: HKWorkoutActivityType,
        locations: [FlightLocation]
    ) -> [HKQuantitySample] {
        var allSamples: [HKQuantitySample] = []
        let samplingInterval = max(1, metrics.speedHistory.count / 100)

        if let cadenceSamples = calculateCadenceSamples(
            metrics: metrics,
            activityType: activityType,
            samplingInterval: samplingInterval
        ) {
            allSamples.append(contentsOf: cadenceSamples)
        }

        if activityType == .running || activityType == .walking || activityType == .hiking {
            if let strideSamples = calculateStrideLengthSamples(
                metrics: metrics,
                activityType: activityType,
                samplingInterval: samplingInterval
            ) {
                allSamples.append(contentsOf: strideSamples)
            }

            if let powerSamples = calculateRunningPowerSamples(
                metrics: metrics,
                locations: locations,
                samplingInterval: samplingInterval
            ) {
                allSamples.append(contentsOf: powerSamples)
            }

            if let vertOscSamples = calculateVerticalOscillationSamples(
                metrics: metrics,
                locations: locations,
                samplingInterval: samplingInterval
            ) {
                allSamples.append(contentsOf: vertOscSamples)
            }

            if let gctSamples = calculateGroundContactTimeSamples(metrics: metrics, samplingInterval: samplingInterval) {
                allSamples.append(contentsOf: gctSamples)
            }
        }

        return allSamples
    }

    private func buildStepCountSamples(
        metrics: FlightMetrics,
        activityType: HKWorkoutActivityType,
        startDate: Date,
        endDate: Date
    ) -> [HKQuantitySample] {
        var samples: [HKQuantitySample] = []

        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return samples
        }

        let nativeSteps = (metrics.stepsCount ?? 0) > 0 ? (metrics.stepsCount ?? 0) : 0
        let isStepBasedActivity = (activityType == .walking || activityType == .running || activityType == .hiking)
        var stepSources: [(count: Double, source: String)] = []

        if nativeSteps > 0 {
            print("📱 👟 Using native pedometer steps: \(String(format: "%.0f", nativeSteps))")
            stepSources.append((nativeSteps, "pedometer-native"))
        }

        if isStepBasedActivity && metrics.totalDistance > 0 {
            let strideLength: Double = activityType == .running ? 1.2 : 0.75
            let estimatedSteps = metrics.totalDistance / strideLength
            print("📱 👟 Using GPS-estimated steps: \(String(format: "%.0f", estimatedSteps)) (distance \(String(format: "%.2f", metrics.totalDistance/1000))km)")
            if nativeSteps > 0 {
                let ratio = nativeSteps > 0 ? (estimatedSteps / nativeSteps) : 0
                print("📱 👟 Native vs GPS-estimated step ratio: \(String(format: "%.2f", ratio))x")
            }
            stepSources.append((estimatedSteps, "gps-estimated"))
        } else if stepSources.isEmpty {
            print("📱 👟 No step channels available for activity \(activityType.rawValue) - skipping step sample")
        }

        for stepSource in stepSources where stepSource.count > 0 {
            let distributedSamples = buildDistributedStepSamples(
                stepType: stepType,
                totalSteps: stepSource.count,
                startDate: startDate,
                endDate: endDate
            )
            if distributedSamples.isEmpty {
                let stepSample = HKQuantitySample(
                    type: stepType,
                    quantity: HKQuantitySafe(unit: .count(), doubleValue: stepSource.count),
                    start: startDate,
                    end: endDate
                )
                samples.append(stepSample)
            } else {
                samples.append(contentsOf: distributedSamples)
                print("📱 👟 Step Count distributed into \(distributedSamples.count) samples (\(stepSource.source))")
            }
            print("📱 👟 Step Count: \(String(format: "%.0f", stepSource.count)) steps (\(stepSource.source))")
        }

        return samples
    }

    private func buildDistributedStepSamples(
        stepType: HKQuantityType,
        totalSteps: Double,
        startDate: Date,
        endDate: Date
    ) -> [HKQuantitySample] {
        let duration = endDate.timeIntervalSince(startDate)
        guard duration > 0, totalSteps > 0 else { return [] }

        let bucketCount = max(1, min(240, Int(duration / 60.0)))
        guard bucketCount > 1 else { return [] }

        let bucketDuration = duration / Double(bucketCount)
        var remaining = totalSteps
        var samples: [HKQuantitySample] = []

        for i in 0..<bucketCount {
            let bucketStart = startDate.addingTimeInterval(Double(i) * bucketDuration)
            let bucketEnd = (i == bucketCount - 1)
                ? endDate
                : startDate.addingTimeInterval(Double(i + 1) * bucketDuration)
            let stepsForBucket: Double
            if i == bucketCount - 1 {
                stepsForBucket = max(0, remaining)
            } else {
                let evenShare = totalSteps / Double(bucketCount)
                stepsForBucket = max(0, evenShare)
                remaining -= stepsForBucket
            }

            guard stepsForBucket > 0, bucketEnd > bucketStart else { continue }
            samples.append(
                HKQuantitySample(
                    type: stepType,
                    quantity: HKQuantitySafe(unit: .count(), doubleValue: stepsForBucket),
                    start: bucketStart,
                    end: bucketEnd
                )
            )
        }

        return samples
    }

    private func buildActiveEnergySamples(metrics: FlightMetrics, startDate: Date, endDate: Date) -> [HKQuantitySample] {
        guard metrics.caloriesBurned > 0,
              let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
            return []
        }

        let energyQuantity = HKQuantitySafe(unit: .kilocalorie(), doubleValue: metrics.caloriesBurned)
        let sample = HKQuantitySample(type: energyType, quantity: energyQuantity, start: startDate, end: endDate)
        return [sample]
    }

    private func buildBasalEnergySamples(metrics: FlightMetrics, startDate: Date, endDate: Date) -> [HKQuantitySample] {
        guard metrics.restingEnergyBurned > 0,
              let energyType = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned) else {
            return []
        }

        let energyQuantity = HKQuantitySafe(unit: .kilocalorie(), doubleValue: metrics.restingEnergyBurned)
        let sample = HKQuantitySample(type: energyType, quantity: energyQuantity, start: startDate, end: endDate)
        return [sample]
    }

    private func buildDistanceSamples(
        metrics: FlightMetrics,
        activityType: HKWorkoutActivityType,
        startDate: Date,
        endDate: Date
    ) -> [HKQuantitySample] {
        guard metrics.totalDistance > 0 else { return [] }

        var identifiers: [HKQuantityTypeIdentifier]
        switch activityType {
        case .cycling:
            // Keep cycling distance, and mirror to walking/running so Health totals track user movement.
            identifiers = [.distanceCycling, .distanceWalkingRunning]
        case .running, .walking, .hiking:
            // Redundant write for walking/running to improve Health aggregation reliability.
            identifiers = [.distanceWalkingRunning, .distanceCycling]
        default:
            identifiers = [.distanceWalkingRunning]
        }

        var sourceDistances: [(label: String, value: Double)] = [("gps", metrics.totalDistance)]
        if let nativeStepDistance = metrics.nativeStepDistance, nativeStepDistance > 0 {
            sourceDistances.append(("nativeStep", nativeStepDistance))
        }

        var samples: [HKQuantitySample] = []
        for source in sourceDistances {
            let distanceQuantity = HKQuantitySafe(unit: .meter(), doubleValue: source.value)
            for identifier in identifiers {
                guard let distanceType = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
                let sample = HKQuantitySample(
                    type: distanceType,
                    quantity: distanceQuantity,
                    start: startDate,
                    end: endDate
                )
                samples.append(sample)
            }
        }

        return samples
    }

    private func buildDirectSaveSupplementalSamples(
        metrics: FlightMetrics,
        activityType: HKWorkoutActivityType,
        startDate: Date,
        endDate: Date
    ) -> [HKQuantitySample] {
        let distanceSamples = buildDistanceSamples(
            metrics: metrics,
            activityType: activityType,
            startDate: startDate,
            endDate: endDate
        )
        let energySamples = buildActiveEnergySamples(metrics: metrics, startDate: startDate, endDate: endDate)
        let basalSamples = buildBasalEnergySamples(metrics: metrics, startDate: startDate, endDate: endDate)
        let stepSamples = buildStepCountSamples(
            metrics: metrics,
            activityType: activityType,
            startDate: startDate,
            endDate: endDate
        )
        return distanceSamples + energySamples + basalSamples + stepSamples
    }

    private func buildHeartRateSamples(metrics: FlightMetrics, startDate: Date, endDate: Date) -> [HKQuantitySample] {
        let heartRateValue = metrics.averageHeartRate ?? metrics.currentHeartRate
        guard let heartRateValue,
              let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return []
        }

        let quantity = HKQuantitySafe(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: heartRateValue)
        let sample = HKQuantitySample(type: heartRateType, quantity: quantity, start: startDate, end: endDate)
        return [sample]
    }

    // MARK: - Metric Calculations

    private func calculateCadenceSamples(metrics: FlightMetrics, activityType: HKWorkoutActivityType, samplingInterval: Int) -> [HKQuantitySample]? {
        var samples: [HKQuantitySample] = []

        switch activityType {
        case .running, .walking, .hiking:
            // No running cadence type available in this SDK; avoid invalid stepCount samples.
            return nil

        case .cycling:
            // Cycling cadence (RPM)
            guard let cadenceType = HKQuantityType.quantityType(forIdentifier: .cyclingCadence) else { return nil }

            for (index, speedSample) in metrics.speedHistory.enumerated() where index % samplingInterval == 0 {
                // Estimate cycling cadence from speed
                // Average: 60-90 RPM
                let cadence = estimateCyclingCadence(speed: speedSample.speed)

                let quantity = HKQuantitySafe(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: cadence)
                let sample = HKQuantitySample(
                    type: cadenceType,
                    quantity: quantity,
                    start: speedSample.timestamp,
                    end: speedSample.timestamp.addingTimeInterval(60.0)
                )
                samples.append(sample)
            }

        default:
            return nil
        }

        return samples.isEmpty ? nil : samples
    }

    private func calculateStrideLengthSamples(
        metrics: FlightMetrics,
        activityType: HKWorkoutActivityType,
        samplingInterval: Int
    ) -> [HKQuantitySample]? {
        let identifier: HKQuantityTypeIdentifier = {
            switch activityType {
            case .walking, .hiking:
                return .walkingStepLength
            default:
                return .runningStrideLength
            }
        }()
        guard let strideType = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }

        var samples: [HKQuantitySample] = []

        for (index, speedSample) in metrics.speedHistory.enumerated() where index % samplingInterval == 0 {
            // Calculate stride length from speed
            let strideLength = calculateStrideLength(speed: speedSample.speed)

            let quantity = HKQuantitySafe(unit: .meter(), doubleValue: strideLength)
            let sample = HKQuantitySample(
                type: strideType,
                quantity: quantity,
                start: speedSample.timestamp,
                end: speedSample.timestamp.addingTimeInterval(1.0)
            )
            samples.append(sample)
        }

        if !samples.isEmpty {
            print("📱 👟 Added \(samples.count) stride samples using \(identifier == .walkingStepLength ? "walkingStepLength" : "runningStrideLength")")
        }
        return samples.isEmpty ? nil : samples
    }

    private func calculateRunningPowerSamples(metrics: FlightMetrics, locations: [FlightLocation], samplingInterval: Int) -> [HKQuantitySample]? {
        guard let powerType = HKQuantityType.quantityType(forIdentifier: .runningPower) else { return nil }

        var samples: [HKQuantitySample] = []

        for (index, speedSample) in metrics.speedHistory.enumerated() where index % samplingInterval == 0 {
            // Get corresponding altitude if available
            let altitude = index < locations.count ? locations[index].altitude : 0.0

            // Estimate running power (watts)
            let power = estimateRunningPower(speed: speedSample.speed, altitude: altitude)

            let quantity = HKQuantitySafe(unit: .watt(), doubleValue: power)
            let sample = HKQuantitySample(
                type: powerType,
                quantity: quantity,
                start: speedSample.timestamp,
                end: speedSample.timestamp.addingTimeInterval(1.0)
            )
            samples.append(sample)
        }

        return samples.isEmpty ? nil : samples
    }

    private func calculateVerticalOscillationSamples(metrics: FlightMetrics, locations: [FlightLocation], samplingInterval: Int) -> [HKQuantitySample]? {
        guard let vertOscType = HKQuantityType.quantityType(forIdentifier: .runningVerticalOscillation) else { return nil }

        var samples: [HKQuantitySample] = []

        for (index, speedSample) in metrics.speedHistory.enumerated() where index % samplingInterval == 0 {
            // Estimate vertical oscillation from speed
            // Typical: 6-13 cm, increases with speed
            let vertOsc = estimateVerticalOscillation(speed: speedSample.speed)

            let quantity = HKQuantitySafe(unit: HKUnit.meterUnit(with: .centi), doubleValue: vertOsc)
            let sample = HKQuantitySample(
                type: vertOscType,
                quantity: quantity,
                start: speedSample.timestamp,
                end: speedSample.timestamp.addingTimeInterval(1.0)
            )
            samples.append(sample)
        }

        return samples.isEmpty ? nil : samples
    }

    private func calculateGroundContactTimeSamples(metrics: FlightMetrics, samplingInterval: Int) -> [HKQuantitySample]? {
        guard let gctType = HKQuantityType.quantityType(forIdentifier: .runningGroundContactTime) else { return nil }

        var samples: [HKQuantitySample] = []

        for (index, speedSample) in metrics.speedHistory.enumerated() where index % samplingInterval == 0 {
            // Estimate ground contact time from speed
            // Typical: 200-300ms, decreases with speed
            let gct = estimateGroundContactTime(speed: speedSample.speed)

            let quantity = HKQuantitySafe(unit: HKUnit.secondUnit(with: .milli), doubleValue: gct)
            let sample = HKQuantitySample(
                type: gctType,
                quantity: quantity,
                start: speedSample.timestamp,
                end: speedSample.timestamp.addingTimeInterval(1.0)
            )
            samples.append(sample)
        }

        return samples.isEmpty ? nil : samples
    }

    // MARK: - Estimation Algorithms

    private func estimateStepCadence(speed: Double, activityType: HKWorkoutActivityType) -> Double {
        // speed in m/s
        let speedKmh = speed * 3.6

        switch activityType {
        case .running:
            // Running: 160-180 spm at moderate pace, increases slightly with speed
            if speedKmh < 6.0 {
                return 150.0 // Slow jog
            } else if speedKmh < 10.0 {
                return 160.0 + (speedKmh - 6.0) * 2.5 // 160-170 spm
            } else if speedKmh < 15.0 {
                return 170.0 + (speedKmh - 10.0) * 2.0 // 170-180 spm
            } else {
                return 180.0 // Fast running
            }

        case .walking, .hiking:
            // Walking: 100-120 spm
            if speedKmh < 3.0 {
                return 100.0
            } else if speedKmh < 5.0 {
                return 100.0 + (speedKmh - 3.0) * 10.0 // 100-120 spm
            } else {
                return 120.0
            }

        default:
            return 160.0
        }
    }

    private func estimateCyclingCadence(speed: Double) -> Double {
        // speed in m/s
        let speedKmh = speed * 3.6

        // Cycling cadence: typically 60-90 RPM
        if speedKmh < 15.0 {
            return 60.0 // Slow cycling
        } else if speedKmh < 25.0 {
            return 60.0 + (speedKmh - 15.0) * 2.0 // 60-80 RPM
        } else if speedKmh < 35.0 {
            return 80.0 + (speedKmh - 25.0) * 1.0 // 80-90 RPM
        } else {
            return 90.0 // Fast cycling
        }
    }

    private func calculateStrideLength(speed: Double) -> Double {
        // Stride length (m) = speed (m/s) / (cadence (steps/min) / 60)
        // Simplified: assume 160 spm average
        let assumedCadence = 160.0 / 60.0 // steps per second

        if speed < 0.1 {
            return 0.0
        }

        let strideLength = speed / assumedCadence
        return max(0.5, min(2.5, strideLength)) // Clamp to realistic range: 0.5-2.5m
    }

    private func estimateRunningPower(speed: Double, altitude: Double) -> Double {
        // Simplified running power estimation
        // Power (watts) ≈ mass * gravity * vertical_speed + mass * speed^3 / efficiency
        // Assumptions: 70kg runner, 25% efficiency

        let mass = 70.0 // kg
        let gravity = 9.81 // m/s²
        let efficiency = 0.25

        // Horizontal power component
        let horizontalPower = mass * pow(speed, 2.0) / efficiency

        // Vertical power component (if climbing)
        let verticalSpeed = 0.0 // Can't accurately estimate without continuous altitude data
        let verticalPower = mass * gravity * verticalSpeed

        let totalPower = horizontalPower + verticalPower

        return max(0.0, min(500.0, totalPower)) // Clamp to realistic range: 0-500W
    }

    private func estimateVerticalOscillation(speed: Double) -> Double {
        // Vertical oscillation in cm
        // Increases with speed, typical range: 6-13 cm
        let speedKmh = speed * 3.6

        if speedKmh < 6.0 {
            return 7.0 // Slow jog
        } else if speedKmh < 12.0 {
            return 7.0 + (speedKmh - 6.0) * 0.5 // 7-10 cm
        } else if speedKmh < 18.0 {
            return 10.0 + (speedKmh - 12.0) * 0.5 // 10-13 cm
        } else {
            return 13.0 // Fast running
        }
    }

    private func estimateGroundContactTime(speed: Double) -> Double {
        // Ground contact time in milliseconds
        // Decreases with speed, typical range: 150-300ms
        let speedKmh = speed * 3.6

        if speedKmh < 6.0 {
            return 280.0 // Slow jog
        } else if speedKmh < 10.0 {
            return 280.0 - (speedKmh - 6.0) * 15.0 // 280-220 ms
        } else if speedKmh < 15.0 {
            return 220.0 - (speedKmh - 10.0) * 10.0 // 220-170 ms
        } else {
            return 170.0 // Fast running
        }
    }

    func fetchRoute(for workout: HKWorkout, completion: @escaping ([FlightLocation]?, Error?) -> Void) {
        print("🗺️ Fetching route for workout: \(workout.uuid)")

        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)

        let query = HKSampleQuery(
            sampleType: routeType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { _, results, error in
            guard let routes = results as? [HKWorkoutRoute], let route = routes.first else {
                print("⚠️ No route found for workout")
                completion(nil, error)
                return
            }

            print("✅ Found route, fetching location data...")

            var allLocations: [CLLocation] = []
            let routeQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let locations = locations {
                    allLocations.append(contentsOf: locations)
                }

                if done {
                    if allLocations.isEmpty {
                        print("⚠️ Route has no location data")
                        completion(nil, NSError(domain: "HealthKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "Route has no locations"]))
                    } else {
                        print("✅ Loaded \(allLocations.count) locations from route")

                        // Convert CLLocations to FlightLocations
                        let flightLocations = allLocations.map { location in
                            FlightLocation(from: location, isFiltered: false, isValid: true)
                        }

                        completion(flightLocations, nil)
                    }
                }
            }

            self.healthStore.execute(routeQuery)
        }

        healthStore.execute(query)
    }

    /// What HealthKit actually kept, read back from HealthKit itself.
    ///
    /// The app's own record and the copy the Fitness app draws are two different things, and
    /// until now only the first was inspectable — so a route this app displays correctly while
    /// Fitness draws it as one long straight line could only be argued about, never checked.
    /// Reports how many route series are attached (more than one is itself a bug), how many
    /// points survived, and the largest step between consecutive points: a walk whose real
    /// steps are 1–3 m apart cannot legitimately contain a 500 m one.
    func routeDiagnostics(for workoutUUID: UUID,
                          completion: @escaping (_ routes: Int, _ points: Int, _ maxGap: Double) -> Void) {
        fetchWorkout(uuid: workoutUUID) { [weak self] workout, _ in
            guard let self, let workout else {
                completion(0, 0, 0)
                return
            }
            let routeType = HKSeriesType.workoutRoute()
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(sampleType: routeType, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                let routes = (results as? [HKWorkoutRoute]) ?? []
                guard !routes.isEmpty else {
                    completion(0, 0, 0)
                    return
                }
                // EVERY SERIES, NOT JUST THE FIRST.
                //
                // Reading only routes.first reported "no gap" while the Fitness map drew a
                // dotted line — Apple's own way of saying two parts of a route do not join —
                // with polyline visible at BOTH ends. A second series attached to the same
                // workout would produce exactly that and be invisible to a diagnostic that
                // stops at the first one. Merging them by time is also how Fitness draws them,
                // so the largest gap reported is the one actually rendered.
                var all: [CLLocation] = []
                var pending = routes.count
                for route in routes {
                    let routeQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, _ in
                        if let locations { all.append(contentsOf: locations) }
                        guard done else { return }
                        pending -= 1
                        guard pending == 0 else { return }
                        let sorted = all.sorted { $0.timestamp < $1.timestamp }
                        var maxGap: Double = 0
                        for i in 1..<max(sorted.count, 1) {
                            maxGap = max(maxGap, sorted[i].distance(from: sorted[i - 1]))
                        }
                        completion(routes.count, sorted.count, maxGap)
                    }
                    self.healthStore.execute(routeQuery)
                }
            }
            self.healthStore.execute(query)
        }
    }

    // Check if a workout with the given UUID still exists in HealthKit
    func workoutExists(uuid: UUID, completion: @escaping (Bool) -> Void) {
        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForObject(with: uuid)

        let query = HKSampleQuery(
            sampleType: workoutType,
            predicate: predicate,
            limit: 1,
            sortDescriptors: nil
        ) { _, results, error in
            if let error = error {
                print("❌ Error checking workout existence: \(error.localizedDescription)")
                completion(false)
                return
            }

            let exists = results?.first != nil
            completion(exists)
        }

        healthStore.execute(query)
    }

    // Check multiple workouts at once for efficiency
    func checkWorkoutsExist(uuids: [UUID], completion: @escaping ([UUID: Bool]) -> Void) {
        guard !uuids.isEmpty else {
            completion([:])
            return
        }

        var results: [UUID: Bool] = [:]
        let group = DispatchGroup()

        for uuid in uuids {
            group.enter()
            workoutExists(uuid: uuid) { exists in
                results[uuid] = exists
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(results)
        }
    }

    // MARK: - Resync to HealthKit

    /// Calculate total distance from GPS location array
    /// Used to fix corrupted distance data by recalculating from raw GPS points
    private func calculateTotalDistance(from locations: [FlightLocation]) -> Double {
        guard locations.count > 1 else { return 0 }

        var totalDistance: Double = 0
        for i in 1..<locations.count {
            let currentLocation = locations[i]
            let previousLocation = locations[i - 1]

            // Only count valid GPS points
            guard currentLocation.isValid && previousLocation.isValid else {
                continue
            }

            // Calculate distance between consecutive points
            let distance = currentLocation.distance(to: previousLocation)

            // Sanity check: ignore impossible jumps (GPS glitches)
            if distance < 1000.0 { // Less than 1km jump (reasonable for 1Hz GPS)
                totalDistance += distance
            } else {
                print("      ⚠️ Skipping GPS glitch: \(String(format: "%.0f", distance))m jump")
            }
        }

        return totalDistance
    }

    /// Resend flight data to HealthKit with correct distance
    /// Deletes old workout and creates new one with accurate data
    /// CRITICAL: Recalculates distance from GPS locations to fix corruption
    func resyncFlightToHealthKit(
        flight: Flight,
        locations: [FlightLocation],
        metrics: FlightMetrics,
        completion: @escaping (Bool, Error?, HKWorkout?) -> Void
    ) {
        guard isAuthorized else {
            let error = NSError(domain: "HealthKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "HealthKit not authorized"])
            completion(false, error, nil)
            return
        }

        print("🔄 Resyncing flight to HealthKit...")
        print("   Flight ID: \(flight.id)")
        print("   Date: \(flight.startDate)")
        print("   Stored Distance: \(String(format: "%.2f", metrics.totalDistance/1000))km")
        print("   Locations: \(locations.count)")

        // 🔥 CRITICAL FIX: Recalculate distance from actual GPS locations
        // This fixes the 17km → 50km corruption issue
        var correctedMetrics = metrics
        if locations.count > 1 {
            let recalculatedDistance = calculateTotalDistance(from: locations)
            if abs(recalculatedDistance - metrics.totalDistance) > 100.0 { // More than 100m difference
                print("   ⚠️ DISTANCE CORRUPTION DETECTED!")
                print("   📊 Stored: \(String(format: "%.2f", metrics.totalDistance/1000))km")
                print("   📊 Recalculated from GPS: \(String(format: "%.2f", recalculatedDistance/1000))km")
                print("   🔧 Using recalculated distance for HealthKit")
                correctedMetrics.totalDistance = recalculatedDistance

                // Recalculate average speed with correct distance
                if correctedMetrics.duration > 0 {
                    correctedMetrics.averageSpeed = recalculatedDistance / correctedMetrics.duration
                }

                // Recalculate steps with correct distance
                if correctedMetrics.stepsCount == nil || correctedMetrics.stepsCount == 0 {
                    // Re-estimate steps from corrected distance
                    let activityType = flight.workoutType.flatMap { HKWorkoutActivityType(rawValue: $0) } ?? .walking
                    if activityType == .running || activityType == .walking || activityType == .hiking {
                        let strideLength: Double = activityType == .running ? 1.2 : 0.75
                        correctedMetrics.stepsCount = recalculatedDistance / strideLength
                        print("   👟 Recalculated steps: \(String(format: "%.0f", correctedMetrics.stepsCount ?? 0))")
                    }
                }
            } else {
                print("   ✅ Distance verified: \(String(format: "%.2f", metrics.totalDistance/1000))km (no corruption)")
            }
        }

        print("   Final Distance to HealthKit: \(String(format: "%.2f", correctedMetrics.totalDistance/1000))km")

        // Step 1: Delete old workouts that overlap this time range to prevent duplicates
        let endDate = flight.endDate ?? flight.startDate.addingTimeInterval(max(correctedMetrics.duration, 0))
        deleteWorkoutsForResync(flight: flight, endDate: endDate) { [weak self] _ in
            guard let self = self else { return }

            // Step 2: Create new workout with CORRECTED data
            print("   💾 Creating new workout with corrected distance...")
            self.saveWorkout(flight: flight, locations: locations, metrics: correctedMetrics) { saveSuccess, error, workout in
                if saveSuccess {
                    print("   ✅ Flight resynced successfully to HealthKit!")
                } else {
                    print("   ❌ Failed to resync: \(error?.localizedDescription ?? "Unknown")")
                }
                completion(saveSuccess, error, workout)
            }
        }
    }

    func resyncFlightToHealthKit(
        flight: Flight,
        locations: [FlightLocation],
        metrics: FlightMetrics,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        resyncFlightToHealthKit(flight: flight, locations: locations, metrics: metrics) { success, error, _ in
            completion(success, error)
        }
    }

    /// Delete a workout from HealthKit
    private func deleteWorkout(uuid: UUID, completion: @escaping (Bool) -> Void) {
        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForObject(with: uuid)

        let query = HKSampleQuery(
            sampleType: workoutType,
            predicate: predicate,
            limit: 1,
            sortDescriptors: nil
        ) { [weak self] _, results, error in
            guard let self = self else {
                completion(false)
                return
            }

            if let error = error {
                print("❌ Error finding workout to delete: \(error.localizedDescription)")
                completion(false)
                return
            }

            guard let workout = results?.first else {
                print("⚠️ Workout not found in HealthKit (might already be deleted)")
                completion(true) // Not an error - workout doesn't exist
                return
            }

            // Delete the workout
            self.healthStore.delete(workout) { success, error in
                if let error = error {
                    print("❌ Error deleting workout: \(error.localizedDescription)")
                    completion(false)
                } else {
                    completion(success)
                }
            }
        }

        healthStore.execute(query)
    }

    private func deleteWorkoutsForResync(
        flight: Flight,
        endDate: Date,
        completion: @escaping (Bool) -> Void
    ) {
        let group = DispatchGroup()
        var overallSuccess = true

        if let workoutUUID = flight.workoutUUID {
            print("   🗑️ Deleting existing HealthKit workout: \(workoutUUID)")
            group.enter()
            deleteWorkout(uuid: workoutUUID) { success in
                overallSuccess = overallSuccess && success
                group.leave()
            }
        }

        let windowStart = flight.startDate.addingTimeInterval(-60)
        let windowEnd = endDate.addingTimeInterval(60)
        group.enter()
        deleteWorkoutsInTimeRange(startDate: windowStart, endDate: windowEnd, activityTypeRaw: flight.workoutType) { success in
            overallSuccess = overallSuccess && success
            group.leave()
        }

        group.notify(queue: .main) {
            completion(overallSuccess)
        }
    }

    private func deleteWorkoutsInTimeRange(
        startDate: Date,
        endDate: Date,
        activityTypeRaw: UInt?,
        completion: @escaping (Bool) -> Void
    ) {
        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [.strictStartDate, .strictEndDate])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let targetType = activityTypeRaw.flatMap { HKWorkoutActivityType(rawValue: $0) }

        let query = HKSampleQuery(
            sampleType: workoutType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sort]
        ) { [weak self] _, results, error in
            guard let self = self else {
                completion(false)
                return
            }

            if let error = error {
                print("❌ Error finding overlapping workouts: \(error.localizedDescription)")
                completion(false)
                return
            }

            guard let workouts = results as? [HKWorkout], !workouts.isEmpty else {
                completion(true)
                return
            }

            let filtered = workouts.filter { workout in
                guard let targetType = targetType else { return true }
                return workout.workoutActivityType == targetType
            }

            guard !filtered.isEmpty else {
                completion(true)
                return
            }

            print("   🗑️ Deleting \(filtered.count) overlapping workout(s) in time window")
            self.healthStore.delete(filtered) { success, deleteError in
                if let deleteError = deleteError {
                    print("❌ Failed to delete overlapping workouts: \(deleteError.localizedDescription)")
                }
                completion(success && deleteError == nil)
            }
        }

        healthStore.execute(query)
    }
}
