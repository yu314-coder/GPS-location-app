import Foundation
import CoreLocation

class DataValidator {
    // Validation thresholds
    private let maxTimestampAge: TimeInterval = 60.0  // seconds (increased from 10 to handle GPS acquisition delays)
    private let maxHorizontalAccuracy: Double = 150.0 // meters - accept most GPS readings
    private let maxRealisticAccuracy: Double = 1000.0 // meters - very lenient upper bound
    private let maxAltitudeChangeRate: Double = 1000.0 // meters per second
    private let maxSpeed: Double = 10000.0 / 3.6        // 10000 km/h in m/s

    private var lastValidLocation: CLLocation?
    private var validLocationCount = 0

    func validateLocation(_ location: CLLocation) -> Bool {
        // Check timestamp freshness
        guard isTimestampValid(location) else {
            print("Invalid: Timestamp too old")
            return false
        }

        // Check horizontal accuracy
        guard isAccuracyValid(location) else {
            print("Invalid: Poor horizontal accuracy: \(location.horizontalAccuracy)m")
            return false
        }

        // Check coordinate bounds
        guard isCoordinateValid(location) else {
            print("Invalid: Coordinate out of bounds")
            return false
        }

        // Check speed if available
        if location.speed >= 0 {
            guard isSpeedValid(location) else {
                print("Invalid: Unrealistic speed: \(location.speed)m/s")
                return false
            }
        }

        // Check altitude change rate if we have a previous location
        if let lastLocation = lastValidLocation {
            guard isAltitudeChangeValid(location, previous: lastLocation) else {
                print("Invalid: Unrealistic altitude change")
                return false
            }
        }

        // Log successful validations (only first 5 to avoid spam)
        validLocationCount += 1
        if validLocationCount <= 5 {
            print("✅ Location VALID #\(validLocationCount): accuracy=\(String(format: "%.2f", location.horizontalAccuracy))m, age=\(String(format: "%.1f", abs(location.timestamp.timeIntervalSinceNow)))s")
        }

        // Location is valid
        lastValidLocation = location
        return true
    }

    private func isTimestampValid(_ location: CLLocation) -> Bool {
        let age = abs(location.timestamp.timeIntervalSinceNow)
        return age <= maxTimestampAge
    }

    private func isAccuracyValid(_ location: CLLocation) -> Bool {
        let accuracy = location.horizontalAccuracy

        // Negative accuracy means invalid
        if accuracy < 0 {
            return false
        }

        // Check if accuracy exceeds realistic upper bound
        // Note: Very low accuracy (< 1m) is EXCELLENT, not invalid!
        if accuracy > maxRealisticAccuracy {
            return false
        }

        // Accept any reasonable accuracy
        return accuracy <= maxHorizontalAccuracy
    }

    private func isCoordinateValid(_ location: CLLocation) -> Bool {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        // Check latitude bounds (-90 to 90)
        guard lat >= -90 && lat <= 90 else {
            return false
        }

        // Check longitude bounds (-180 to 180)
        guard lon >= -180 && lon <= 180 else {
            return false
        }

        return true
    }

    private func isSpeedValid(_ location: CLLocation) -> Bool {
        return location.speed <= maxSpeed
    }

    private func isAltitudeChangeValid(_ location: CLLocation, previous: CLLocation) -> Bool {
        let altitudeDelta = abs(location.altitude - previous.altitude)
        let timeDelta = location.timestamp.timeIntervalSince(previous.timestamp)

        guard timeDelta > 0 else {
            return true
        }

        // For GPS readings coming quickly (< 2 seconds apart), be very lenient
        // GPS altitude can have significant noise, especially indoors or with poor signal
        if timeDelta < 2.0 {
            // Allow up to 100m change for readings < 2s apart (GPS noise tolerance)
            return altitudeDelta <= 100.0
        }

        // For longer intervals, use rate-based validation
        let altitudeChangeRate = altitudeDelta / timeDelta
        return altitudeChangeRate <= maxAltitudeChangeRate
    }

    func reset() {
        lastValidLocation = nil
        validLocationCount = 0
    }
}
