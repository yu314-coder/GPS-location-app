import Foundation
import CoreLocation

class KalmanFilterEngine {
    // State variables
    private var latitude: Double = 0
    private var longitude: Double = 0
    private var latVelocity: Double = 0
    private var lonVelocity: Double = 0

    // Covariance (uncertainty in position and velocity)
    private var positionVariance: Double = 1.0
    private var velocityVariance: Double = 1.0

    // Process noise (Q) - how much we trust the motion model
    private let processNoise: Double = 0.001

    // Measurement noise (R) - how much we trust GPS measurements
    private let measurementNoise: Double = 50.0

    // Timestamp of last update
    private var lastTimestamp: Date?

    // Initialization flag
    private var isInitialized = false

    func filterLocation(_ rawLocation: CLLocation) -> CLLocation {
        // Initialize filter with first location
        if !isInitialized {
            latitude = rawLocation.coordinate.latitude
            longitude = rawLocation.coordinate.longitude
            latVelocity = 0
            lonVelocity = 0
            lastTimestamp = rawLocation.timestamp
            isInitialized = true
            return rawLocation
        }

        // Calculate time delta
        let deltaTime: Double
        if let last = lastTimestamp {
            deltaTime = rawLocation.timestamp.timeIntervalSince(last)
        } else {
            deltaTime = 1.0
        }
        lastTimestamp = rawLocation.timestamp

        // Clamp deltaTime to reasonable values
        let dt = min(max(deltaTime, 0.1), 10.0)

        // PREDICTION PHASE
        // Predict next position based on velocity
        let predictedLat = latitude + latVelocity * dt
        let predictedLon = longitude + lonVelocity * dt

        // Increase uncertainty due to process noise
        positionVariance += processNoise * dt
        velocityVariance += processNoise * dt

        // MEASUREMENT PHASE
        let measurementLat = rawLocation.coordinate.latitude
        let measurementLon = rawLocation.coordinate.longitude

        // Innovation (difference between predicted and measured)
        let innovationLat = measurementLat - predictedLat
        let innovationLon = measurementLon - predictedLon

        // UPDATE PHASE
        // Innovation covariance
        let innovationCovariance = positionVariance + measurementNoise

        // Kalman gain (how much to trust the measurement)
        let kalmanGain = positionVariance / innovationCovariance

        // Update position estimate
        latitude = predictedLat + kalmanGain * innovationLat
        longitude = predictedLon + kalmanGain * innovationLon

        // Update velocity estimate
        latVelocity = innovationLat / dt
        lonVelocity = innovationLon / dt

        // Reduce uncertainty based on measurement
        positionVariance = (1 - kalmanGain) * positionVariance
        velocityVariance *= 0.95  // Gradual decrease

        // Calculate filtered horizontal accuracy
        let filteredAccuracy = sqrt(positionVariance)

        // Return filtered location
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: rawLocation.altitude,
            horizontalAccuracy: filteredAccuracy,
            verticalAccuracy: rawLocation.verticalAccuracy,
            course: rawLocation.course,
            speed: rawLocation.speed,
            timestamp: rawLocation.timestamp
        )
    }

    func reset() {
        latitude = 0
        longitude = 0
        latVelocity = 0
        lonVelocity = 0
        positionVariance = 1.0
        velocityVariance = 1.0
        lastTimestamp = nil
        isInitialized = false
    }
}
