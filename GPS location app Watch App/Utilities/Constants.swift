import Foundation
import CoreLocation

struct AppConstants {
    // GPS Validation Constants
    struct GPS {
        static let maxTimestampAge: TimeInterval = 10.0 // seconds
        static let maxHorizontalAccuracyClimb: Double = 100.0 // meters
        static let maxHorizontalAccuracyCruise: Double = 150.0 // meters
        static let minRealisticAccuracy: Double = 5.0 // meters
        static let maxRealisticAccuracy: Double = 500.0 // meters
        static let maxAltitudeChangeRate: Double = 1000.0 // m/s
        static let maxSpeed: Double = 300.0 / 3.6 // 300 km/h in m/s
    }

    // Kalman Filter Constants
    struct Kalman {
        static let processNoise: Double = 0.001
        static let measurementNoise: Double = 50.0
        static let minDeltaTime: Double = 0.1
        static let maxDeltaTime: Double = 10.0
    }

    // Workout Configuration
    struct Workout {
        static let caloriesPerMinute: Double = 0.75
        static let defaultUserWeight: Double = 70.0 // kg
    }

    // UI Constants
    struct UI {
        static let defaultMapLatitudeDelta: Double = 0.1
        static let defaultMapLongitudeDelta: Double = 0.1
        static let routeFitPadding: Double = 1.2
        static let metricsUpdateInterval: TimeInterval = 1.0
    }

    // App Information
    struct App {
        static let version = "1.0.0"
        static let name = "GPS Workout Tracker"
    }

    // Default Locations (for initialization)
    struct DefaultLocations {
        static let beijing = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
        static let taipei = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
    }

    // HealthKit
    struct HealthKit {
        static let routeBatchSize = 100
    }

    // Replay
    struct Replay {
        static let baseUpdateInterval: TimeInterval = 0.1
        static let skipAmount = 50
        static let availableSpeeds = [1.0, 2.0, 4.0, 8.0, 10.0]
    }
}
