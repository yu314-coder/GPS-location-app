import Foundation
import os.log

class AppLogger {
    static let shared = AppLogger()

    private let subsystem = Bundle.main.bundleIdentifier ?? "com.flightgps"

    // Log categories
    private lazy var locationLog = OSLog(subsystem: subsystem, category: "Location")
    private lazy var healthKitLog = OSLog(subsystem: subsystem, category: "HealthKit")
    private lazy var workoutLog = OSLog(subsystem: subsystem, category: "Workout")
    private lazy var kalmanLog = OSLog(subsystem: subsystem, category: "Kalman")
    private lazy var validationLog = OSLog(subsystem: subsystem, category: "Validation")
    private lazy var generalLog = OSLog(subsystem: subsystem, category: "General")

    private init() {}

    // MARK: - Location Logging

    func logLocation(_ message: String, type: OSLogType = .info) {
        os_log("%{public}@", log: locationLog, type: type, message)
    }

    func logLocationUpdate(_ location: FlightLocation) {
        let message = """
        Location Update:
        - Coordinate: (\(location.latitude), \(location.longitude))
        - Altitude: \(location.altitude)m
        - Accuracy: ±\(location.horizontalAccuracy)m
        - Speed: \(location.speed)m/s
        - Valid: \(location.isValid)
        - Filtered: \(location.isFiltered)
        """
        os_log("%{public}@", log: locationLog, type: .debug, message)
    }

    func logGPSSignalQuality(_ quality: GPSSignalQuality, accuracy: Double?) {
        let accuracyStr = accuracy != nil ? String(format: "±%.1fm", accuracy!) : "N/A"
        os_log("GPS Signal: %{public}@ | Accuracy: %{public}@",
               log: locationLog,
               type: .info,
               quality.description,
               accuracyStr)
    }

    // MARK: - HealthKit Logging

    func logHealthKit(_ message: String, type: OSLogType = .info) {
        os_log("%{public}@", log: healthKitLog, type: type, message)
    }

    func logWorkoutSave(success: Bool, distance: Double, duration: TimeInterval) {
        let message = """
        Workout Save: \(success ? "SUCCESS" : "FAILED")
        - Distance: \(distance / 1000.0)km
        - Duration: \(duration)s
        """
        os_log("%{public}@", log: healthKitLog, type: success ? .info : .error, message)
    }

    // MARK: - Workout Logging

    func logWorkout(_ message: String, type: OSLogType = .info) {
        os_log("%{public}@", log: workoutLog, type: type, message)
    }

    func logWorkoutStart() {
        os_log("Workout session started", log: workoutLog, type: .info)
    }

    func logWorkoutEnd(duration: TimeInterval, distance: Double) {
        os_log("Workout session ended - Duration: %{public}.1fs, Distance: %{public}.1fkm",
               log: workoutLog,
               type: .info,
               duration,
               distance / 1000.0)
    }

    // MARK: - Kalman Filter Logging

    func logKalman(_ message: String, type: OSLogType = .debug) {
        os_log("%{public}@", log: kalmanLog, type: type, message)
    }

    func logKalmanFilter(raw: (lat: Double, lon: Double),
                        filtered: (lat: Double, lon: Double),
                        gain: Double) {
        os_log("Kalman Filter - Raw: (%{public}.6f, %{public}.6f) -> Filtered: (%{public}.6f, %{public}.6f) | Gain: %{public}.4f",
               log: kalmanLog,
               type: .debug,
               raw.lat, raw.lon,
               filtered.lat, filtered.lon,
               gain)
    }

    // MARK: - Validation Logging

    func logValidation(_ message: String, type: OSLogType = .debug) {
        os_log("%{public}@", log: validationLog, type: type, message)
    }

    func logValidationResult(valid: Bool, reason: String) {
        let status = valid ? "VALID" : "INVALID"
        os_log("Validation: %{public}@ - %{public}@",
               log: validationLog,
               type: valid ? .debug : .info,
               status,
               reason)
    }

    // MARK: - General Logging

    func log(_ message: String, type: OSLogType = .info) {
        os_log("%{public}@", log: generalLog, type: type, message)
    }

    func logError(_ error: Error, context: String = "") {
        let message = context.isEmpty ? error.localizedDescription : "\(context): \(error.localizedDescription)"
        os_log("%{public}@", log: generalLog, type: .error, message)
    }

    func logDebug(_ message: String) {
        #if DEBUG
        os_log("%{public}@", log: generalLog, type: .debug, message)
        #endif
    }

    // MARK: - Performance Logging

    func measurePerformance(name: String, block: () -> Void) {
        let start = Date()
        block()
        let duration = Date().timeIntervalSince(start)
        os_log("Performance - %{public}@: %{public}.4fs",
               log: generalLog,
               type: .debug,
               name,
               duration)
    }
}

// MARK: - Convenience Methods

extension AppLogger {
    /// Log location manager events
    func logLocationManagerEvent(_ event: String) {
        logLocation("LocationManager: \(event)")
    }

    /// Log filter application
    func logFilterApplication(before: Double, after: Double, improvement: Double) {
        logKalman("Filter applied - Before: ±\(before)m, After: ±\(after)m, Improvement: \(improvement)%")
    }

    /// Log metrics update
    func logMetricsUpdate(distance: Double, speed: Double, altitude: Double) {
        logWorkout("Metrics - Distance: \(distance / 1000.0)km, Speed: \(speed * 3.6)km/h, Altitude: \(altitude)m")
    }
}
