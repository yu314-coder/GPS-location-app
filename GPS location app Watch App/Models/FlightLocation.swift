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
    var isEstimated: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case latitude
        case longitude
        case altitude
        case horizontalAccuracy
        case verticalAccuracy
        case speed
        case course
        case pressure
        case satelliteCount
        case signalStrength
        case isFiltered
        case isValid
        case isEstimated
    }

    init(from location: CLLocation, isFiltered: Bool = false, isValid: Bool = true, satelliteCount: Int? = nil, signalStrength: Double? = nil, pressure: Double? = nil, isEstimated: Bool = false) {
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
        self.isEstimated = isEstimated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        altitude = try container.decode(Double.self, forKey: .altitude)
        horizontalAccuracy = try container.decode(Double.self, forKey: .horizontalAccuracy)
        verticalAccuracy = try container.decode(Double.self, forKey: .verticalAccuracy)
        speed = try container.decode(Double.self, forKey: .speed)
        course = try container.decode(Double.self, forKey: .course)
        pressure = try container.decodeIfPresent(Double.self, forKey: .pressure)
        satelliteCount = try container.decodeIfPresent(Int.self, forKey: .satelliteCount)
        signalStrength = try container.decodeIfPresent(Double.self, forKey: .signalStrength)
        isFiltered = try container.decodeIfPresent(Bool.self, forKey: .isFiltered) ?? false
        isValid = try container.decodeIfPresent(Bool.self, forKey: .isValid) ?? true
        isEstimated = try container.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(altitude, forKey: .altitude)
        try container.encode(horizontalAccuracy, forKey: .horizontalAccuracy)
        try container.encode(verticalAccuracy, forKey: .verticalAccuracy)
        try container.encode(speed, forKey: .speed)
        try container.encode(course, forKey: .course)
        try container.encodeIfPresent(pressure, forKey: .pressure)
        try container.encodeIfPresent(satelliteCount, forKey: .satelliteCount)
        try container.encodeIfPresent(signalStrength, forKey: .signalStrength)
        try container.encode(isFiltered, forKey: .isFiltered)
        try container.encode(isValid, forKey: .isValid)
        try container.encode(isEstimated, forKey: .isEstimated)
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

    /// Full member-wise initializer, so a position-shifted copy can be built despite the
    /// coordinate fields being `let` (used to rubber-sheet dead-reckoned points onto GPS).
    init(id: UUID, timestamp: Date, latitude: Double, longitude: Double, altitude: Double,
         horizontalAccuracy: Double, verticalAccuracy: Double, speed: Double, course: Double,
         pressure: Double?, satelliteCount: Int?, signalStrength: Double?,
         isFiltered: Bool, isValid: Bool, isEstimated: Bool) {
        self.id = id; self.timestamp = timestamp
        self.latitude = latitude; self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy; self.verticalAccuracy = verticalAccuracy
        self.speed = speed; self.course = course
        self.pressure = pressure; self.satelliteCount = satelliteCount; self.signalStrength = signalStrength
        self.isFiltered = isFiltered; self.isValid = isValid; self.isEstimated = isEstimated
    }

    /// A copy shifted horizontally by (north, east) metres, preserving identity and all other
    /// fields. Equirectangular approximation — exact enough for metre-scale corrections.
    func movedHorizontally(north: Double, east: Double) -> FlightLocation {
        let newLat = latitude + north / 111_320.0
        let cosLat = Swift.max(cos(latitude * .pi / 180), 0.000001)
        let newLon = longitude + east / (111_320.0 * cosLat)
        return FlightLocation(
            id: id, timestamp: timestamp, latitude: newLat, longitude: newLon, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy,
            speed: speed, course: course, pressure: pressure, satelliteCount: satelliteCount,
            signalStrength: signalStrength, isFiltered: isFiltered, isValid: isValid, isEstimated: isEstimated)
    }
}
