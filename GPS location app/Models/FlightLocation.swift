import Foundation
import CoreLocation

struct FlightLocation: Identifiable, Codable, Hashable {
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

    // Full motion snapshot captured at each point (all optional so existing saved data still
    // decodes). `course`/`speed`/`altitude` above already carry movement direction, speed and
    // height; these add the rest of what the sensors know at that instant — important for
    // diagnosing dead-reckoned flights where GPS is absent.
    var motionAcceleration: Double?        // m/s², gravity-removed magnitude
    var forwardAcceleration: Double?       // m/s² along travel direction
    var lateralAcceleration: Double?       // m/s² sideways
    var deviceHeading: Double?             // degrees, device attitude yaw (world frame)
    var compassHeading: Double?            // degrees, magnetometer heading
    var movementDirection: Double?         // degrees, estimated direction of motion
    var pitch: Double?                     // degrees
    var roll: Double?                      // degrees
    var yaw: Double?                       // degrees
    var rotationRate: Double?              // rad/s magnitude
    var verticalSpeed: Double?             // m/s (barometric climb rate)
    var relativeAltitude: Double?          // m, barometric altitude change since start

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
        case motionAcceleration
        case forwardAcceleration
        case lateralAcceleration
        case deviceHeading
        case compassHeading
        case movementDirection
        case pitch
        case roll
        case yaw
        case rotationRate
        case verticalSpeed
        case relativeAltitude
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
        self.motionAcceleration = nil
        self.forwardAcceleration = nil
        self.lateralAcceleration = nil
        self.deviceHeading = nil
        self.compassHeading = nil
        self.movementDirection = nil
        self.pitch = nil
        self.roll = nil
        self.yaw = nil
        self.rotationRate = nil
        self.verticalSpeed = nil
        self.relativeAltitude = nil
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
        motionAcceleration = try container.decodeIfPresent(Double.self, forKey: .motionAcceleration)
        forwardAcceleration = try container.decodeIfPresent(Double.self, forKey: .forwardAcceleration)
        lateralAcceleration = try container.decodeIfPresent(Double.self, forKey: .lateralAcceleration)
        deviceHeading = try container.decodeIfPresent(Double.self, forKey: .deviceHeading)
        compassHeading = try container.decodeIfPresent(Double.self, forKey: .compassHeading)
        movementDirection = try container.decodeIfPresent(Double.self, forKey: .movementDirection)
        pitch = try container.decodeIfPresent(Double.self, forKey: .pitch)
        roll = try container.decodeIfPresent(Double.self, forKey: .roll)
        yaw = try container.decodeIfPresent(Double.self, forKey: .yaw)
        rotationRate = try container.decodeIfPresent(Double.self, forKey: .rotationRate)
        verticalSpeed = try container.decodeIfPresent(Double.self, forKey: .verticalSpeed)
        relativeAltitude = try container.decodeIfPresent(Double.self, forKey: .relativeAltitude)
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
        try container.encodeIfPresent(motionAcceleration, forKey: .motionAcceleration)
        try container.encodeIfPresent(forwardAcceleration, forKey: .forwardAcceleration)
        try container.encodeIfPresent(lateralAcceleration, forKey: .lateralAcceleration)
        try container.encodeIfPresent(deviceHeading, forKey: .deviceHeading)
        try container.encodeIfPresent(compassHeading, forKey: .compassHeading)
        try container.encodeIfPresent(movementDirection, forKey: .movementDirection)
        try container.encodeIfPresent(pitch, forKey: .pitch)
        try container.encodeIfPresent(roll, forKey: .roll)
        try container.encodeIfPresent(yaw, forKey: .yaw)
        try container.encodeIfPresent(rotationRate, forKey: .rotationRate)
        try container.encodeIfPresent(verticalSpeed, forKey: .verticalSpeed)
        try container.encodeIfPresent(relativeAltitude, forKey: .relativeAltitude)
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

    /// Full member-wise initializer. The coordinate fields are `let`, so producing a copy
    /// with a shifted position (used to rubber-sheet dead-reckoned points onto a GPS fix)
    /// needs an initializer that sets every stored property explicitly.
    init(id: UUID, timestamp: Date, latitude: Double, longitude: Double, altitude: Double,
         horizontalAccuracy: Double, verticalAccuracy: Double, speed: Double, course: Double,
         pressure: Double?, satelliteCount: Int?, signalStrength: Double?,
         isFiltered: Bool, isValid: Bool, isEstimated: Bool,
         motion: MotionSnapshot? = nil) {
        self.id = id; self.timestamp = timestamp
        self.latitude = latitude; self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy; self.verticalAccuracy = verticalAccuracy
        self.speed = speed; self.course = course
        self.pressure = pressure; self.satelliteCount = satelliteCount; self.signalStrength = signalStrength
        self.isFiltered = isFiltered; self.isValid = isValid; self.isEstimated = isEstimated
        self.motionAcceleration = motion?.acceleration
        self.forwardAcceleration = motion?.forwardAcceleration
        self.lateralAcceleration = motion?.lateralAcceleration
        self.deviceHeading = motion?.deviceHeading
        self.compassHeading = motion?.compassHeading
        self.movementDirection = motion?.movementDirection
        self.pitch = motion?.pitch; self.roll = motion?.roll; self.yaw = motion?.yaw
        self.rotationRate = motion?.rotationRate
        self.verticalSpeed = motion?.verticalSpeed
        self.relativeAltitude = motion?.relativeAltitude
    }

    /// Applies a motion snapshot to a freshly-built location (used for the CLLocation-based
    /// initializer, which cannot carry these fields).
    func withMotion(_ motion: MotionSnapshot?) -> FlightLocation {
        guard let motion else { return self }
        var copy = self
        copy.motionAcceleration = motion.acceleration
        copy.forwardAcceleration = motion.forwardAcceleration
        copy.lateralAcceleration = motion.lateralAcceleration
        copy.deviceHeading = motion.deviceHeading
        copy.compassHeading = motion.compassHeading
        copy.movementDirection = motion.movementDirection
        copy.pitch = motion.pitch; copy.roll = motion.roll; copy.yaw = motion.yaw
        copy.rotationRate = motion.rotationRate
        copy.verticalSpeed = motion.verticalSpeed
        copy.relativeAltitude = motion.relativeAltitude
        return copy
    }

    /// A copy shifted horizontally by (north, east) metres, preserving identity and every
    /// other field. Uses a local equirectangular approximation, which is exact enough for the
    /// small (metres-to-hundreds-of-metres) corrections rubber-sheeting applies.
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


/// A snapshot of the device's motion sensors at one instant, attached to a FlightLocation.
struct MotionSnapshot {
    var acceleration: Double?
    var forwardAcceleration: Double?
    var lateralAcceleration: Double?
    var deviceHeading: Double?
    var compassHeading: Double?
    var movementDirection: Double?
    var pitch: Double?
    var roll: Double?
    var yaw: Double?
    var rotationRate: Double?
    var verticalSpeed: Double?
    var relativeAltitude: Double?
}
