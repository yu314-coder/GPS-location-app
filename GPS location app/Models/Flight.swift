import Foundation
import CoreLocation
import HealthKit

struct Flight: Identifiable, Codable, Hashable {
    let id: UUID
    var startDate: Date
    var endDate: Date?
    var locations: [FlightLocation]
    var metrics: FlightMetrics?

    // Flight details
    var origin: String?
    var destination: String?
    var notes: String?
    var effort: Int?

    // HealthKit reference
    var workoutUUID: UUID?
    var workoutType: UInt? // HKWorkoutActivityType raw value
    var lastResyncedAt: Date?
    var lastResyncSignature: String?

    init(id: UUID = UUID(), startDate: Date = Date()) {
        self.id = id
        self.startDate = startDate
        self.locations = []
        self.effort = nil
    }

    // Computed properties
    var duration: TimeInterval {
        guard let endDate = endDate else {
            return Date().timeIntervalSince(startDate)
        }
        return endDate.timeIntervalSince(startDate)
    }

    var isActive: Bool {
        return endDate == nil
    }

    var totalDistance: Double {
        return metrics?.totalDistance ?? 0
    }

    var averageSpeed: Double {
        return metrics?.averageSpeed ?? 0
    }

    var maxAltitude: Double {
        return metrics?.maxAltitude ?? 0
    }
}
