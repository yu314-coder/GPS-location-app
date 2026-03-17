import Foundation
import CoreLocation
import CoreMotion
import Combine

class LocationManager: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    private let kalmanFilter = KalmanFilterEngine()
    private let dataValidator = DataValidator()
    private let altimeter = CMAltimeter()

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus
    @Published var isTracking = false
    @Published var locations: [FlightLocation] = []
    @Published var gpsSignalQuality: GPSSignalQuality = .unknown
    @Published var locationSource: LocationSource = .unknown
    @Published var currentPressure: Double? // in kilopascals (kPa)

    var onLocationUpdate: ((FlightLocation) -> Void)?

    // Pressure tracking
    private var latestPressure: Double?

    // GPS reconnection logic
    private var gpsTimeoutTimer: Timer?
    private var reconnectionTimer: Timer?
    private var forceNetworkTimer: Timer?
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
    private let FORCE_NETWORK_RESTART_INTERVAL: TimeInterval = 15.0 // Keep network location alive during fallback

    override init() {
        self.authorizationStatus = locationManager.authorizationStatus
        super.init()
        setupLocationManager()
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone

        // Request maximum update frequency (approximately 0.1s intervals)
        if #available(watchOS 8.0, *) {
            locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        }

        // Activity type for workout tracking
        locationManager.activityType = .fitness

        // CRITICAL: Enable background location updates for cellular/WiFi positioning
        // This allows the watch to use cellular and WiFi when GPS is unavailable
        if #available(watchOS 4.0, *) {
            locationManager.allowsBackgroundLocationUpdates = true
            print("⌚ ✅ Enabled background location updates for cellular/WiFi positioning")
        }

        // pausesLocationUpdatesAutomatically and showsBackgroundLocationIndicator are not available on watchOS
        print("⌚ Location manager configured for workout tracking with fitness activity type")
    }

    func requestAuthorization() {
        // watchOS: Request location permission
        // Note: watchOS doesn't have the same "When In Use" vs "Always" distinction as iOS
        let status = locationManager.authorizationStatus

        if status == .notDetermined {
            print("📍 Requesting location permission on Watch...")
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            print("✅ Location permission already granted on Watch")
        } else {
            print("❌ Location permission denied or restricted on Watch")
        }
    }

    func startTracking() {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            print("Location permission not granted")
            return
        }

        isTracking = true
        locationManager.startUpdatingLocation()

        // Reset reconnection state when starting fresh
        reconnectionAttempts = 0
        lastLocationUpdateTime = Date()
        lastValidLocationTime = Date()
        recoveryModeActivated = false

        // Start GPS timeout monitoring
        startGPSTimeoutMonitoring()

        // Start pressure tracking
        startPressureTracking()

        print("⌚ Started GPS tracking with WiFi/Cellular fallback")
        print("   Desired accuracy: Best for Navigation (GPS)")
        print("   Fallback: WiFi/Cellular positioning after 10s timeout")
        print("   GPS timeout monitoring: Active (5s timeout)")
    }

    func stopTracking() {
        isTracking = false
        locationManager.stopUpdatingLocation()

        // Clean up timers
        stopGPSTimeoutMonitoring()
        cancelReconnectionTimer()
        stopForceNetworkUpdates()
        recoveryModeActivated = false
        lastValidLocationTime = nil
        locationManager.activityType = .fitness

        // Reset fallback mode
        isFallbackModeActive = false
        fallbackModeStartTime = nil
        stopForceNetworkUpdates()

        // Stop pressure tracking
        stopPressureTracking()

        // Restore high accuracy mode for next session
        if #available(watchOS 8.0, *) {
            locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        } else {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
        }

        print("⌚ Stopped GPS tracking and timeout monitoring")
    }

    private func processLocation(_ rawLocation: CLLocation) {
        let (processedLocation, isFiltered) = processLocationForTracking(rawLocation)
        let isValid = dataValidator.validateLocation(processedLocation)

        // Determine and log location source for diagnostics
        let source = determineLocationSource(from: processedLocation.horizontalAccuracy)

        // Log location source changes (especially for cellular/WiFi fallback debugging)
        if source != locationSource {
            print("⌚ 📡 Location source changed: \(locationSource.description) → \(source.description)")
            print("   Accuracy: ±\(String(format: "%.1f", processedLocation.horizontalAccuracy))m")
            if source == .cellular || source == .wifi {
                print("   ✅ Using \(source.description) positioning (GPS unavailable)")
            }
        }

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
            print("⌚ ✅ GPS connection restored after \(reconnectionAttempts) reconnection attempts")
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

            // Call the callback to notify WorkoutSession (can be on background thread)
            onLocationUpdate?(flightLocation)
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
        kalmanFilter.reset()
        stopGPSTimeoutMonitoring()
        cancelReconnectionTimer()
        stopForceNetworkUpdates()
        reconnectionAttempts = 0
        lastLocationUpdateTime = nil
        lastValidLocationTime = nil

        // Reset fallback mode
        isFallbackModeActive = false
        fallbackModeStartTime = nil
        stopForceNetworkUpdates()
    }

    func updateActivityType(_ activityType: CLActivityType) {
        locationManager.activityType = activityType
        print("⌚ Activity type set to \(activityType)")
    }

    func refreshCellularFallback() {
        guard isTracking else {
            print("⌚ ⚠️ Cannot refresh cellular fallback - tracking is not active")
            return
        }

        print("⌚ 📡 Manual cellular/WiFi refresh requested")

        if !isFallbackModeActive {
            activateFallbackMode()
            return
        }

        fallbackModeStartTime = Date()
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        startForceNetworkUpdates()

        locationManager.stopUpdatingLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.isTracking else { return }
            self.locationManager.startUpdatingLocation()
            self.lastLocationUpdateTime = Date()
            print("⌚ ✅ Manual cellular/WiFi refresh complete")
        }
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
        print("⌚ ⚠️ GPS timeout detected - no updates for \(String(format: "%.1f", timeSinceLastUpdate))s")

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

        print("⌚ 🚨 No GPS fix for 60s - switching activity type to airborne")
        locationManager.activityType = .airborne
    }

    // MARK: - WiFi/Cellular Fallback Logic

    private func activateFallbackMode() {
        guard !isFallbackModeActive else { return }
        isFallbackModeActive = true
        fallbackModeStartTime = Date()

        print("⌚ 📡 Activating WiFi/Cellular fallback mode")
        print("   GPS signal weak or unavailable - using alternative positioning")
        print("   📶 Cellular data will be used if WiFi unavailable")
        print("   📱 If watch signal fails, will request iPhone GPS")

        // Switch to lower accuracy mode which enables WiFi and Cellular positioning
        // kCLLocationAccuracyHundredMeters enables WiFi/Cellular positioning
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        // Restart location updates to apply new accuracy settings
        locationManager.stopUpdatingLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isTracking else { return }
            self.locationManager.startUpdatingLocation()
            print("   ✅ Fallback mode active - will use WiFi/Cellular/iPhone positioning")
            self.startForceNetworkUpdates()
        }
    }

    private func deactivateFallbackMode() {
        guard isFallbackModeActive else { return }
        isFallbackModeActive = false
        fallbackModeStartTime = nil
        stopForceNetworkUpdates()

        print("⌚ 🛰️ Deactivating fallback mode - GPS signal restored")
        print("   Switching back to high-accuracy GPS positioning")

        // Switch back to high accuracy GPS mode
        if #available(watchOS 8.0, *) {
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

    private func startForceNetworkUpdates() {
        stopForceNetworkUpdates()
        forceNetworkTimer = Timer.scheduledTimer(withTimeInterval: FORCE_NETWORK_RESTART_INTERVAL, repeats: true) { [weak self] _ in
            guard let self = self, self.isTracking, self.isFallbackModeActive else { return }
            print("⌚ 🔄 Keeping network location active (fallback mode)")
            self.locationManager.stopUpdatingLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard self.isTracking, self.isFallbackModeActive else { return }
                self.locationManager.startUpdatingLocation()
            }
        }
    }

    private func stopForceNetworkUpdates() {
        forceNetworkTimer?.invalidate()
        forceNetworkTimer = nil
    }

    // MARK: - Pressure Tracking

    private func startPressureTracking() {
        // Check if relative altitude (barometric pressure) is available
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            print("⌚ ⚠️ Barometric pressure sensor not available on this device")
            return
        }

        print("⌚ 🌡️ Starting barometric pressure tracking")

        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] (altitudeData, error) in
            guard let self = self else { return }

            if let error = error {
                print("⌚ ❌ Altimeter error: \(error.localizedDescription)")
                return
            }

            guard let data = altitudeData else { return }

            // Convert pressure from kPa to hPa (hectopascals/millibars) for display
            // CMAltitudeData.pressure is in kilopascals (kPa)
            let pressureKPa = data.pressure.doubleValue

            self.latestPressure = pressureKPa

            DispatchQueue.main.async {
                self.currentPressure = pressureKPa
            }
        }
    }

    private func stopPressureTracking() {
        altimeter.stopRelativeAltitudeUpdates()
        latestPressure = nil
        DispatchQueue.main.async { [weak self] in
            self?.currentPressure = nil
        }
        print("⌚ 🌡️ Stopped barometric pressure tracking")
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

        // Determine location source before processing
        let source = determineLocationSource(from: location.horizontalAccuracy)

        // Log first location update
        if self.locations.isEmpty {
            print("⌚ 📍 First location received!")
            print("   Source: \(source.description)")
            print("   Lat: \(String(format: "%.6f", location.coordinate.latitude)), Lon: \(String(format: "%.6f", location.coordinate.longitude))")
            print("   Accuracy: ±\(String(format: "%.1f", location.horizontalAccuracy))m")
        }

        processLocation(location)
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
        authorizationStatus = manager.authorizationStatus
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
