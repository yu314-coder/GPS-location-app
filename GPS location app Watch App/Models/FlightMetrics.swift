import Foundation
import CoreLocation

// Speed sample for history tracking
struct SpeedSample: Codable {
    let timestamp: Date
    let speed: Double  // in m/s
}

// Altitude sample for history tracking
struct AltitudeSample: Codable {
    let timestamp: Date
    let altitude: Double  // in meters
}

// Pressure sample for history tracking
struct PressureSample: Codable {
    let timestamp: Date
    let pressure: Double  // in kilopascals (kPa)
}

struct FlightMetrics: Codable {
    // Distance metrics
    var totalDistance: Double = 0.0  // in meters

    // Speed metrics
    var averageSpeed: Double = 0.0   // in m/s
    var maxSpeed: Double = 0.0       // in m/s
    var currentSpeed: Double = 0.0   // in m/s (instantaneous)
    var smoothedSpeed: Double = 0.0  // in m/s (exponentially smoothed)

    // Altitude metrics
    var maxAltitude: Double = 0.0    // in meters
    var minAltitude: Double = 0.0    // in meters
    var currentAltitude: Double = 0.0 // in meters
    var totalAltitudeGain: Double = 0.0
    var totalAltitudeLoss: Double = 0.0

    // Atmospheric data
    var currentPressure: Double? = nil  // in kilopascals (kPa)

    // Time metrics
    var duration: TimeInterval = 0.0  // in seconds

    // Energy
    var caloriesBurned: Double = 0.0
    var restingEnergyBurned: Double = 0.0

    // Steps count (from pedometer)
    var stepsCount: Double? = nil
    var nativeStepDistance: Double? = nil  // meters from CMPedometerData.distance

    // Heart rate metrics
    var currentHeartRate: Double? = nil      // bpm
    var averageHeartRate: Double? = nil      // bpm
    var maxHeartRate: Double? = nil          // bpm
    var minHeartRate: Double? = nil          // bpm
    private var heartRateSamples: [Double] = []

    // Speed history for graphing
    var speedHistory: [SpeedSample] = []
    var tenSecondAverageSpeed: Double = 0.0  // 10-second rolling average in m/s

    // Altitude history for graphing
    var altitudeHistory: [AltitudeSample] = []

    // Pressure history for graphing
    var pressureHistory: [PressureSample] = []

    // Splits (per kilometer)
    var splits: [Split] = []
    private var currentSplitDistance: Double = 0.0
    private var currentSplitStartTime: Date?

    // GPS quality metrics
    var totalPoints: Int = 0
    var validPoints: Int = 0
    var averageAccuracy: Double = 0.0
    var signalCoverage: Double = 0.0  // percentage

    // Computed properties
    var distanceInKilometers: Double {
        return totalDistance / 1000.0
    }

    var distanceInMiles: Double {
        return totalDistance / 1609.34
    }

    var averageSpeedKmh: Double {
        return averageSpeed * 3.6
    }

    var averageSpeedMph: Double {
        return averageSpeed * 2.23694
    }

    var maxSpeedKmh: Double {
        return maxSpeed * 3.6
    }

    var maxSpeedMph: Double {
        return maxSpeed * 2.23694
    }

    var tenSecondAverageSpeedKmh: Double {
        return tenSecondAverageSpeed * 3.6
    }

    var averagePace: Double {
        guard averageSpeed > 0 else { return 0 }
        return 1.0 / averageSpeed  // seconds per meter
    }

    // MARK: - Pace Calculations (for running/cycling apps)

    /// Current pace in seconds per kilometer
    var currentPacePerKm: TimeInterval {
        guard currentSpeed > 0 else { return 0 }
        return 1000.0 / currentSpeed  // seconds per km
    }

    /// Average pace in seconds per kilometer
    var averagePacePerKm: TimeInterval {
        guard averageSpeed > 0 else { return 0 }
        return 1000.0 / averageSpeed  // seconds per km
    }

    /// Formatted current pace string (e.g., "5:23 /km")
    var formattedCurrentPace: String {
        guard currentPacePerKm > 0 && currentPacePerKm < 3600 else { return "--:-- /km" }
        let minutes = Int(currentPacePerKm) / 60
        let seconds = Int(currentPacePerKm) % 60
        return String(format: "%d:%02d /km", minutes, seconds)
    }

    /// Formatted average pace string (e.g., "5:23 /km")
    var formattedAveragePace: String {
        guard averagePacePerKm > 0 && averagePacePerKm < 3600 else { return "--:-- /km" }
        let minutes = Int(averagePacePerKm) / 60
        let seconds = Int(averagePacePerKm) % 60
        return String(format: "%d:%02d /km", minutes, seconds)
    }

    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    mutating func updateWithLocation(_ location: FlightLocation, previousLocation: FlightLocation?, elapsedTime: TimeInterval = 0) {
        totalPoints += 1
        if location.isValid {
            validPoints += 1
        }

        // Update current altitude
        currentAltitude = location.altitude

        // Update distance and altitude gain/loss
        if let previous = previousLocation {
            let distance = location.distance(to: previous)
            totalDistance += distance

            // Performance: Reduce distance logging to every 50 points (matches summary logging)
            if totalPoints % 50 == 0 {
                print("📏 Distance: +\(String(format: "%.2f", distance))m → Total: \(String(format: "%.2f", totalDistance))m (\(String(format: "%.3f", totalDistance/1000))km)")
            }

            let altitudeDelta = location.altitude - previous.altitude
            if altitudeDelta > 0 {
                totalAltitudeGain += altitudeDelta
            } else {
                totalAltitudeLoss += abs(altitudeDelta)
            }

            // Calculate instantaneous speed (m/s) from distance between points
            let timeDelta = location.timestamp.timeIntervalSince(previous.timestamp)
            if timeDelta > 0 && distance > 0 {
                currentSpeed = distance / timeDelta
            }

            // Apply Exponential Moving Average (EMA) for smooth speed
            // α = 0.3 provides good balance between responsiveness and smoothing
            // Based on research: https://makeabilitylab.github.io/physcomp/advancedio/smoothing-input.html
            let alpha: Double = 0.3
            if smoothedSpeed == 0.0 {
                // Initialize with first valid speed
                smoothedSpeed = currentSpeed
            } else {
                // EMA formula: EMA = α × current + (1 - α) × previous_EMA
                smoothedSpeed = alpha * currentSpeed + (1.0 - alpha) * smoothedSpeed
            }
        } else {
            currentSpeed = 0.0
            smoothedSpeed = 0.0
        }

        // Update max speed using ACTUAL instantaneous speed (not smoothed)
        // IMPORTANT: Use currentSpeed to capture true peak performance
        // Smoothed speed (α=0.3) misses peaks because: smoothed = 0.3*current + 0.7*previous
        // Example: 30 km/h burst → smoothed only reaches ~18 km/h
        if currentSpeed > maxSpeed {
            maxSpeed = currentSpeed
        }

        // Add smoothed speed to history (not raw instantaneous speed)
        // This creates cleaner graphs and more accurate 10-second averages
        let sample = SpeedSample(timestamp: location.timestamp, speed: smoothedSpeed)
        speedHistory.append(sample)

        // Add to altitude history
        let altitudeSample = AltitudeSample(timestamp: location.timestamp, altitude: location.altitude)
        altitudeHistory.append(altitudeSample)

        // Add to pressure history (if available)
        if let pressure = location.pressure {
            let pressureSample = PressureSample(timestamp: location.timestamp, pressure: pressure)
            pressureHistory.append(pressureSample)
        }

        // Calculate 10-second rolling average from smoothed speeds
        let tenSecondsAgo = location.timestamp.addingTimeInterval(-10.0)
        let recentSamples = speedHistory.filter { $0.timestamp >= tenSecondsAgo }
        if !recentSamples.isEmpty {
            tenSecondAverageSpeed = recentSamples.map { $0.speed }.reduce(0, +) / Double(recentSamples.count)
        }

        // Update overall average speed during workout
        if elapsedTime > 0 {
            averageSpeed = totalDistance / elapsedTime
        }

        if location.altitude > maxAltitude {
            maxAltitude = location.altitude
        }

        if minAltitude == 0 || location.altitude < minAltitude {
            minAltitude = location.altitude
        }

        // Update average accuracy
        averageAccuracy = (averageAccuracy * Double(totalPoints - 1) + location.horizontalAccuracy) / Double(totalPoints)

        // Update signal coverage
        if location.isValid {
            signalCoverage = (Double(validPoints) / Double(totalPoints)) * 100.0
        }
    }

    mutating func calculateAverages(duration: TimeInterval) {
        self.duration = duration
        if duration > 0 {
            averageSpeed = totalDistance / duration
        }
    }

    mutating func estimateCalories(duration: TimeInterval, userWeight: Double = 70.0) {
        // Rough estimation: ~0.5-1.0 calories per minute during flight
        let minutes = duration / 60.0
        caloriesBurned = minutes * 0.75
    }

    // MARK: - Heart Rate Updates

    mutating func updateWithHeartRate(_ heartRate: Double) {
        currentHeartRate = heartRate
        heartRateSamples.append(heartRate)

        // Update max and min
        if let max = maxHeartRate {
            maxHeartRate = Swift.max(max, heartRate)
        } else {
            maxHeartRate = heartRate
        }

        if let min = minHeartRate {
            minHeartRate = Swift.min(min, heartRate)
        } else {
            minHeartRate = heartRate
        }

        // Calculate average
        if !heartRateSamples.isEmpty {
            averageHeartRate = heartRateSamples.reduce(0, +) / Double(heartRateSamples.count)
        }
    }

    // MARK: - Splits Management

    mutating func updateSplits(startDate: Date?) {
        // Check if we've completed a kilometer
        let splitDistance: Double = 1000.0 // 1 km in meters
        let newDistance = totalDistance - currentSplitDistance

        if newDistance >= splitDistance {
            // Create a split for each completed kilometer
            let completedKilometers = Int(newDistance / splitDistance)

            for _ in 0..<completedKilometers {
                let splitNumber = splits.count + 1
                let split = Split(
                    number: splitNumber,
                    distance: splitDistance,
                    duration: 0, // Will be calculated from timestamps
                    averageSpeed: averageSpeed,
                    averageHeartRate: currentHeartRate,
                    timestamp: Date()
                )
                splits.append(split)
                currentSplitDistance += splitDistance
            }
        }
    }

    mutating func finalizeSplits() {
        // Add final partial split if there's remaining distance
        let remainingDistance = totalDistance - currentSplitDistance
        if remainingDistance > 0 {
            let splitNumber = splits.count + 1
            let split = Split(
                number: splitNumber,
                distance: remainingDistance,
                duration: 0,
                averageSpeed: averageSpeed,
                averageHeartRate: currentHeartRate,
                timestamp: Date()
            )
            splits.append(split)
        }
    }
}

// MARK: - Split Model

struct Split: Codable, Identifiable {
    var id = UUID()
    let number: Int
    let distance: Double          // in meters
    let duration: TimeInterval    // in seconds
    let averageSpeed: Double      // in m/s
    let averageHeartRate: Double? // bpm
    let timestamp: Date

    var pacePerKm: TimeInterval {
        guard distance > 0 else { return 0 }
        return (duration / distance) * 1000.0  // seconds per km
    }

    var formattedPace: String {
        let pace = pacePerKm
        let minutes = Int(pace) / 60
        let seconds = Int(pace) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedDistance: String {
        let km = distance / 1000.0
        return String(format: "%.2f km", km)
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
