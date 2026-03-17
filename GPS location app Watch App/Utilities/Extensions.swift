import Foundation
import CoreLocation
import SwiftUI

// MARK: - Double Extensions
extension Double {
    /// Convert meters to kilometers
    var toKilometers: Double {
        return self / 1000.0
    }

    /// Convert meters to miles
    var toMiles: Double {
        return self / 1609.34
    }

    /// Convert meters per second to kilometers per hour
    var toKmh: Double {
        return self * 3.6
    }

    /// Convert meters per second to miles per hour
    var toMph: Double {
        return self * 2.23694
    }

    /// Convert meters per second to knots
    var toKnots: Double {
        return self * 1.94384
    }

    /// Convert meters to feet
    var toFeet: Double {
        return self * 3.28084
    }
}

// MARK: - TimeInterval Extensions
extension TimeInterval {
    /// Format duration as HH:MM:SS
    var formattedDuration: String {
        let hours = Int(self) / 3600
        let minutes = Int(self) / 60 % 60
        let seconds = Int(self) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// Format duration as HH:MM
    var formattedShortDuration: String {
        let hours = Int(self) / 3600
        let minutes = Int(self) / 60 % 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    /// Format duration as "Xh Ym"
    var formattedHumanReadable: String {
        let hours = Int(self) / 3600
        let minutes = Int(self) / 60 % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - Date Extensions
extension Date {
    /// Format date as "MMM dd, yyyy"
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }

    /// Format date and time as "MMM dd, yyyy HH:mm"
    var formattedDateTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }

    /// Format time as "HH:mm:ss"
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: self)
    }
}

// MARK: - CLLocation Extensions
extension CLLocation {
    /// Calculate distance using Haversine formula
    func haversineDistance(to location: CLLocation) -> Double {
        let lat1 = self.coordinate.latitude.degreesToRadians
        let lon1 = self.coordinate.longitude.degreesToRadians
        let lat2 = location.coordinate.latitude.degreesToRadians
        let lon2 = location.coordinate.longitude.degreesToRadians

        let dLat = lat2 - lat1
        let dLon = lon2 - lon1

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1) * cos(lat2) *
                sin(dLon / 2) * sin(dLon / 2)

        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        let earthRadius = 6371000.0 // meters
        return earthRadius * c
    }

    /// Get bearing to another location
    func bearing(to location: CLLocation) -> Double {
        let lat1 = self.coordinate.latitude.degreesToRadians
        let lon1 = self.coordinate.longitude.degreesToRadians
        let lat2 = location.coordinate.latitude.degreesToRadians
        let lon2 = location.coordinate.longitude.degreesToRadians

        let dLon = lon2 - lon1

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        let bearing = atan2(y, x)
        return bearing.radiansToDegrees.normalized
    }
}

// MARK: - CLLocationCoordinate2D Extensions
extension CLLocationCoordinate2D {
    /// Check if coordinate is valid
    var isValid: Bool {
        return latitude >= -90 && latitude <= 90 &&
               longitude >= -180 && longitude <= 180
    }
}

// MARK: - Numeric Extensions
extension Double {
    /// Convert degrees to radians
    var degreesToRadians: Double {
        return self * .pi / 180.0
    }

    /// Convert radians to degrees
    var radiansToDegrees: Double {
        return self * 180.0 / .pi
    }

    /// Normalize angle to 0-360 range
    var normalized: Double {
        var angle = self
        while angle < 0 {
            angle += 360
        }
        while angle >= 360 {
            angle -= 360
        }
        return angle
    }
}

// MARK: - Array Extensions
extension Array where Element == FlightLocation {
    /// Calculate total distance for array of locations
    var totalDistance: Double {
        guard count > 1 else { return 0 }

        var distance: Double = 0
        for i in 0..<(count - 1) {
            distance += self[i].distance(to: self[i + 1])
        }
        return distance
    }

    /// Get valid locations only
    var validLocations: [FlightLocation] {
        return filter { $0.isValid }
    }
}

// MARK: - Color Extensions
extension Color {
    /// Color for speed-based path coloring
    static func speedColor(for speed: Double, maxSpeed: Double) -> Color {
        let ratio = speed / maxSpeed
        if ratio > 0.8 {
            return .green
        } else if ratio > 0.5 {
            return .yellow
        } else {
            return .red
        }
    }
}
