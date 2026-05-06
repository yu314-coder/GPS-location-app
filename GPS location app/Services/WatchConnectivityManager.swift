import Foundation
import WatchConnectivity
import Combine

struct FlightCheckpointPayload: Codable {
    let flightID: UUID
    let startDate: Date
    let endDate: Date?
    let locations: [FlightLocation]
    let locationStartIndex: Int
    let totalLocationCount: Int
    let metrics: FlightMetrics
    let effort: Int?
    let workoutType: UInt?
    let isFinal: Bool
}

struct FlightCheckpointEnvelope: Codable {
    let type: String
    let payload: Data
}

class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var isReachable = false
    @Published var isWatchAppInstalled = false
    @Published var receivedWorkoutData: WorkoutSyncData?

    private var session: WCSession?
    private let healthKitManager = HealthKitManager.shared

    // CarPlay access to last workout data
    var lastReceivedWorkoutData: WorkoutSyncData? {
        return receivedWorkoutData
    }

    // GPS Sharing with Watch
    @Published var isSharingGPS = false
    private var gpsSharingTimer: Timer?
    private let locationManager = LocationManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var isMirroringWatchLiveActivity = false
    private var isLocalWorkoutActive = false

    private override init() {
        super.init()
        setupWorkoutStateObservers()

        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }

    private func setupWorkoutStateObservers() {
        NotificationCenter.default.publisher(for: .workoutDidStart)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.isLocalWorkoutActive = true
                if self.isMirroringWatchLiveActivity {
                    self.endMirroredLiveActivity(finalDuration: 0, finalDistance: 0, finalCalories: 0)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workoutDidStop)
            .sink { [weak self] _ in
                self?.isLocalWorkoutActive = false
            }
            .store(in: &cancellables)
    }

    private func startMirroredLiveActivityIfNeeded() {
        guard !isLocalWorkoutActive else {
            print("📱 Live Activity mirror skipped (local iPhone workout active)")
            return
        }

        guard #available(iOS 16.1, *) else { return }
        guard WorkoutLiveActivityManager.isSupported else { return }
        guard !isMirroringWatchLiveActivity else { return }

        WorkoutLiveActivityManager.shared.startLiveActivity(workoutType: "Watch Workout")
        isMirroringWatchLiveActivity = true
        print("📱 🔴 Mirrored Live Activity started from watch workout")
    }

    private func updateMirroredLiveActivity(with data: WorkoutSyncData) {
        guard !isLocalWorkoutActive else { return }
        guard #available(iOS 16.1, *) else { return }
        guard WorkoutLiveActivityManager.isSupported else { return }

        if !isMirroringWatchLiveActivity {
            startMirroredLiveActivityIfNeeded()
        }

        let gpsDistance = data.gpsWorkoutDistance ?? data.distance
        WorkoutLiveActivityManager.shared.updateLiveActivity(
            duration: data.duration,
            distance: gpsDistance,
            speed: data.currentSpeed,
            calories: data.calories,
            altitude: data.currentAltitude,
            heartRate: data.heartRate,
            isPaused: false
        )
    }

    private func endMirroredLiveActivity(finalDuration: TimeInterval, finalDistance: Double, finalCalories: Double) {
        guard #available(iOS 16.1, *) else { return }
        guard isMirroringWatchLiveActivity else { return }
        guard !isLocalWorkoutActive else {
            isMirroringWatchLiveActivity = false
            print("📱 Live Activity mirror cleared (local iPhone workout active)")
            return
        }

        WorkoutLiveActivityManager.shared.endLiveActivity(
            finalDuration: finalDuration,
            finalDistance: finalDistance,
            finalCalories: finalCalories
        )
        isMirroringWatchLiveActivity = false
        print("📱 🔴 Mirrored Live Activity ended from watch workout")
    }

    // MARK: - Send Messages

    func startWorkoutOnWatch(workoutType: Int? = nil) {
        guard let session = session, session.isReachable else {
            print("⚠️ Watch not reachable")
            return
        }

        var message: [String: Any] = ["action": "startWorkout"]
        if let workoutType = workoutType {
            message["workoutType"] = workoutType
            print("📱 Sending workout start command with type: \(workoutType)")
        }

        session.sendMessage(message, replyHandler: { reply in
            print("✅ Watch started workout: \(reply)")
        }) { error in
            print("❌ Failed to start workout on watch: \(error.localizedDescription)")
        }
    }

    func stopWorkoutOnWatch() {
        guard let session = session, session.isReachable else {
            print("⚠️ Watch not reachable")
            return
        }

        let message = ["action": "stopWorkout"]
        session.sendMessage(message, replyHandler: { reply in
            print("✅ Watch stopped workout: \(reply)")
        }) { error in
            print("❌ Failed to stop workout on watch: \(error.localizedDescription)")
        }
    }

    func sendWorkoutUpdate(_ data: WorkoutSyncData) {
        guard let session = session else { return }

        do {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(data)

            if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                try session.updateApplicationContext(json)
                print("✅ Sent workout update to watch")
            }
        } catch {
            print("❌ Failed to send workout update: \(error.localizedDescription)")
        }
    }

    // MARK: - GPS Sharing

    func startGPSSharing() {
        guard !isSharingGPS else {
            print("📱 GPS sharing already active")
            return
        }

        print("📱 🛰️ Starting GPS sharing with watch")
        isSharingGPS = true

        // Start location tracking if not already active
        if !locationManager.isTracking {
            locationManager.startTracking()
        }
        locationManager.requestImmediateLocationFix()

        // Send GPS locations at 1Hz (every 1.0 second) to match watch GPS frequency
        gpsSharingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sendCurrentLocationToWatch()
        }
    }

    func stopGPSSharing() {
        guard isSharingGPS else { return }

        print("📱 🛑 Stopping GPS sharing with watch")
        isSharingGPS = false
        gpsSharingTimer?.invalidate()
        gpsSharingTimer = nil
    }

    private func sendCurrentLocationToWatch() {
        guard let session = session else {
            print("📱 ⚠️ WCSession unavailable for GPS sharing")
            return
        }

        let preferredLocation = locationManager.currentLocation
        let relayLocation = preferredLocation ?? locationManager.latestRawLocation

        guard let location = relayLocation else {
            print("📱 ⚠️ No iPhone GPS location available")
            locationManager.requestImmediateLocationFix()
            return
        }

        if location.horizontalAccuracy < 0 {
            print("📱 ⚠️ iPhone location invalid (negative accuracy) - requesting new fix")
            locationManager.requestImmediateLocationFix()
            return
        }

        let usingRawRelayLocation = (preferredLocation == nil)
        let sourceTag = locationManager.locationSource.description
        print(
            "📱 📡 Relaying iPhone location to watch: source=\(sourceTag), acc=±\(String(format: "%.1f", location.horizontalAccuracy))m, rawFallback=\(usingRawRelayLocation)"
        )

        // Convert CLLocation to dictionary for WatchConnectivity transfer
        var locationData: [String: Any] = [
            "action": "gpsLocation",
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "altitude": location.altitude,
            "horizontalAccuracy": location.horizontalAccuracy,
            "verticalAccuracy": location.verticalAccuracy,
            "speed": location.speed,
            "course": location.course,
            "timestamp": location.timestamp.timeIntervalSince1970,
            "relaySource": sourceTag,
            "usingRawRelayLocation": usingRawRelayLocation
        ]
        if let acceleration = locationManager.currentMotionAcceleration {
            locationData["motionAcceleration"] = acceleration
        }
        if let horizontalAcceleration = locationManager.currentMotionHorizontalAcceleration {
            locationData["motionHorizontalAcceleration"] = horizontalAcceleration
        }
        if let forwardAcceleration = locationManager.currentMotionForwardAcceleration {
            locationData["motionForwardAcceleration"] = forwardAcceleration
        }
        if let lateralAcceleration = locationManager.currentMotionLateralAcceleration {
            locationData["motionLateralAcceleration"] = lateralAcceleration
        }
        if let directionDegrees = locationManager.currentMotionDirectionDegrees {
            locationData["motionDirectionDegrees"] = directionDegrees
        }

        if session.isReachable {
            session.sendMessage(locationData, replyHandler: nil) { error in
                print("📱 ❌ Failed to send GPS location to watch: \(error.localizedDescription)")
            }
        } else {
            let pendingTransfers = session.outstandingUserInfoTransfers.count
            if pendingTransfers < 60 {
                session.transferUserInfo(locationData)
                print("📱 📦 Queued GPS location via userInfo (pending: \(pendingTransfers + 1))")
            } else {
                print("📱 ⚠️ Skipping userInfo GPS queue (pending transfers: \(pendingTransfers))")
            }
            do {
                try session.updateApplicationContext(locationData)
                print("📱 📤 Queued latest GPS location for watch (not currently reachable)")
            } catch {
                print("📱 ❌ Failed to queue GPS context for watch: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            self.isWatchAppInstalled = session.isWatchAppInstalled

            if let error = error {
                print("❌ WCSession activation failed: \(error.localizedDescription)")
            } else {
                print("✅ WCSession activated: \(activationState.rawValue)")
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            print("🔄 Watch reachability changed: \(session.isReachable)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        print("⚠️ WCSession became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        print("⚠️ WCSession deactivated")
        session.activate()
    }

    // MARK: - Receive Messages

    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        print("📱 Received message from watch: \(message)")

        if let action = message["action"] as? String {
            switch action {
            case "workoutStarted":
                startMirroredLiveActivityIfNeeded()
                // Keep iPhone positioning ready so watch can switch to phone-assisted location quickly.
                startGPSSharing()
                replyHandler(["status": "acknowledged"])
            case "workoutStopped":
                stopGPSSharing()  // Stop GPS sharing when workout stops
                endMirroredLiveActivity(finalDuration: 0, finalDistance: 0, finalCalories: 0)
                replyHandler(["status": "acknowledged"])
            case "requestGPS":
                // Watch is requesting iPhone GPS fallback
                print("📱 🛰️ Watch requesting GPS fallback")
                startGPSSharing()
                replyHandler(["status": "gps_sharing_started"])
            case "stopGPS":
                // Watch has recovered its own GPS
                print("📱 🛑 Watch stopped requesting GPS fallback")
                stopGPSSharing()
                replyHandler(["status": "gps_sharing_stopped"])
            default:
                replyHandler(["status": "unknown action"])
            }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        if let action = applicationContext["action"] as? String {
            DispatchQueue.main.async {
                switch action {
                case "requestGPS":
                    print("📱 🛰️ Received GPS fallback request via application context")
                    self.startGPSSharing()
                case "stopGPS":
                    print("📱 🛑 Received GPS stop request via application context")
                    self.stopGPSSharing()
                default:
                    break
                }
            }
            return
        }

        // Ignore empty context from Watch
        guard !applicationContext.isEmpty else {
            print("📱 Received empty application context from Watch - ignoring")
            return
        }

        print("📱 Received application context: \(applicationContext)")

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: applicationContext)
            let decoder = JSONDecoder()
            let data = try decoder.decode(WorkoutSyncData.self, from: jsonData)

            DispatchQueue.main.async {
                self.receivedWorkoutData = data
                let gpsDistance = data.gpsWorkoutDistance ?? data.distance
                print(
                    "📱 Sync payload from watch: gpsDistance=\(String(format: "%.2f", gpsDistance))m, nativeSteps=\(data.nativeStepCount.map { String(format: "%.0f", $0) } ?? "nil"), nativeStepDistance=\(data.nativeStepDistance.map { String(format: "%.2f", $0) } ?? "nil")m"
                )
                if data.isActive {
                    self.updateMirroredLiveActivity(with: data)
                } else {
                    let gpsDistance = data.gpsWorkoutDistance ?? data.distance
                    self.endMirroredLiveActivity(
                        finalDuration: data.duration,
                        finalDistance: gpsDistance,
                        finalCalories: data.calories
                    )
                }
            }
        } catch {
            print("❌ Failed to decode workout data: \(error.localizedDescription)")
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        handleFlightCheckpointMessageData(messageData)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadataType = file.metadata?["type"] as? String
        guard metadataType == "flight" || metadataType == "flightCheckpoint" else {
            print("📱 Received unknown file from watch")
            return
        }

        do {
            let data = try Data(contentsOf: file.fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            if metadataType == "flightCheckpoint" {
                let checkpoint = try decoder.decode(FlightCheckpointPayload.self, from: data)
                FlightDataStore.shared.mergeFlightCheckpoint(checkpoint)
                print("📱 💾 Saved watch checkpoint locally: \(checkpoint.flightID), newLocations=\(checkpoint.locations.count), total=\(checkpoint.totalLocationCount)")
            } else {
                let flight = try decoder.decode(Flight.self, from: data)

                guard let metrics = flight.metrics else {
                    print("📱 Flight transfer missing metrics - skipping HealthKit save")
                    return
                }

                print("📱 Received final flight transfer from watch: \(flight.id)")
                saveFlightToHealthKit(flight: flight, metrics: metrics)
            }
        } catch {
            print("❌ Failed to decode flight transfer: \(error.localizedDescription)")
        }
    }

    private func handleFlightCheckpointMessageData(_ messageData: Data) {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(FlightCheckpointEnvelope.self, from: messageData)

            guard envelope.type == "flightCheckpoint" else {
                print("📱 Received unknown data message from watch: \(envelope.type)")
                return
            }

            let checkpoint = try decoder.decode(FlightCheckpointPayload.self, from: envelope.payload)
            FlightDataStore.shared.mergeFlightCheckpoint(checkpoint)
            print("📱 💾 Saved immediate watch checkpoint: \(checkpoint.flightID), newLocations=\(checkpoint.locations.count), total=\(checkpoint.totalLocationCount)")
        } catch {
            print("❌ Failed to decode watch checkpoint message: \(error.localizedDescription)")
        }
    }

    private func saveFlightToHealthKit(flight: Flight, metrics: FlightMetrics) {
        let doSave = {
            self.healthKitManager.saveWorkout(
                flight: flight,
                locations: flight.locations,
                metrics: metrics
            ) { success, error, workout in
                if let workout = workout {
                    FlightDataStore.shared.updateWorkoutUUID(for: flight.id, workoutUUID: workout.uuid)
                }
                if success {
                    print("📱 ✅ Watch flight saved to HealthKit")
                } else {
                    print("📱 ❌ Failed to save watch flight to HealthKit: \(error?.localizedDescription ?? "Unknown")")
                }
            }
        }

        if healthKitManager.isAuthorized {
            doSave()
        } else {
            healthKitManager.requestAuthorization { success, error in
                if success {
                    doSave()
                } else {
                    print("📱 ❌ HealthKit authorization failed for watch transfer: \(error?.localizedDescription ?? "Unknown")")
                }
            }
        }
    }
}

// MARK: - Workout Sync Data Model

struct WorkoutSyncData: Codable {
    let isActive: Bool
    let startDate: Date?
    let duration: TimeInterval
    let distance: Double
    let gpsWorkoutDistance: Double?
    let nativeStepDistance: Double?
    let nativeStepCount: Double?
    let currentSpeed: Double
    let averageSpeed: Double
    let maxSpeed: Double
    let currentAltitude: Double
    let maxAltitude: Double
    let heartRate: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let calories: Double
    let locationCount: Int

    init(isActive: Bool = false,
         startDate: Date? = nil,
         duration: TimeInterval = 0,
         distance: Double = 0,
         gpsWorkoutDistance: Double? = nil,
         nativeStepDistance: Double? = nil,
         nativeStepCount: Double? = nil,
         currentSpeed: Double = 0,
         averageSpeed: Double = 0,
         maxSpeed: Double = 0,
         currentAltitude: Double = 0,
         maxAltitude: Double = 0,
         heartRate: Double? = nil,
         averageHeartRate: Double? = nil,
         maxHeartRate: Double? = nil,
         calories: Double = 0,
         locationCount: Int = 0) {
        self.isActive = isActive
        self.startDate = startDate
        self.duration = duration
        self.distance = distance
        self.gpsWorkoutDistance = gpsWorkoutDistance
        self.nativeStepDistance = nativeStepDistance
        self.nativeStepCount = nativeStepCount
        self.currentSpeed = currentSpeed
        self.averageSpeed = averageSpeed
        self.maxSpeed = maxSpeed
        self.currentAltitude = currentAltitude
        self.maxAltitude = maxAltitude
        self.heartRate = heartRate
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.calories = calories
        self.locationCount = locationCount
    }
}
