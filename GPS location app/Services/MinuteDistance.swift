import Foundation

/// THE DISTANCE MINUTE BY MINUTE, SO FITNESS CAN SHOW PACE (build 122).
///
/// The workout's distance went to Health as one sample covering the whole workout, which gives Fitness a total
/// and an average but nothing to draw pace or splits from. Now it is spread over the workout's minutes along the
/// recorded route - GPS and Force Velocity points alike, flights included - and scaled so the minutes add up to
/// exactly the workout's distance (the distance the app counted, which can include distance made up after iOS
/// paused the app and so is not always the sum of the route's segments). Nothing is added or removed: only when.
///
/// The watch carries an identical copy.
enum MinuteDistance {
    typealias Minute = (start: Date, end: Date, meters: Double)

    static func split(locations: [FlightLocation], total: Double, start: Date, end: Date) -> [Minute] {
        let span = end.timeIntervalSince(start)
        let pts = locations.filter { $0.isValid }.sorted { $0.timestamp < $1.timestamp }
        guard total > 0, span >= 60, pts.count > 1 else { return [] }
        let n = Int((span / 60).rounded(.up))
        var bins = [Double](repeating: 0, count: n)
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let d = meters(a, b)
            guard d > 0, d.isFinite else { continue }
            let t0 = min(max(a.timestamp.timeIntervalSince(start), 0), span)
            let t1 = min(max(b.timestamp.timeIntervalSince(start), 0), span)
            if t1 <= t0 {                                     // no time between them: all in that minute
                bins[min(n - 1, Int(t0 / 60))] += d
                continue
            }
            var t = t0                                        // spread over the minutes it spans, by time
            while t < t1 {
                let k = min(n - 1, Int(t / 60))
                let edge = min(t1, Double(k + 1) * 60)
                guard edge > t else { break }
                bins[k] += d * (edge - t) / (t1 - t0)
                t = edge
            }
        }
        let sum = bins.reduce(0, +)
        guard sum > 0 else { return [] }
        let scale = total / sum
        var out: [Minute] = []
        for (k, m) in bins.enumerated() where m > 0 {
            let s = start.addingTimeInterval(Double(k) * 60)
            let e = min(end, start.addingTimeInterval(Double(k + 1) * 60))
            if e > s { out.append((s, e, m * scale)) }
        }
        return out
    }

    private static func meters(_ a: FlightLocation, _ b: FlightLocation) -> Double {
        let r = 6_371_000.0, la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dLa = la2 - la1, dLo = (b.longitude - a.longitude) * .pi / 180
        let x = sin(dLa / 2) * sin(dLa / 2) + cos(la1) * cos(la2) * sin(dLo / 2) * sin(dLo / 2)
        return 2 * r * asin(min(1, x.squareRoot()))
    }
}
