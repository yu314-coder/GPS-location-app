import Foundation
import CoreLocation
import CoreMotion
import Combine

class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    private let locationManager = CLLocationManager()
    private let kalmanFilter = KalmanFilterEngine()
    private let dataValidator = DataValidator()
    private let altimeter = CMAltimeter()
    private let motionManager = CMMotionManager()

    @Published var currentLocation: CLLocation?
    @Published var latestRawLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus
    @Published var isTracking = false
    @Published var locations: [FlightLocation] = []
    @Published var gpsSignalQuality: GPSSignalQuality = .unknown
    @Published var locationSource: LocationSource = .unknown
    @Published var currentPressure: Double? // in kilopascals (kPa)
    @Published var currentMotionAcceleration: Double? // in m/s², gravity removed
    @Published var currentPitch: Double? // degrees
    @Published var currentRoll: Double? // degrees
    @Published var currentYaw: Double? // degrees
    @Published var currentRotationRate: Double? // rad/s magnitude
    @Published var currentCompassHeading: Double? // degrees
    @Published var currentMotionHorizontalAcceleration: Double? // in m/s², gravity removed
    @Published var currentMotionForwardAcceleration: Double? // in m/s² along current travel direction
    @Published var currentMotionLateralAcceleration: Double? // in m/s² sideways to current travel direction
    @Published var currentMotionDirectionDegrees: Double? // degrees, estimated movement direction
    @Published var currentRelativeAltitude: Double? // in meters from altimeter start
    @Published var currentVerticalSpeed: Double? // in m/s

    var onLocationUpdate: ((FlightLocation) -> Void)?
    var onMotionAccelerationUpdate: ((Double, Double?, Double?, Double?, Double?, Double?, Double?, Double?, Double?, Double?, Date) -> Void)?
    var onCompassHeadingUpdate: ((Double, Date) -> Void)?
    var onBarometricAltitudeUpdate: ((Double, Double?, Date) -> Void)?

    // Pressure tracking
    private var latestPressure: Double?
    private var lastRelativeAltitudeSample: (altitude: Double, timestamp: Date)?
    /// Monotonic timestamp of the previous device-motion sample, used to derive the true
    /// integration interval for inertial dead reckoning.
    private var lastMotionSampleTimestamp: TimeInterval?
    /// Local magnetic declination (true − magnetic), learned from CLHeading. Used to rotate
    /// Core Motion's magnetic-north-referenced acceleration into the true-north frame.
    private(set) var magneticDeclinationDegrees: Double = 0
    /// False when Core Motion could only supply `.xArbitraryZVertical`, i.e. the world X axis
    /// is not north and integrated direction is meaningless in absolute terms.
    private(set) var motionReferenceFrameIsAbsolute: Bool = true
    private let standardGravity = 9.80665

    // GPS reconnection logic
    private var gpsTimeoutTimer: Timer?
    private var reconnectionTimer: Timer?
    private var reconnectionAttempts = 0
    private var lastLocationUpdateTime: Date?
    private var lastValidLocationTime: Date?
    private let GPS_TIMEOUT_INTERVAL: TimeInterval = 5.0 // 5 seconds without GPS = connection issue
    private let GPS_RECOVERY_INTERVAL: TimeInterval = 60.0 // 60 seconds without GPS triggers recovery mode
    private let MAX_RECONNECTION_ATTEMPTS = 10
    private let BASE_RETRY_DELAY: TimeInterval = 1.0 // Start with 1 second
    private var recoveryModeActivated = false
    private let maxFilterDivergenceFitness: CLLocationDistance = 500.0
    private let maxFilterDivergenceAirborne: CLLocationDistance = 5000.0

    // WiFi/Cellular fallback settings
    private var isFallbackModeActive = false
    private var fallbackModeStartTime: Date?
    private let FALLBACK_ACTIVATION_DELAY: TimeInterval = 10.0 // Activate WiFi/Cellular after 10s without GPS
    private let FALLBACK_DEACTIVATION_DELAY: TimeInterval = 5.0 // Return to GPS after 5s of good signal

    override init() {
        self.authorizationStatus = locationManager.authorizationStatus
        super.init()
        setupLocationManager()
    }

    private func setupLocationManager() {
        locationManager.delegate = self

        // iOS 16.4+ requirement: desiredAccuracy must be kCLLocationAccuracyHundredMeters or better
        // for background updates to work
        locationManager.desiredAccuracy = kCLLocationAccuracyBest

        // iOS 16.4+ requirement: distanceFilter must be kCLDistanceFilterNone for continuous updates
        locationManager.distanceFilter = kCLDistanceFilterNone

        locationManager.pausesLocationUpdatesAutomatically = false

        // Request maximum update frequency (approximately 0.1s intervals)
        if #available(iOS 15.0, *) {
            locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        }

        // Activity type for better battery management
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = (authorizationStatus == .authorizedAlways)
        locationManager.showsBackgroundLocationIndicator = (authorizationStatus == .authorizedAlways)

        print("✅ Location manager configured for fitness tracking")
    }

    func requestAuthorization() {
        // IMPORTANT: iOS 13+ requires requesting "When In Use" first
        // You cannot directly request "Always" - must be a two-step process

        let status = locationManager.authorizationStatus

        if status == .notDetermined {
            // Step 1: Request "When In Use" first
            print("📍 Requesting 'When In Use' location permission...")
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse {
            // Step 2: Upgrade to "Always" if we already have "When In Use"
            print("📍 Upgrading to 'Always' location permission...")
            locationManager.requestAlwaysAuthorization()
        } else if status == .authorizedAlways {
            print("✅ Already have 'Always' location permission")
        } else {
            print("❌ Location permission denied or restricted")
        }
    }

    func requestAlwaysAuthorization() {
        // Public method to explicitly request Always permission
        // Only works if user already granted When In Use
        if authorizationStatus == .authorizedWhenInUse {
            print("📍 Upgrading to 'Always' location permission...")
            locationManager.requestAlwaysAuthorization()
        } else if authorizationStatus == .notDetermined {
            print("⚠️ Must request 'When In Use' first")
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func startTracking() {
        print("📍 LocationManager.startTracking() called")
        print("   Current isTracking: \(isTracking)")
        print("   Authorization: \(authorizationStatus.rawValue)")

        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            print("❌ Location permission not granted - cannot start tracking")
            print("   Current status: \(authorizationStatus.rawValue)")
            return
        }

        isTracking = true
        print("   Setting isTracking = true")

        locationManager.allowsBackgroundLocationUpdates = (authorizationStatus == .authorizedAlways)
        locationManager.showsBackgroundLocationIndicator = (authorizationStatus == .authorizedAlways)

        print("   Calling CLLocationManager.startUpdatingLocation()...")
        locationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        }
        if authorizationStatus == .authorizedAlways {
            locationManager.startMonitoringSignificantLocationChanges()
            print("   Significant-change monitoring: Active (relaunch safety)")
        }

        // Reset reconnection state when starting fresh
        reconnectionAttempts = 0
        lastLocationUpdateTime = Date()
        lastValidLocationTime = Date()
        recoveryModeActivated = false

        // Start GPS timeout monitoring
        startGPSTimeoutMonitoring()

        // Start pressure tracking
        startPressureTracking()

        // Start device-motion acceleration recording. This is metrics-only and does not drive detection.
        startMotionTracking()

        print("✅ Started GPS tracking with WiFi/Cellular fallback")
        print("   isTracking: \(isTracking)")
        print("   Desired accuracy: Best for Navigation (GPS)")
        print("   Fallback: WiFi/Cellular positioning after 10s timeout")
        print("   Distance filter: None (continuous updates)")
        print("   Permission: \(authorizationStatus == .authorizedAlways ? "Always" : "When In Use")")
        print("   Background: Enabled via Info.plist UIBackgroundModes + HKWorkoutBuilder")
        print("   GPS timeout monitoring: Active (5s timeout)")

        if authorizationStatus != .authorizedAlways {
            print("   ⚠️ For background tracking, grant 'Always' permission in Settings")
        }
    }

    func requestImmediateLocationFix() {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            print("📍 Cannot request immediate fix - location permission not granted")
            return
        }
        locationManager.requestLocation()
    }

    func stopTracking() {
        print("⏹️ LocationManager.stopTracking() called")
        print("   Current isTracking: \(isTracking)")

        isTracking = false
        print("   Setting isTracking = false")

        print("   Calling CLLocationManager.stopUpdatingLocation()...")
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        locationManager.stopMonitoringSignificantLocationChanges()

        // Clean up timers
        stopGPSTimeoutMonitoring()
        cancelReconnectionTimer()
        recoveryModeActivated = false
        lastValidLocationTime = nil
        locationManager.activityType = .fitness

        // Reset fallback mode
        isFallbackModeActive = false
        fallbackModeStartTime = nil

        // Stop pressure tracking
        stopPressureTracking()

        // Stop motion tracking
        stopMotionTracking()

        // Restore high accuracy mode for next session
        if #available(iOS 15.0, *) {
            locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        } else {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
        }

        print("✅ Stopped GPS tracking")
        print("   isTracking: \(isTracking)")
        print("   GPS timeout monitoring: Stopped")
    }

    private func processLocation(_ rawLocation: CLLocation) {
        let (processedLocation, isFiltered) = processLocationForTracking(rawLocation)
        let isValid = dataValidator.validateLocation(processedLocation)

        let flightLocation = FlightLocation(
            from: processedLocation,
            isFiltered: isFiltered,
            isValid: isValid,
            pressure: latestPressure
        )

        // Update last location time to reset timeout
        lastLocationUpdateTime = Date()

        // Reset reconnection attempts on successful location update
        if reconnectionAttempts > 0 {
            print("✅ GPS connection restored after \(reconnectionAttempts) reconnection attempts")
            reconnectionAttempts = 0
        }

        // Check if we should deactivate fallback mode (good GPS signal restored)
        if isFallbackModeActive && processedLocation.horizontalAccuracy < 50 && isValid {
            // Good GPS signal detected while in fallback mode
            if let fallbackStart = fallbackModeStartTime,
               Date().timeIntervalSince(fallbackStart) >= FALLBACK_DEACTIVATION_DELAY {
                deactivateFallbackMode()
            }
        }

        // Only process valid locations
        if isValid {
            lastValidLocationTime = Date()
            // IMPORTANT: Update @Published properties on main thread to avoid warning
            DispatchQueue.main.async { [weak self] in
                self?.currentLocation = processedLocation
                self?.locations.append(flightLocation)
                self?.updateSignalQuality(from: processedLocation)
            }

            // Keep session updates on the main actor to avoid SwiftUI publish violations.
            if Thread.isMainThread {
                onLocationUpdate?(flightLocation)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.onLocationUpdate?(flightLocation)
                }
            }
        } else {
            // Log invalid locations for debugging
            if locations.count < 5 {
                print("⚠️ Invalid location filtered out - accuracy: \(processedLocation.horizontalAccuracy)m")
            }
        }
    }

    private func updateSignalQuality(from location: CLLocation) {
        let accuracy = location.horizontalAccuracy

        // Determine location source based on accuracy
        // GPS typically provides <20m accuracy
        // WiFi positioning provides 20-100m accuracy
        // Cellular positioning provides 100m-1km+ accuracy
        if accuracy < 0 {
            gpsSignalQuality = .noSignal
            locationSource = .unknown
        } else if accuracy < 20 {
            gpsSignalQuality = .excellent
            locationSource = .gps
        } else if accuracy < 50 {
            gpsSignalQuality = .good
            locationSource = .hybrid // GPS + WiFi
        } else if accuracy < 100 {
            gpsSignalQuality = .fair
            locationSource = .wifi
        } else if accuracy < 1000 {
            gpsSignalQuality = .poor
            locationSource = .wifi
        } else {
            gpsSignalQuality = .poor
            locationSource = .cellular
        }
    }

    private func determineLocationSource(from accuracy: Double) -> LocationSource {
        // Heuristic based on typical accuracy ranges:
        // GPS: 5-20m
        // WiFi: 20-100m
        // Cellular: 100m-3km+
        if accuracy < 0 {
            return .unknown
        } else if accuracy < 20 {
            return .gps
        } else if accuracy < 65 {
            return .hybrid // Likely GPS + WiFi
        } else if accuracy < 200 {
            return .wifi
        } else {
            return .cellular
        }
    }

    private func processLocationForTracking(_ rawLocation: CLLocation) -> (CLLocation, Bool) {
        // Filter first, then sanity-check the filtered output.
        let filteredLocation = kalmanFilter.filterLocation(rawLocation)
        let maxDivergence = (locationManager.activityType == .airborne)
            ? maxFilterDivergenceAirborne
            : maxFilterDivergenceFitness

        if !isCoordinateValid(filteredLocation.coordinate) {
            kalmanFilter.reset()
            return (rawLocation, false)
        }

        let divergence = rawLocation.distance(from: filteredLocation)
        if divergence > maxDivergence {
            kalmanFilter.reset()
            return (rawLocation, false)
        }

        return (filteredLocation, true)
    }

    private func isCoordinateValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        return lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
    }

    func reset() {
        locations.removeAll()
        currentLocation = nil
        latestRawLocation = nil
        kalmanFilter.reset()
        stopGPSTimeoutMonitoring()
        cancelReconnectionTimer()
        reconnectionAttempts = 0
        lastLocationUpdateTime = nil
        lastValidLocationTime = nil

        // Reset fallback mode
        isFallbackModeActive = false
        fallbackModeStartTime = nil
    }

    func updateActivityType(_ activityType: CLActivityType) {
        locationManager.activityType = activityType
        print("📍 Activity type set to \(activityType)")
    }

    /// Adjust GPS power draw to relieve thermal pressure. When the device is hot,
    /// drop from best/navigation accuracy to a coarser (but still route-usable)
    /// accuracy and apply a small distance filter so fewer updates fire.
    func applyThermalAccuracy(reduced: Bool) {
        if reduced {
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 5.0
            print("🌡️ GPS throttled for heat: NearestTenMeters, distanceFilter=5m")
        } else {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = kCLDistanceFilterNone
            print("🌡️ GPS restored to full accuracy")
        }
    }

    /// Adjust device-motion update rate to relieve thermal pressure.
    func applyThermalMotionInterval(hot: Bool) {
        guard motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = hot ? 1.0 : 0.5
    }

    // MARK: - GPS Timeout Monitoring

    private func startGPSTimeoutMonitoring() {
        stopGPSTimeoutMonitoring() // Clean up existing timer

        gpsTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkGPSTimeout()
        }
    }

    private func stopGPSTimeoutMonitoring() {
        gpsTimeoutTimer?.invalidate()
        gpsTimeoutTimer = nil
    }

    private func checkGPSTimeout() {
        guard isTracking else { return }

        guard let lastUpdate = lastLocationUpdateTime else {
            // No location received yet, this is normal at startup
            return
        }

        let timeSinceLastUpdate = Date().timeIntervalSince(lastUpdate)

        if timeSinceLastUpdate >= GPS_TIMEOUT_INTERVAL {
            handleGPSTimeout(timeSinceLastUpdate: timeSinceLastUpdate)
        }

        let validReference = lastValidLocationTime ?? lastUpdate
        let timeSinceValid = Date().timeIntervalSince(validReference)

        if timeSinceValid >= GPS_RECOVERY_INTERVAL {
            activateRecoveryModeIfNeeded()
        }
    }

    private func handleGPSTimeout(timeSinceLastUpdate: TimeInterval) {
        print("⚠️ GPS timeout detected - no updates for \(String(format: "%.1f", timeSinceLastUpdate))s")

        gpsSignalQuality = .noSignal

        // Activate WiFi/Cellular fallback if timeout persists
        if timeSinceLastUpdate >= FALLBACK_ACTIVATION_DELAY && !isFallbackModeActive {
            activateFallbackMode()
        }

        attemptReconnection()
    }

    private func activateRecoveryModeIfNeeded() {
        guard !recoveryModeActivated else { return }
        recoveryModeActivated = true

        print("🚨 No GPS fix for 60s - activating recovery mode")
        print("   Requesting full accuracy (if available) and switching activity type to airborne")

        if #available(iOS 14.0, *) {
            if locationManager.accuracyAuthorization == .reducedAccuracy {
                locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "FullAccuracyTracking") { error in
                    if let error = error {
                        print("❌ Failed to request full accuracy: \(error.localizedDescription)")
                    } else {
                        print("✅ Temporary full accuracy granted")
                    }
                }
            }
        }

        locationManager.activityType = .airborne
    }

    // MARK: - WiFi/Cellular Fallback Logic

    private func activateFallbackMode() {
        guard !isFallbackModeActive else { return }
        isFallbackModeActive = true
        fallbackModeStartTime = Date()

        print("📡 Activating WiFi/Cellular fallback mode")
        print("   GPS signal weak or unavailable - using alternative positioning")

        // Switch to lower accuracy mode which enables WiFi and Cellular positioning
        // kCLLocationAccuracyHundredMeters enables WiFi positioning
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        // Restart location updates to apply new accuracy settings
        locationManager.stopUpdatingLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isTracking else { return }
            self.locationManager.startUpdatingLocation()
            print("   ✅ Fallback mode active - using WiFi/Cellular positioning")
        }
    }

    private func deactivateFallbackMode() {
        guard isFallbackModeActive else { return }
        isFallbackModeActive = false
        fallbackModeStartTime = nil

        print("🛰️ Deactivating fallback mode - GPS signal restored")
        print("   Switching back to high-accuracy GPS positioning")

        // Switch back to high accuracy GPS mode
        if #available(iOS 15.0, *) {
            locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        } else {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
        }

        // Restart location updates to apply new accuracy settings
        locationManager.stopUpdatingLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isTracking else { return }
            self.locationManager.startUpdatingLocation()
            print("   ✅ High-accuracy GPS mode restored")
        }
    }

    // MARK: - Pressure Tracking

    private func startPressureTracking() {
        // Check if relative altitude (barometric pressure) is available
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            print("⚠️ Barometric pressure sensor not available on this device")
            return
        }

        print("🌡️ Starting barometric pressure tracking")

        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] (altitudeData, error) in
            guard let self = self else { return }

            if let error = error {
                print("❌ Altimeter error: \(error.localizedDescription)")
                return
            }

            guard let data = altitudeData else { return }

            // Convert pressure from kPa to hPa (hectopascals/millibars) for display
            // CMAltitudeData.pressure is in kilopascals (kPa)
            let pressureKPa = data.pressure.doubleValue
            let relativeAltitude = data.relativeAltitude.doubleValue
            let timestamp = Date()

            self.latestPressure = pressureKPa
            self.onBarometricAltitudeUpdate?(relativeAltitude, pressureKPa, timestamp)

            var verticalSpeed: Double?
            if let previous = self.lastRelativeAltitudeSample {
                let timeDelta = timestamp.timeIntervalSince(previous.timestamp)
                if timeDelta > 0.2 {
                    verticalSpeed = (relativeAltitude - previous.altitude) / timeDelta
                }
            }
            self.lastRelativeAltitudeSample = (relativeAltitude, timestamp)

            DispatchQueue.main.async {
                self.currentPressure = pressureKPa
                self.currentRelativeAltitude = relativeAltitude
                self.currentVerticalSpeed = verticalSpeed
            }
        }
    }

    private func stopPressureTracking() {
        altimeter.stopRelativeAltitudeUpdates()
        latestPressure = nil
        lastRelativeAltitudeSample = nil
        DispatchQueue.main.async { [weak self] in
            self?.currentPressure = nil
            self?.currentRelativeAltitude = nil
            self?.currentVerticalSpeed = nil
        }
        print("🌡️ Stopped barometric pressure tracking")
    }

    // MARK: - Motion Tracking

    private func startMotionTracking() {
        guard motionManager.isDeviceMotionAvailable else {
            print("⚠️ Device motion acceleration not available on this device")
            return
        }

        motionManager.deviceMotionUpdateInterval = 0.5
        lastMotionSampleTimestamp = nil
        print("📈 Starting device-motion acceleration recording")

        // Whether the attitude frame is geographically anchored. `.xArbitraryZVertical` has a
        // vertical Z but an X axis pointing in an UNKNOWN direction, so world-frame
        // acceleration from it carries no absolute bearing information — distance is still
        // valid, direction is not. Consumers must not treat it as north.
        motionReferenceFrameIsAbsolute = CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
        if !motionReferenceFrameIsAbsolute {
            print("⚠️ Magnetic-north attitude frame unavailable — dead-reckoned DIRECTION will fall back to compass/GPS course")
        }

        let referenceFrame: CMAttitudeReferenceFrame = CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
            ? .xMagneticNorthZVertical
            : .xArbitraryZVertical

        motionManager.startDeviceMotionUpdates(using: referenceFrame, to: .main) { [weak self] motion, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ Device motion error: \(error.localizedDescription)")
                return
            }

            guard let motion else { return }
            let userAcceleration = motion.userAcceleration
            let acceleration = sqrt(
                pow(userAcceleration.x, 2) +
                pow(userAcceleration.y, 2) +
                pow(userAcceleration.z, 2)
            ) * self.standardGravity
            let accelerationX = userAcceleration.x * self.standardGravity
            let accelerationY = userAcceleration.y * self.standardGravity
            let accelerationZ = userAcceleration.z * self.standardGravity
            let referenceAcceleration = self.trueNorthAcceleration(from: motion)
            let horizontalAcceleration = sqrt(
                referenceAcceleration.north * referenceAcceleration.north +
                referenceAcceleration.east * referenceAcceleration.east
            )
            let movementDirection = self.currentLocation?.course ?? self.currentCompassHeading ?? (
                horizontalAcceleration > 0.05
                    ? self.normalizedDegrees(atan2(referenceAcceleration.east, referenceAcceleration.north) * 180 / .pi)
                    : nil
            )
            let projectedAcceleration = self.projectAcceleration(
                north: referenceAcceleration.north,
                east: referenceAcceleration.east,
                directionDegrees: movementDirection
            )
            let pitch = motion.attitude.pitch * 180 / .pi
            let roll = motion.attitude.roll * 180 / .pi
            let yaw = motion.attitude.yaw * 180 / .pi
            let rotationRate = motion.rotationRate
            let rotationMagnitude = sqrt(
                pow(rotationRate.x, 2) +
                pow(rotationRate.y, 2) +
                pow(rotationRate.z, 2)
            )
            let timestamp = Date()

            self.currentMotionAcceleration = acceleration
            self.currentPitch = pitch
            self.currentRoll = roll
            self.currentYaw = yaw
            self.currentRotationRate = rotationMagnitude
            self.currentMotionHorizontalAcceleration = horizontalAcceleration
            self.currentMotionForwardAcceleration = projectedAcceleration.forward
            self.currentMotionLateralAcceleration = projectedAcceleration.lateral
            self.currentMotionDirectionDegrees = movementDirection
            // Feed the inertial dead-reckoning integrator at the sensor rate. dt MUST come
            // from the sample timestamps, not from deviceMotionUpdateInterval: that property
            // is the REQUESTED rate, delivery jitters around it, and setHighRateMotion flips
            // it between 2Hz and 50Hz mid-workout. Integrating with a nominal dt injects a
            // direct, unbounded error into velocity and therefore distance.
            let sampleDt: TimeInterval
            if let previous = self.lastMotionSampleTimestamp {
                // Clamp against dropped/duplicated samples and scheduler stalls.
                sampleDt = min(max(motion.timestamp - previous, 0.0), 1.0)
            } else {
                sampleDt = 0.0
            }
            self.lastMotionSampleTimestamp = motion.timestamp
            if sampleDt > 0 {
                self.onWorldAccelSample?(referenceAcceleration.north,
                                         referenceAcceleration.east,
                                         referenceAcceleration.up,
                                         rotationMagnitude,
                                         sampleDt)
            }
            self.onMotionAccelerationUpdate?(
                acceleration,
                accelerationX,
                accelerationY,
                accelerationZ,
                pitch,
                roll,
                yaw,
                rotationRate.x,
                rotationRate.y,
                rotationRate.z,
                timestamp
            )
        }
    }

    private func stopMotionTracking() {
        motionManager.stopDeviceMotionUpdates()
        lastMotionSampleTimestamp = nil
        DispatchQueue.main.async { [weak self] in
            self?.currentMotionAcceleration = nil
            self?.currentPitch = nil
            self?.currentRoll = nil
            self?.currentYaw = nil
            self?.currentRotationRate = nil
            self?.currentCompassHeading = nil
            self?.currentMotionHorizontalAcceleration = nil
            self?.currentMotionForwardAcceleration = nil
            self?.currentMotionLateralAcceleration = nil
            self?.currentMotionDirectionDegrees = nil
        }
        print("📈 Stopped device-motion acceleration recording")
    }

    /// World-frame acceleration rotated from Core Motion's MAGNETIC-north reference frame
    /// into the TRUE-north frame that every other part of the app (GPS course, saved
    /// coordinates, the map) uses.
    private func trueNorthAcceleration(from motion: CMDeviceMotion) -> (north: Double, east: Double, up: Double) {
        let w = referenceFrameAcceleration(from: motion)
        // A declination correction only means anything if the frame is anchored to magnetic
        // north in the first place.
        guard motionReferenceFrameIsAbsolute, magneticDeclinationDegrees != 0 else { return w }
        let d = magneticDeclinationDegrees * .pi / 180
        let c = cos(d), s = sin(d)
        // Rotate the horizontal vector by +declination (true bearing = magnetic + declination).
        return (north: w.north * c - w.east * s,
                east:  w.north * s + w.east * c,
                up:    w.up)
    }

    private func referenceFrameAcceleration(from motion: CMDeviceMotion) -> (north: Double, east: Double, up: Double) {
        let a = motion.userAcceleration
        let g = motion.gravity
        let m = motion.attitude.rotationMatrix

        // Convert gravity-free device acceleration into the motion reference frame.
        // Apple's rotation-matrix convention (R·v vs Rᵀ·v) is ambiguous, and guessing
        // wrong leaks VERTICAL motion (e.g. an elevator) into the horizontal components.
        // Resolve it at runtime: pick whichever orientation makes GRAVITY vertical —
        // that is by definition the true device→world rotation.
        let gUpCol = g.x * m.m13 + g.y * m.m23 + g.z * m.m33
        let gUpRow = g.x * m.m31 + g.y * m.m32 + g.z * m.m33

        // Core Motion's reference frame is NORTH-WEST-UP, not north-EAST-up: with X toward
        // (magnetic) north and Z up, right-handedness forces Y = Z × X = WEST. The second
        // world axis must therefore be NEGATED to obtain east. Without this every
        // dead-reckoned heading comes out mirrored about the north/south axis (a right turn
        // is drawn as a left turn). The watch implementation already accounts for this.
        // NOTE: `up` is the VERTICAL USER ACCELERATION, obtained by projecting userAcceleration
        // onto the world up axis with the same rotation used for the horizontal components.
        // It is not the gravity projection (which is a near-constant −9.81 and carries no
        // information about movement).
        let north: Double
        let west: Double
        let up: Double
        if abs(gUpCol) >= abs(gUpRow) {
            north = (a.x * m.m11 + a.y * m.m21 + a.z * m.m31) * standardGravity
            west  = (a.x * m.m12 + a.y * m.m22 + a.z * m.m32) * standardGravity
            up    = (a.x * m.m13 + a.y * m.m23 + a.z * m.m33) * standardGravity
        } else {
            north = (a.x * m.m11 + a.y * m.m12 + a.z * m.m13) * standardGravity
            west  = (a.x * m.m21 + a.y * m.m22 + a.z * m.m23) * standardGravity
            up    = (a.x * m.m31 + a.y * m.m32 + a.z * m.m33) * standardGravity
        }
        return (north, -west, up)
    }

    /// Per-sample world-frame horizontal acceleration (north, east, dt) for inertial
    /// dead reckoning. Fires at the device-motion rate so velocity can be integrated
    /// properly rather than sampled once per second.
    /// (north, east, up, rotationRateMagnitude, dt) — up and rotation rate feed the ZUPT
    /// stationarity detector.
    var onWorldAccelSample: ((Double, Double, Double, Double, TimeInterval) -> Void)?

    /// Raise the device-motion rate for accurate velocity integration while the user has
    /// forced velocity mode on; drop back to the thermal-friendly rate otherwise.
    func setHighRateMotion(_ enabled: Bool) {
        guard motionManager.isDeviceMotionActive else { return }
        let target = enabled ? 0.02 : 0.5
        if abs(motionManager.deviceMotionUpdateInterval - target) > 0.001 {
            motionManager.deviceMotionUpdateInterval = target
            print("📈 Device-motion rate → \(enabled ? "50Hz (forced velocity)" : "2Hz (normal)")")
        }
    }

    private func projectAcceleration(
        north: Double,
        east: Double,
        directionDegrees: Double?
    ) -> (forward: Double?, lateral: Double?) {
        guard let directionDegrees else {
            return (nil, nil)
        }

        let radians = directionDegrees * .pi / 180
        let forward = north * cos(radians) + east * sin(radians)
        let lateral = -north * sin(radians) + east * cos(radians)
        return (forward, lateral)
    }

    private func normalizedDegrees(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value >= 0 ? value : value + 360
    }

    // MARK: - GPS Reconnection Logic

    private func attemptReconnection() {
        guard isTracking else {
            print("   Not attempting reconnection - tracking stopped")
            return
        }

        guard reconnectionAttempts < MAX_RECONNECTION_ATTEMPTS else {
            print("❌ GPS reconnection failed - max attempts (\(MAX_RECONNECTION_ATTEMPTS)) reached")
            print("   GPS may be unavailable (indoors, poor signal, etc.)")
            return
        }

        reconnectionAttempts += 1

        // Calculate exponential backoff delay: 1s, 2s, 4s, 8s, 16s (capped at 30s)
        let delay = min(BASE_RETRY_DELAY * pow(2.0, Double(reconnectionAttempts - 1)), 30.0)

        print("🔄 Attempting GPS reconnection #\(reconnectionAttempts)/\(MAX_RECONNECTION_ATTEMPTS) in \(String(format: "%.1f", delay))s...")

        cancelReconnectionTimer()

        reconnectionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.performReconnection()
        }
    }

    private func performReconnection() {
        guard isTracking else { return }

        print("🔄 Performing GPS reconnection...")

        // Stop and restart location services
        locationManager.stopUpdatingLocation()

        // Small delay before restarting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isTracking else { return }

            print("   Restarting location updates...")
            self.locationManager.startUpdatingLocation()
            self.lastLocationUpdateTime = Date() // Reset timeout

            // If no location received after next timeout, will trigger another retry
        }
    }

    private func cancelReconnectionTimer() {
        reconnectionTimer?.invalidate()
        reconnectionTimer = nil
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        latestRawLocation = location

        // Determine location source before processing
        let source = determineLocationSource(from: location.horizontalAccuracy)

        // Log first location update
        if self.locations.isEmpty {
            print("📍 First location received!")
            print("   Source: \(source.description)")
            print("   Lat: \(String(format: "%.6f", location.coordinate.latitude)), Lon: \(String(format: "%.6f", location.coordinate.longitude))")
            print("   Accuracy: ±\(String(format: "%.1f", location.horizontalAccuracy))m")
        }

        processLocation(location)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard heading >= 0 else { return }

        // Core Motion's attitude reference frame is MAGNETIC north, but GPS course, the map,
        // and every saved coordinate are TRUE north. CLHeading reports both, so their
        // difference is the local magnetic declination — the only place we can obtain it
        // without shipping a world magnetic model. Without this correction the entire
        // dead-reckoned route is rotated by up to ~15° depending on location.
        if newHeading.trueHeading >= 0 && newHeading.magneticHeading >= 0 {
            var d = newHeading.trueHeading - newHeading.magneticHeading
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            // Declination is a smooth geographic field; reject nonsense from a bad calibration.
            if abs(d) <= 45 { magneticDeclinationDegrees = d }
        }

        currentCompassHeading = heading
        onCompassHeadingUpdate?(heading, Date())
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("❌ Location manager error: \(error.localizedDescription)")

        // Handle different error types
        if let clError = error as? CLError {
            switch clError.code {
            case .locationUnknown:
                // Temporary error - location manager is still trying
                print("   Temporary error - location unknown, continuing to search...")
                gpsSignalQuality = .poor

            case .denied:
                print("   Location access denied by user")
                gpsSignalQuality = .noSignal

            case .network:
                print("   Network-related location error")
                gpsSignalQuality = .noSignal
                // Attempt reconnection for network errors
                if isTracking {
                    attemptReconnection()
                }

            default:
                print("   Error code: \(clError.code.rawValue)")
                gpsSignalQuality = .noSignal
                // Attempt reconnection for other errors
                if isTracking {
                    attemptReconnection()
                }
            }
        } else {
            gpsSignalQuality = .noSignal
            // Attempt reconnection for unknown errors
            if isTracking {
                attemptReconnection()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let oldStatus = authorizationStatus
        authorizationStatus = manager.authorizationStatus

        if oldStatus != authorizationStatus {
            print("📍 Location permission changed: \(oldStatus.rawValue) → \(authorizationStatus.rawValue)")

            switch authorizationStatus {
            case .authorizedAlways:
                print("   ✅ Always authorized - background tracking enabled")
                locationManager.allowsBackgroundLocationUpdates = true
                locationManager.showsBackgroundLocationIndicator = true
            case .authorizedWhenInUse:
                print("   ✅ When In Use authorized - foreground tracking enabled")
                locationManager.allowsBackgroundLocationUpdates = false
                locationManager.showsBackgroundLocationIndicator = false
            case .denied:
                print("   ❌ Permission denied")
                locationManager.allowsBackgroundLocationUpdates = false
                locationManager.showsBackgroundLocationIndicator = false
            case .restricted:
                print("   ❌ Permission restricted")
                locationManager.allowsBackgroundLocationUpdates = false
                locationManager.showsBackgroundLocationIndicator = false
            case .notDetermined:
                print("   ⏳ Permission not determined")
                locationManager.allowsBackgroundLocationUpdates = false
                locationManager.showsBackgroundLocationIndicator = false
            @unknown default:
                print("   ⚠️ Unknown permission status")
            }
        }
    }
}

// MARK: - Location Source Type
enum LocationSource {
    case gps
    case wifi
    case cellular
    case hybrid
    case unknown

    var description: String {
        switch self {
        case .gps: return "GPS"
        case .wifi: return "WiFi"
        case .cellular: return "Cellular"
        case .hybrid: return "GPS+WiFi"
        case .unknown: return "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .gps: return "location.fill"
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .hybrid: return "location.fill.viewfinder"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - GPS Signal Quality
enum GPSSignalQuality {
    case unknown
    case noSignal
    case poor
    case fair
    case good
    case excellent

    var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .noSignal: return "No Signal"
        case .poor: return "Poor"
        case .fair: return "Fair"
        case .good: return "Good"
        case .excellent: return "Excellent"
        }
    }

    var color: String {
        switch self {
        case .unknown: return "gray"
        case .noSignal: return "red"
        case .poor: return "orange"
        case .fair: return "yellow"
        case .good: return "lightGreen"
        case .excellent: return "green"
        }
    }

    var barCount: Int {
        switch self {
        case .unknown, .noSignal: return 0
        case .poor: return 1
        case .fair: return 2
        case .good: return 3
        case .excellent: return 4
        }
    }
}
