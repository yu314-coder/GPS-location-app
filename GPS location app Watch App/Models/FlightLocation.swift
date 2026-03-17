import Foundation
import CoreLocation

struct FlightLocation: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let speed: Double
    let course: Double

    // Atmospheric data
    let pressure: Double? // in kilopascals (kPa)

    // GPS quality metrics
    let satelliteCount: Int?
    let signalStrength: Double?

    // Validation flags
    var isFiltered: Bool
    var isValid: Bool

    init(from location: CLLocation, isFiltered: Bool = false, isValid: Bool = true, satelliteCount: Int? = nil, signalStrength: Double? = nil, pressure: Double? = nil) {
        self.id = UUID()
        self.timestamp = location.timestamp
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.verticalAccuracy = location.verticalAccuracy
        self.speed = location.speed
        self.course = location.course
        self.pressure = pressure
        self.satelliteCount = satelliteCount
        self.signalStrength = signalStrength
        self.isFiltered = isFiltered
        self.isValid = isValid
    }

    // Convert back to CLLocation
    func toCLLocation() -> CLLocation {
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
    }

    // Calculate distance to another location
    func distance(to other: FlightLocation) -> Double {
        let location1 = toCLLocation()
        let location2 = other.toCLLocation()
        return location1.distance(from: location2)
    }
}
