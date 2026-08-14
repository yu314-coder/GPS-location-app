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

// Acceleration sample for history tracking
struct AccelerationSample: Codable {
    let timestamp: Date
    let acceleration: Double  // in m/s²
}

// Device-motion acceleration sample for history tracking
struct MotionAccelerationSample: Codable {
    let timestamp: Date
    let acceleration: Double  // in m/s², gravity removed
    let x: Double?
    let y: Double?
    let z: Double?
}

struct AttitudeSample: Codable {
    let timestamp: Date
    let pitch: Double  // degrees
    let roll: Double   // degrees
    let yaw: Double    // degrees
}

struct RotationRateSample: Codable {
    let timestamp: Date
    let x: Double      // rad/s
    let y: Double      // rad/s
    let z: Double      // rad/s
    let magnitude: Double
}

struct HeadingSample: Codable {
    let timestamp: Date
    let heading: Double  // degrees, 0...360
}

// Barometric altitude sample for history tracking
struct BarometricAltitudeSample: Codable {
    let timestamp: Date
    let relativeAltitude: Double  // in meters from the workout start reference
    let verticalSpeed: Double?    // in m/s
}

// GPS quality sample for history tracking
struct GPSQualitySample: Codable {
    let timestamp: Date
    let score: Double             // 0...100
    let horizontalAccuracy: Double
}

struct FlightMetrics: Codable {
    private static let liveHistoryLimit = 180

    // Distance metrics
    var totalDistance: Double = 0.0  // in meters

    // Speed metrics
    var averageSpeed: Double = 0.0   // in m/s
    var maxSpeed: Double = 0.0       // in m/s
    var currentSpeed: Double = 0.0   // in m/s (instantaneous)
    var smoothedSpeed: Double = 0.0  // in m/s (exponentially smoothed)

    // Acceleration metrics. Optional for backward-compatible decoding of older saved workouts.
    var currentAcceleration: Double? = nil  // in m/s²
    var maxAcceleration: Double? = nil      // peak positive acceleration in m/s²
    var maxDeceleration: Double? = nil      // peak negative acceleration in m/s²
    var averageAcceleration: Double? = nil  // average absolute acceleration in m/s²

    // Device-motion acceleration metrics. These are recorded only and do not affect movement detection.
    var currentMotionAcceleration: Double? = nil
    var maxMotionAcceleration: Double? = nil
    var averageMotionAcceleration: Double? = nil
    var currentMotionAccelerationX: Double? = nil
    var currentMotionAccelerationY: Double? = nil
    var currentMotionAccelerationZ: Double? = nil

    // Device orientation and rotation metrics.
    var currentPitch: Double? = nil
    var currentRoll: Double? = nil
    var currentYaw: Double? = nil
    var currentRotationRate: Double? = nil
    var maxRotationRate: Double? = nil
    var currentRotationRateX: Double? = nil
    var currentRotationRateY: Double? = nil
    var currentRotationRateZ: Double? = nil

    // Compass heading independent of GPS course when available.
    var currentCompassHeading: Double? = nil

    // Altitude metrics
    var maxAltitude: Double = 0.0    // in meters
    var minAltitude: Double = 0.0    // in meters
    var currentAltitude: Double = 0.0 // in meters
    var totalAltitudeGain: Double = 0.0
    var totalAltitudeLoss: Double = 0.0

    // Barometer-derived climb/descent metrics. Optional for old saved workouts.
    var currentBarometricRelativeAltitude: Double? = nil
    var maxBarometricRelativeAltitude: Double? = nil
    var minBarometricRelativeAltitude: Double? = nil
    var barometricAltitudeGain: Double? = nil
    var barometricAltitudeLoss: Double? = nil
    var currentVerticalSpeed: Double? = nil
    var maxClimbRate: Double? = nil
    var maxDescentRate: Double? = nil
    var averageVerticalSpeed: Double? = nil

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

    // Acceleration history for graphing
    var accelerationHistory: [AccelerationSample]? = nil
    var motionAccelerationHistory: [MotionAccelerationSample]? = nil
    var attitudeHistory: [AttitudeSample]? = nil
    var rotationRateHistory: [RotationRateSample]? = nil
    var compassHeadingHistory: [HeadingSample]? = nil

    // Altitude history for graphing
    var altitudeHistory: [AltitudeSample] = []
    var barometricAltitudeHistory: [BarometricAltitudeSample]? = nil

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
    var currentGPSQualityScore: Double? = nil
    var averageGPSQualityScore: Double? = nil
    var bestGPSQualityScore: Double? = nil
    var worstGPSQualityScore: Double? = nil
    var gpsQualityHistory: [GPSQualitySample]? = nil

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

    var currentAccelerationKmhPerSecond: Double {
        return (currentAcceleration ?? 0) * 3.6
    }

    var maxAccelerationKmhPerSecond: Double {
        return (maxAcceleration ?? 0) * 3.6
    }

    var maxDecelerationKmhPerSecond: Double {
        return (maxDeceleration ?? 0) * 3.6
    }

    var averageAccelerationKmhPerSecond: Double {
        return (averageAcceleration ?? 0) * 3.6
    }

    var currentVerticalSpeedMetersPerMinute: Double {
        return (currentVerticalSpeed ?? 0) * 60.0
    }

    var maxClimbRateMetersPerMinute: Double {
        return (maxClimbRate ?? 0) * 60.0
    }

    var maxDescentRateMetersPerMinute: Double {
        return (maxDescentRate ?? 0) * 60.0
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

    var healthKitSensorMetadata: [String: Double] {
        var metadata: [String: Double] = [:]
        metadata["com.exmstc.gps.acceleration.max"] = maxAcceleration ?? 0
        metadata["com.exmstc.gps.acceleration.maxDeceleration"] = maxDeceleration ?? 0
        metadata["com.exmstc.gps.acceleration.averageAbs"] = averageAcceleration ?? 0
        metadata["com.exmstc.gps.motionAcceleration.current"] = currentMotionAcceleration ?? 0
        metadata["com.exmstc.gps.motionAcceleration.max"] = maxMotionAcceleration ?? 0
        metadata["com.exmstc.gps.motionAcceleration.average"] = averageMotionAcceleration ?? 0
        return metadata
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
            let previousSpeed = currentSpeed
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
            // A speed derived from two points a few milliseconds apart is a division
            // artifact, not a measurement (see iPhone: a 1.6 km/h walk reported a max speed of
            // 1416.2 km/h). Below this gap the pair says nothing about speed.
            // A step inside the noise is not a speed — see the iPhone. Two fixes 17.9 m apart
            // with 17 m accuracy each read as 9 m/s and gave a 4.2 km/h walk a 33 km/h maximum.
            let combinedUncertainty = max(location.horizontalAccuracy, 0) + max(previous.horizontalAccuracy, 0)
            let movementIsResolvable = distance >= combinedUncertainty * 0.5
            if timeDelta >= 0.2 && distance > 0 && movementIsResolvable {
                currentSpeed = distance / timeDelta
            }

            if timeDelta > 0.5 {
                let acceleration = (currentSpeed - previousSpeed) / timeDelta
                currentAcceleration = acceleration
                if acceleration > 0 {
                    maxAcceleration = max(maxAcceleration ?? acceleration, acceleration)
                } else if acceleration < 0 {
                    maxDeceleration = min(maxDeceleration ?? acceleration, acceleration)
                }

                var history = accelerationHistory ?? []
                history.append(AccelerationSample(timestamp: location.timestamp, acceleration: acceleration))
                Self.trimHistory(&history)
                accelerationHistory = history
                let previousAverage = averageAcceleration ?? abs(acceleration)
                averageAcceleration = previousAverage + ((abs(acceleration) - previousAverage) / Double(totalPoints))
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
            currentAcceleration = 0.0
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
        Self.trimHistory(&speedHistory)

        // Add to altitude history
        let altitudeSample = AltitudeSample(timestamp: location.timestamp, altitude: location.altitude)
        altitudeHistory.append(altitudeSample)
        Self.trimHistory(&altitudeHistory)

        // Add to pressure history (if available)
        if let pressure = location.pressure {
            let pressureSample = PressureSample(timestamp: location.timestamp, pressure: pressure)
            pressureHistory.append(pressureSample)
            Self.trimHistory(&pressureHistory)
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

        updateGPSQuality(with: location)
    }

    mutating func updateWithMotionAcceleration(
        _ acceleration: Double,
        x: Double? = nil,
        y: Double? = nil,
        z: Double? = nil,
        pitch: Double? = nil,
        roll: Double? = nil,
        yaw: Double? = nil,
        rotationRateX: Double? = nil,
        rotationRateY: Double? = nil,
        rotationRateZ: Double? = nil,
        heading: Double? = nil,
        timestamp: Date = Date()
    ) {
        currentMotionAcceleration = acceleration
        maxMotionAcceleration = max(maxMotionAcceleration ?? acceleration, acceleration)
        currentMotionAccelerationX = x
        currentMotionAccelerationY = y
        currentMotionAccelerationZ = z

        let previousAverage = averageMotionAcceleration ?? acceleration
        let sampleCount = Double(totalPoints + 1)
        averageMotionAcceleration = previousAverage + ((acceleration - previousAverage) / max(1, sampleCount))

        // Keep current attitude/rotation for the live display, but DO NOT record
        // pitch/roll/yaw or rotation-rate histories — accumulating these arrays
        // bloats the data and overheats the device.
        if let pitch, let roll, let yaw {
            currentPitch = pitch
            currentRoll = roll
            currentYaw = yaw
        }

        if let rotationRateX, let rotationRateY, let rotationRateZ {
            let magnitude = sqrt(rotationRateX * rotationRateX + rotationRateY * rotationRateY + rotationRateZ * rotationRateZ)
            currentRotationRate = magnitude
            maxRotationRate = max(maxRotationRate ?? magnitude, magnitude)
            currentRotationRateX = rotationRateX
            currentRotationRateY = rotationRateY
            currentRotationRateZ = rotationRateZ
        }

        if let heading {
            updateWithCompassHeading(heading, timestamp: timestamp)
        }
    }

    mutating func updateWithCompassHeading(_ heading: Double, timestamp: Date = Date()) {
        currentCompassHeading = heading
        var history = compassHeadingHistory ?? []
        history.append(HeadingSample(timestamp: timestamp, heading: heading))
        Self.trimHistory(&history)
        compassHeadingHistory = history
    }

    mutating func updateWithBarometricAltitude(relativeAltitude: Double, pressure: Double?, timestamp: Date = Date()) {
        currentBarometricRelativeAltitude = relativeAltitude
        currentPressure = pressure ?? currentPressure
        maxBarometricRelativeAltitude = max(maxBarometricRelativeAltitude ?? relativeAltitude, relativeAltitude)
        minBarometricRelativeAltitude = min(minBarometricRelativeAltitude ?? relativeAltitude, relativeAltitude)

        var history = barometricAltitudeHistory ?? []
        var verticalSpeed: Double?
        if let previous = history.last {
            let timeDelta = timestamp.timeIntervalSince(previous.timestamp)
            if timeDelta > 0.2 {
                let altitudeDelta = relativeAltitude - previous.relativeAltitude
                verticalSpeed = altitudeDelta / timeDelta

                // Ignore tiny barometer flutter when accumulating climb/descent.
                if abs(altitudeDelta) >= 0.3 {
                    if altitudeDelta > 0 {
                        barometricAltitudeGain = (barometricAltitudeGain ?? 0) + altitudeDelta
                    } else {
                        barometricAltitudeLoss = (barometricAltitudeLoss ?? 0) + abs(altitudeDelta)
                    }
                }

                currentVerticalSpeed = verticalSpeed
                if let verticalSpeed {
                    maxClimbRate = max(maxClimbRate ?? verticalSpeed, verticalSpeed)
                    maxDescentRate = min(maxDescentRate ?? verticalSpeed, verticalSpeed)
                }
            }
        }

        history.append(BarometricAltitudeSample(
            timestamp: timestamp,
            relativeAltitude: relativeAltitude,
            verticalSpeed: verticalSpeed
        ))
        Self.trimHistory(&history)
        barometricAltitudeHistory = history

        let verticalSpeeds = history.compactMap { $0.verticalSpeed }.map(abs)
        if !verticalSpeeds.isEmpty {
            averageVerticalSpeed = verticalSpeeds.reduce(0, +) / Double(verticalSpeeds.count)
        }
    }

    private mutating func updateGPSQuality(with location: FlightLocation) {
        let history = gpsQualityHistory ?? []
        let previousTimestamp = history.last?.timestamp
        let score = gpsQualityScore(for: location, previousTimestamp: previousTimestamp)
        currentGPSQualityScore = score
        bestGPSQualityScore = max(bestGPSQualityScore ?? score, score)
        worstGPSQualityScore = min(worstGPSQualityScore ?? score, score)

        var updatedHistory = history
        updatedHistory.append(GPSQualitySample(
            timestamp: location.timestamp,
            score: score,
            horizontalAccuracy: location.horizontalAccuracy
        ))
        Self.trimHistory(&updatedHistory)
        gpsQualityHistory = updatedHistory
        averageGPSQualityScore = updatedHistory.map { $0.score }.reduce(0, +) / Double(updatedHistory.count)
    }

    private static func trimHistory<T>(_ history: inout [T], limit: Int = FlightMetrics.liveHistoryLimit) {
        guard history.count > limit else { return }
        history.removeFirst(history.count - limit)
    }

    private func gpsQualityScore(for location: FlightLocation, previousTimestamp: Date?) -> Double {
        guard location.isValid, location.horizontalAccuracy >= 0 else { return 0 }

        let accuracy = location.horizontalAccuracy
        let accuracyScore: Double
        switch accuracy {
        case ...10:
            accuracyScore = 100
        case ...20:
            accuracyScore = 90
        case ...35:
            accuracyScore = 75
        case ...50:
            accuracyScore = 60
        case ...100:
            accuracyScore = 35
        case ...250:
            accuracyScore = 15
        default:
            accuracyScore = 5
        }

        let gapPenalty: Double
        if let previousTimestamp {
            let gap = location.timestamp.timeIntervalSince(previousTimestamp)
            switch gap {
            case ...2.5:
                gapPenalty = 0
            case ...5:
                gapPenalty = 8
            case ...10:
                gapPenalty = 25
            case ...20:
                gapPenalty = 45
            default:
                gapPenalty = 65
            }
        } else {
            gapPenalty = 0
        }

        let wallClockAge = Date().timeIntervalSince(location.timestamp)
        let agePenalty: Double
        if wallClockAge >= 0, wallClockAge <= 60 {
            switch wallClockAge {
            case ...2.5:
                agePenalty = 0
            case ...5:
                agePenalty = 5
            case ...10:
                agePenalty = 15
            default:
                agePenalty = 35
            }
        } else {
            agePenalty = 0
        }

        let filterPenalty = location.isFiltered ? 10.0 : 0.0
        let baseScore = max(0, min(100, accuracyScore - gapPenalty - agePenalty - filterPenalty))

        if location.isEstimated {
            return min(baseScore, 25)
        }

        return baseScore
    }

    mutating func clearCheckpointedHistories() {
        speedHistory.removeAll(keepingCapacity: true)
        altitudeHistory.removeAll(keepingCapacity: true)
        pressureHistory.removeAll(keepingCapacity: true)
        accelerationHistory?.removeAll(keepingCapacity: true)
        motionAccelerationHistory?.removeAll(keepingCapacity: true)
        attitudeHistory?.removeAll(keepingCapacity: true)
        rotationRateHistory?.removeAll(keepingCapacity: true)
        compassHeadingHistory?.removeAll(keepingCapacity: true)
        barometricAltitudeHistory?.removeAll(keepingCapacity: true)
        gpsQualityHistory?.removeAll(keepingCapacity: true)
    }

    mutating func calculateAverages(duration: TimeInterval) {
        self.duration = duration
        if duration > 0 {
            averageSpeed = totalDistance / duration
        }
    }

    /// Replaces any NaN/Infinity scalar values with safe finite numbers so the
    /// metrics can be persisted to disk and saved to HealthKit without crashing.
    mutating func sanitize() {
        func fix(_ v: Double) -> Double { v.isFinite ? v : 0.0 }
        func fixOpt(_ v: Double?) -> Double? {
            guard let v = v else { return nil }
            return v.isFinite ? v : 0.0
        }

        totalDistance = fix(totalDistance)
        averageSpeed = fix(averageSpeed)
        maxSpeed = fix(maxSpeed)
        currentSpeed = fix(currentSpeed)
        smoothedSpeed = fix(smoothedSpeed)
        maxAcceleration = fixOpt(maxAcceleration)
        maxDeceleration = fixOpt(maxDeceleration)
        averageAcceleration = fixOpt(averageAcceleration)
        maxMotionAcceleration = fixOpt(maxMotionAcceleration)
        averageMotionAcceleration = fixOpt(averageMotionAcceleration)
        maxAltitude = fix(maxAltitude)
        minAltitude = fix(minAltitude)
        currentAltitude = fix(currentAltitude)
        totalAltitudeGain = fix(totalAltitudeGain)
        totalAltitudeLoss = fix(totalAltitudeLoss)
        averageAccuracy = fix(averageAccuracy)
        caloriesBurned = fix(caloriesBurned)
        restingEnergyBurned = fix(restingEnergyBurned)
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
