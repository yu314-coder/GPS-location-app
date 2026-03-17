import Foundation

struct AppFormatter {
    // MARK: - Distance Formatters

    static func formatDistance(_ meters: Double, unit: DistanceUnit = .kilometers) -> String {
        switch unit {
        case .kilometers:
            if meters < 1000 {
                return String(format: "%.0f m", meters)
            } else {
                return String(format: "%.1f km", meters.toKilometers)
            }
        case .miles:
            if meters < 1609.34 {
                return String(format: "%.0f ft", meters * 3.28084)
            } else {
                return String(format: "%.1f mi", meters.toMiles)
            }
        }
    }

    // MARK: - Speed Formatters

    static func formatSpeed(_ metersPerSecond: Double, unit: SpeedUnit = .kmh) -> String {
        switch unit {
        case .kmh:
            return String(format: "%.0f km/h", metersPerSecond.toKmh)
        case .mph:
            return String(format: "%.0f mph", metersPerSecond.toMph)
        case .knots:
            return String(format: "%.0f kts", metersPerSecond.toKnots)
        }
    }

    // MARK: - Altitude Formatters

    static func formatAltitude(_ meters: Double, unit: AltitudeUnit = .meters) -> String {
        switch unit {
        case .meters:
            return String(format: "%.0f m", meters)
        case .feet:
            return String(format: "%.0f ft", meters.toFeet)
        }
    }

    // MARK: - Duration Formatters

    static func formatDuration(_ duration: TimeInterval, style: DurationStyle = .full) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60

        switch style {
        case .full:
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        case .short:
            return String(format: "%02d:%02d", hours, minutes)
        case .human:
            if hours > 0 {
                return "\(hours)h \(minutes)m"
            } else if minutes > 0 {
                return "\(minutes)m \(seconds)s"
            } else {
                return "\(seconds)s"
            }
        }
    }

    // MARK: - Accuracy Formatters

    static func formatAccuracy(_ meters: Double) -> String {
        if meters < 0 {
            return "N/A"
        }
        return String(format: "±%.0f m", meters)
    }

    // MARK: - Coordinate Formatters

    static func formatCoordinate(_ coordinate: Double, type: CoordinateType) -> String {
        let degrees = Int(abs(coordinate))
        let minutes = Int((abs(coordinate) - Double(degrees)) * 60)
        let seconds = ((abs(coordinate) - Double(degrees)) * 60 - Double(minutes)) * 60

        let direction: String
        switch type {
        case .latitude:
            direction = coordinate >= 0 ? "N" : "S"
        case .longitude:
            direction = coordinate >= 0 ? "E" : "W"
        }

        return String(format: "%d°%d'%.1f\"%@", degrees, minutes, seconds, direction)
    }

    // MARK: - Percentage Formatters

    static func formatPercentage(_ value: Double) -> String {
        return String(format: "%.1f%%", value)
    }

    // MARK: - Number Formatters

    static func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func formatDecimal(_ value: Double, decimals: Int = 1) -> String {
        return String(format: "%.\(decimals)f", value)
    }
}

// MARK: - Supporting Enums

enum DistanceUnit: String {
    case kilometers = "km"
    case miles = "mi"
}

enum SpeedUnit: String {
    case kmh = "km/h"
    case mph = "mph"
    case knots = "knots"
}

enum AltitudeUnit: String {
    case meters = "meters"
    case feet = "feet"
}

enum DurationStyle {
    case full      // HH:MM:SS
    case short     // HH:MM
    case human     // "Xh Ym" or "Ym Zs"
}

enum CoordinateType {
    case latitude
    case longitude
}
