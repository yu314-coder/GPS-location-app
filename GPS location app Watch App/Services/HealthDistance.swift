import Foundation
import HealthKit

/// WHAT APPLE HEALTH IS TOLD (build 120).
///
/// Every journey is recorded as a workout, whatever carried it - a walk, a car, a motorcycle, an airliner - and
/// the workout type only names it in Health. Until build 120 the whole distance went to Health as walking and
/// running distance (and again as cycling distance), with steps estimated from it (a four-hour flight came to
/// about 4.5 million steps), speed samples and made-up gait samples from vehicle speeds, and the vehicle's
/// average and top speed. The Fitness app's walking and running distance and pace took all of it in.
///
/// Now Health gets only what was covered on foot: a stretch between two route points counts when it moved at
/// walking pace (at most 2.8 m/s, about 10 km/h, between the points and at each), the points are no more than
/// 30 s apart, and no point within two minutes was at vehicle speed (5.5 m/s, as the vehicle test elsewhere).
/// A journey with less than half of its distance on foot is saved under the Other type, so it stays out of
/// walking and running altogether. The app keeps the whole route and distance; the workout carries it in its
/// metadata (com.exmstc.gps.gpsDistanceMeters), which the app's own screens read first.
///
/// The watch carries an identical copy.
enum HealthDistance {
    static let FOOT_MAX = 2.8                         // m/s
    static let VEHICLE = 5.5                          // m/s
    static let VEHICLE_MARGIN: TimeInterval = 120
    static let MAX_GAP: TimeInterval = 30
    static let ONE_HALF = 0.5

    typealias Interval = (start: Date, end: Date, meters: Double)

    /// The stretches moved on foot, merged where they touch.
    static func onFootIntervals(_ locations: [FlightLocation]) -> [Interval] {
        let pts = locations.filter { $0.isValid }.sorted { $0.timestamp < $1.timestamp }
        guard pts.count > 1 else { return [] }
        let vehicle = pts.filter { $0.speed > VEHICLE }.map { $0.timestamp.timeIntervalSince1970 }
        func nearVehicle(_ d: Date) -> Bool {
            let t = d.timeIntervalSince1970
            var lo = 0, hi = vehicle.count                // first vehicle time >= t - margin
            while lo < hi { let mid = (lo + hi) / 2; if vehicle[mid] < t - VEHICLE_MARGIN { lo = mid + 1 } else { hi = mid } }
            return lo < vehicle.count && vehicle[lo] <= t + VEHICLE_MARGIN
        }
        var out: [Interval] = []
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            guard dt > 0, dt <= MAX_GAP else { continue }
            let d = meters(a, b)
            guard d / dt <= FOOT_MAX, a.speed <= FOOT_MAX, b.speed <= FOOT_MAX,
                  !nearVehicle(a.timestamp), !nearVehicle(b.timestamp) else { continue }
            if let last = out.last, last.end == a.timestamp {
                out[out.count - 1] = (last.start, b.timestamp, last.meters + d)
            } else {
                out.append((a.timestamp, b.timestamp, d))
            }
        }
        return out.filter { $0.meters > 0 }
    }

    /// The type Health is told: the chosen one, except Other for a walking, running or hiking workout that was
    /// mostly not on foot.
    static func exportType(_ chosen: HKWorkoutActivityType, totalMeters: Double, onFootMeters: Double) -> HKWorkoutActivityType {
        guard chosen == .walking || chosen == .running || chosen == .hiking else { return chosen }
        return totalMeters > 500 && onFootMeters < ONE_HALF * totalMeters ? .other : chosen
    }

    /// Walking and running distance samples, one per stretch on foot.
    static func walkingSamples(_ intervals: [Interval]) -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else { return [] }
        return intervals.map {
            HKQuantitySample(type: type, quantity: HKQuantity(unit: .meter(), doubleValue: $0.meters), start: $0.start, end: $0.end)
        }
    }

    private static func meters(_ a: FlightLocation, _ b: FlightLocation) -> Double {
        let r = 6_371_000.0, la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dLa = la2 - la1, dLo = (b.longitude - a.longitude) * .pi / 180
        let x = sin(dLa / 2) * sin(dLa / 2) + cos(la1) * cos(la2) * sin(dLo / 2) * sin(dLo / 2)
        return 2 * r * asin(min(1, x.squareRoot()))
    }
}

extension HKWorkout {
    /// The journey's distance as the app measured it: the metadata the app writes, else Health's total (which,
    /// since build 120, is only the distance on foot).
    var appDistanceMeters: Double? {
        if let m = metadata?["com.exmstc.gps.gpsDistanceMeters"] as? Double, m > 0 { return m }
        if let n = metadata?["com.exmstc.gps.gpsDistanceMeters"] as? NSNumber, n.doubleValue > 0 { return n.doubleValue }
        return totalDistance?.doubleValue(for: .meter())
    }
}
