import Foundation
import WatchConnectivity
import Combine
import CoreLocation

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
    var workoutUUID: UUID?   // links the local track to the saved HealthKit workout
}

struct FlightCheckpointEnvelope: Codable {
    let type: String
    let payload: Data
}

struct IPhoneMotionAssist {
    let acceleration: Double?
    let horizontalAcceleration: Double?
    let forwardAcceleration: Double?
    let lateralAcceleration: Double?
    let directionDegrees: Double?
    let timestamp: Date
}

class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    enum IPhoneLocationFeedMode {
        case assist
        case fallback
    }

    @Published var isReachable = false
    @Published var shouldStartWorkout = false
    @Published var shouldStopWorkout = false
    @Published var receivedWorkoutData: WorkoutSyncData?
    @Published var receivedWorkoutType: Int?

    // iPhone GPS Fallback
    @Published var isUsingIPhoneGPS = false
    @Published var isIPhoneGPSRequestPending = false
    var onIPhoneLocationReceived: ((FlightLocation, IPhoneLocationFeedMode) -> Void)?
    var onIPhoneMotionAccelerationReceived: ((Double, Date) -> Void)?
    var onIPhoneMotionAssistReceived: ((IPhoneMotionAssist) -> Void)?
    /// iPhone's integrated dead-reckoning answer (speed m/s, heading°, velocity N/E, time).
    /// Arrives independently of GPS, so it keeps flowing when the watch needs it most.
    var onIPhoneDeadReckoningReceived: ((Double, Double, Double, Double, Date) -> Void)?

    fileprivate func handleIPhoneDeadReckoningState(_ message: [String: Any]) {
        guard let speed = message["drSpeed"] as? Double,
              let heading = message["drHeading"] as? Double else { return }
        let velN = message["drVelNorth"] as? Double ?? 0
        let velE = message["drVelEast"] as? Double ?? 0
        let ts = (message["timestamp"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? Date()
        onIPhoneDeadReckoningReceived?(speed, heading, velN, velE, ts)
    }
    private var dualSourceAssistEnabled = false
    var isDualSourceAssistEnabled: Bool { dualSourceAssistEnabled }

    private var session: WCSession?

    private override init() {
        super.init()

        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }

    // MARK: - Send Messages

    func notifyWorkoutStarted() {
        guard let session = session, session.isReachable else {
            print("⚠️ iPhone not reachable")
            return
        }

        let message = ["action": "workoutStarted"]
        session.sendMessage(message, replyHandler: { reply in
            print("✅ iPhone acknowledged workout start: \(reply)")
        }) { error in
            print("❌ Failed to notify iPhone: \(error.localizedDescription)")
        }
    }

    func notifyWorkoutStopped() {
        guard let session = session, session.isReachable else {
            print("⚠️ iPhone not reachable")
            return
        }

        let message = ["action": "workoutStopped"]
        session.sendMessage(message, replyHandler: { reply in
            print("✅ iPhone acknowledged workout stop: \(reply)")
        }) { error in
            print("❌ Failed to notify iPhone: \(error.localizedDescription)")
        }
    }

    func sendWorkoutUpdate(_ data: WorkoutSyncData) {
        guard let session = session else { return }

        do {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(data)

            if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                try session.updateApplicationContext(json)
                print("✅ Sent workout update to iPhone")
            }
        } catch {
            print("❌ Failed to send workout update: \(error.localizedDescription)")
        }
    }

    func transferFlightToPhone(_ flight: Flight) {
        transferFlightToPhone(flight, metadataType: "flight")
    }

    @discardableResult
    func transferFlightCheckpointToPhone(_ payload: FlightCheckpointPayload) -> Bool {
        transferPayloadToPhone(payload, metadataType: "flightCheckpoint", flightID: payload.flightID, preferImmediateMessage: true)
    }

    /// Tell the iPhone which HealthKit workout a locally-synced flight belongs to.
    /// Uses transferUserInfo — a small, durable, in-order transfer that is delivered
    /// even when the iPhone app is suspended (e.g. it was never in a workout).
    func transferFlightWorkoutLink(flightID: UUID, workoutUUID: UUID) {
        guard let session = session else { return }
        let info: [String: Any] = [
            "type": "flightLink",
            "flightID": flightID.uuidString,
            "workoutUUID": workoutUUID.uuidString
        ]
        session.transferUserInfo(info)
        // Also send immediately when reachable for a fast link.
        if session.activationState == .activated, session.isReachable {
            session.sendMessage(info, replyHandler: nil, errorHandler: nil)
        }
        print("⌚ 🔗 Sent flight→workout link: \(flightID) → \(workoutUUID)")
    }

    private func transferFlightToPhone(_ flight: Flight, metadataType: String) {
        _ = transferPayloadToPhone(flight, metadataType: metadataType, flightID: flight.id, preferImmediateMessage: false)
    }

    @discardableResult
    private func transferPayloadToPhone<T: Encodable>(_ payload: T, metadataType: String, flightID: UUID, preferImmediateMessage: Bool) -> Bool {
        guard let session = session else { return false }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)

            if metadataType == "flightCheckpoint" {
                // Allow a generous backlog; WCSession serialises file transfers itself.
                // Dropping checkpoints causes silent GPS data loss on the iPhone side.
                let pendingTransfers = session.outstandingFileTransfers.count
                if pendingTransfers >= 20 {
                    print("⌚ ⚠️ Checkpoint queue at \(pendingTransfers) — still queueing; consider relaunching iPhone app")
                }

                let fileURL = temporaryPayloadURL(metadataType: metadataType, flightID: flightID)
                try data.write(to: fileURL, options: .atomic)
                session.transferFile(fileURL, metadata: ["type": metadataType])
                print("⌚ 📤 Queued durable \(metadataType) transfer to iPhone: \(flightID)")

                if preferImmediateMessage, session.activationState == .activated, session.isReachable {
                    let envelope = FlightCheckpointEnvelope(type: metadataType, payload: data)
                    let envelopeData = try encoder.encode(envelope)
                    session.sendMessageData(envelopeData, replyHandler: nil) { error in
                        print("⌚ ❌ Immediate \(metadataType) message failed: \(error.localizedDescription)")
                    }
                    print("⌚ 📡 Sent immediate \(metadataType) message to iPhone: \(flightID), bytes=\(envelopeData.count)")
                }

                return true
            }

            if preferImmediateMessage, session.activationState == .activated, session.isReachable {
                let envelope = FlightCheckpointEnvelope(type: metadataType, payload: data)
                let envelopeData = try encoder.encode(envelope)
                session.sendMessageData(envelopeData, replyHandler: nil) { error in
                    print("⌚ ❌ Immediate \(metadataType) message failed: \(error.localizedDescription)")
                }
                print("⌚ 📡 Sent immediate \(metadataType) message to iPhone: \(flightID), bytes=\(envelopeData.count)")
                return true
            }

            // Always queue; WCSession handles backpressure. Dropping = data loss.
            let pendingTransfers = session.outstandingFileTransfers.count
            if pendingTransfers >= 20 {
                print("⌚ ⚠️ \(metadataType) queue at \(pendingTransfers) — still queueing")
            }

            let fileURL = temporaryPayloadURL(metadataType: metadataType, flightID: flightID)
            try data.write(to: fileURL, options: .atomic)
            session.transferFile(fileURL, metadata: ["type": metadataType])
            print("⌚ 📤 Queued \(metadataType) transfer to iPhone: \(flightID)")
            return true
        } catch {
            print("⌚ ❌ Failed to transfer \(metadataType) to iPhone: \(error.localizedDescription)")
            return false
        }
    }

    private func temporaryPayloadURL(metadataType: String, flightID: UUID) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileName = "\(metadataType)_\(flightID.uuidString)_\(timestamp)_\(UUID().uuidString).json"
        return FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    // MARK: - iPhone GPS Fallback

    func requestIPhoneGPS() {
        guard !isUsingIPhoneGPS else {
            print("⌚ Already using iPhone GPS")
            return
        }

        guard let session = session else {
            print("⌚ ⚠️ WCSession unavailable for GPS fallback")
            return
        }

        isIPhoneGPSRequestPending = true
        print("⌚ 🛰️ Requesting iPhone location fallback")
        let command = ["action": "requestGPS"]

        // Always send application context command as a background-safe fallback.
        do {
            try session.updateApplicationContext(command)
            print("⌚ 📤 Sent iPhone GPS request via application context fallback")
        } catch {
            print("⌚ ⚠️ Failed to queue iPhone GPS context request: \(error.localizedDescription)")
        }

        guard session.isReachable else {
            print("⌚ ⚠️ iPhone not currently reachable - waiting for background command delivery")
            return
        }

        session.sendMessage(command, replyHandler: { reply in
            print("⌚ ✅ iPhone acknowledged GPS fallback request: \(reply)")
            DispatchQueue.main.async {
                // Mark pending until first fallback location actually arrives.
                self.isIPhoneGPSRequestPending = true
            }
        }) { error in
            print("⌚ ❌ Failed to request iPhone GPS: \(error.localizedDescription)")
        }
    }

    func stopIPhoneGPS() {
        guard let session = session else {
            print("⌚ ⚠️ WCSession unavailable")
            return
        }

        guard isUsingIPhoneGPS || isIPhoneGPSRequestPending else {
            print("⌚ Not using iPhone GPS")
            return
        }

        print("⌚ 🛑 Stopping iPhone GPS fallback")
        let command = ["action": "stopGPS"]

        do {
            try session.updateApplicationContext(command)
            print("⌚ 📤 Sent iPhone GPS stop via application context fallback")
        } catch {
            print("⌚ ⚠️ Failed to queue iPhone GPS stop context: \(error.localizedDescription)")
        }

        if session.isReachable {
            session.sendMessage(command, replyHandler: { reply in
                print("⌚ ✅ iPhone GPS fallback stopped: \(reply)")
            }) { error in
                print("⌚ ❌ Failed to stop iPhone GPS: \(error.localizedDescription)")
            }
        } else {
            print("⌚ ⚠️ iPhone not currently reachable - stop command queued")
        }

        DispatchQueue.main.async {
            self.isUsingIPhoneGPS = false
            self.isIPhoneGPSRequestPending = false
        }
    }

    func setDualSourceAssistEnabled(_ enabled: Bool) {
        dualSourceAssistEnabled = enabled
        if enabled {
            print("⌚ 🔁 Dual-source ingest enabled (watch GPS + iPhone relay)")
        } else {
            print("⌚ 🔁 Dual-source ingest disabled")
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable

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
            print("🔄 iPhone reachability changed: \(session.isReachable)")
        }
    }

    // MARK: - Receive Messages

    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        if let action = message["action"] as? String {
            DispatchQueue.main.async {
                switch action {
                case "startWorkout":
                    print("⌚ Received message from iPhone: startWorkout")
                    // Extract workout type if provided
                    if let workoutType = message["workoutType"] as? Int {
                        print("⌚ Received workout type: \(workoutType)")
                        self.receivedWorkoutType = workoutType
                    }
                    self.shouldStartWorkout = true
                    replyHandler(["status": "starting workout"])
                case "stopWorkout":
                    print("⌚ Received message from iPhone: stopWorkout")
                    self.shouldStopWorkout = true
                    replyHandler(["status": "stopping workout"])
                case "gpsLocation":
                    // Received GPS location from iPhone
                    self.handleIPhoneGPSLocation(message)
                    // No reply needed for location updates (fire-and-forget for performance)
                case "drState":
                    self.handleIPhoneDeadReckoningState(message)
                default:
                    print("⌚ Received unknown message from iPhone: \(message)")
                    replyHandler(["status": "unknown action"])
                }
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        // Handle messages without reply handler (fire-and-forget)
        if let action = message["action"] as? String {
            DispatchQueue.main.async {
                switch action {
                case "gpsLocation":
                    // Received GPS location from iPhone
                    self.handleIPhoneGPSLocation(message)
                case "drState":
                    self.handleIPhoneDeadReckoningState(message)
                default:
                    print("⌚ Received fire-and-forget message: \(action)")
                }
            }
        }
    }

    private func handleIPhoneGPSLocation(_ message: [String: Any]) {
        let isFallbackLocation = isUsingIPhoneGPS || isIPhoneGPSRequestPending
        guard dualSourceAssistEnabled || isFallbackLocation else {
            return
        }

        guard let latitude = message["latitude"] as? Double,
              let longitude = message["longitude"] as? Double,
              let altitude = message["altitude"] as? Double,
              let horizontalAccuracy = message["horizontalAccuracy"] as? Double,
              let verticalAccuracy = message["verticalAccuracy"] as? Double,
              let speed = message["speed"] as? Double,
              let course = message["course"] as? Double,
              let timestampInterval = message["timestamp"] as? TimeInterval else {
            print("⌚ ⚠️ Invalid iPhone GPS location data")
            return
        }

        let timestamp = Date(timeIntervalSince1970: timestampInterval)
        let relaySource = message["relaySource"] as? String ?? "unknown"
        let usingRawRelayLocation = (message["usingRawRelayLocation"] as? Bool) ?? false
        let motionAcceleration = message["motionAcceleration"] as? Double
        let motionHorizontalAcceleration = message["motionHorizontalAcceleration"] as? Double
        let motionForwardAcceleration = message["motionForwardAcceleration"] as? Double
        let motionLateralAcceleration = message["motionLateralAcceleration"] as? Double
        let motionDirectionDegrees = message["motionDirectionDegrees"] as? Double

        if let acceleration = motionAcceleration {
            onIPhoneMotionAccelerationReceived?(acceleration, timestamp)
        }
        if motionAcceleration != nil ||
            motionHorizontalAcceleration != nil ||
            motionForwardAcceleration != nil ||
            motionLateralAcceleration != nil ||
            motionDirectionDegrees != nil {
            onIPhoneMotionAssistReceived?(
                IPhoneMotionAssist(
                    acceleration: motionAcceleration,
                    horizontalAcceleration: motionHorizontalAcceleration,
                    forwardAcceleration: motionForwardAcceleration,
                    lateralAcceleration: motionLateralAcceleration,
                    directionDegrees: motionDirectionDegrees,
                    timestamp: timestamp
                )
            )
        }

        // Create CLLocation from iPhone GPS data
        let clLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            course: course,
            speed: speed,
            timestamp: timestamp
        )

        // Convert to FlightLocation
        let location = FlightLocation(
            from: clLocation,
            isFiltered: false,
            isValid: true,
            satelliteCount: nil,
            signalStrength: nil,
            pressure: nil  // iPhone doesn't send pressure data
        )

        if isFallbackLocation {
            if !isUsingIPhoneGPS {
                print("⌚ ✅ iPhone fallback location stream started")
            }
            isUsingIPhoneGPS = true
            isIPhoneGPSRequestPending = false
            print(
                "⌚ 📱 Fallback location: source=\(relaySource), acc=±\(String(format: "%.1f", horizontalAccuracy))m, rawRelay=\(usingRawRelayLocation)"
            )
            onIPhoneLocationReceived?(location, .fallback)
            return
        }

        print(
            "⌚ 📱 Assist location: source=\(relaySource), acc=±\(String(format: "%.1f", horizontalAccuracy))m, rawRelay=\(usingRawRelayLocation)"
        )
        onIPhoneLocationReceived?(location, .assist)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        if let action = applicationContext["action"] as? String {
            DispatchQueue.main.async {
                switch action {
                case "gpsLocation":
                    self.handleIPhoneGPSLocation(applicationContext)
                case "drState":
                    self.handleIPhoneDeadReckoningState(applicationContext)
                default:
                    print("⌚ Received application-context action: \(action)")
                }
            }
            return
        }

        // Ignore empty context (happens when iPhone hasn't sent data yet)
        guard !applicationContext.isEmpty else {
            print("⌚ Received empty application context - ignoring")
            return
        }

        print("⌚ Received application context: \(applicationContext)")

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: applicationContext)
            let decoder = JSONDecoder()
            let data = try decoder.decode(WorkoutSyncData.self, from: jsonData)

            DispatchQueue.main.async {
                self.receivedWorkoutData = data
                print("⌚ ✅ Updated workout data from iPhone")
            }
        } catch {
            print("⌚ ⚠️ Failed to decode workout data: \(error.localizedDescription)")
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        guard let action = userInfo["action"] as? String else {
            print("⌚ Received userInfo without action")
            return
        }

        DispatchQueue.main.async {
            switch action {
            case "gpsLocation":
                self.handleIPhoneGPSLocation(userInfo)
            case "drState":
                self.handleIPhoneDeadReckoningState(userInfo)
            default:
                print("⌚ Received userInfo action: \(action)")
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
