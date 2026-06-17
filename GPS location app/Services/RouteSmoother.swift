import Foundation
import CoreLocation

/// Fully-offline GPS trace cleaning. Without a road-network graph you can't snap
/// to actual roads, but you can remove GPS noise so the line looks clean and
/// road-like. Pipeline: drop near-duplicates → remove spikes → Douglas-Peucker
/// simplify → Chaikin corner-cutting smoothing. No network, no API key.
enum RouteSmoother {

    static func smooth(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 3 else { return coordinates }
        let deduped = removeDuplicates(coordinates, minMeters: 2.0)
        let despiked = removeSpikes(deduped, maxTurnDegrees: 150, minLegMeters: 4.0)
        let simplified = douglasPeucker(despiked, epsilonMeters: 6.0)
        let smoothed = chaikin(simplified, iterations: 2)
        return smoothed.count > 1 ? smoothed : coordinates
    }

    // MARK: - Distance helpers (equirectangular approx — fine at local scale)

    private static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let mPerDegLat = 111_320.0
        let mPerDegLon = mPerDegLat * cos(a.latitude * .pi / 180)
        let dx = (b.longitude - a.longitude) * mPerDegLon
        let dy = (b.latitude - a.latitude) * mPerDegLat
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - 1) Drop consecutive near-duplicate points

    private static func removeDuplicates(_ coords: [CLLocationCoordinate2D], minMeters: Double) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for c in coords {
            if let last = result.last, meters(last, c) < minMeters { continue }
            result.append(c)
        }
        if let last = coords.last,
           result.last.map({ meters($0, last) >= 0.5 }) == true {
            // keep true endpoint
        }
        return result.count > 1 ? result : coords
    }

    // MARK: - 2) Remove obvious spikes (sharp hairpins over a tiny distance)

    private static func removeSpikes(_ coords: [CLLocationCoordinate2D], maxTurnDegrees: Double, minLegMeters: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 2 else { return coords }
        var result: [CLLocationCoordinate2D] = [coords[0]]
        for i in 1..<(coords.count - 1) {
            let prev = result.last ?? coords[i - 1]
            let cur = coords[i]
            let next = coords[i + 1]
            let inLeg = meters(prev, cur)
            let outLeg = meters(cur, next)
            // Only consider short legs for spike removal; long legs are real movement.
            if inLeg < minLegMeters && outLeg < minLegMeters {
                let turn = turnAngle(prev, cur, next)
                if turn > maxTurnDegrees { continue } // drop the spike point
            }
            result.append(cur)
        }
        result.append(coords[coords.count - 1])
        return result
    }

    private static func turnAngle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D) -> Double {
        let mPerDegLat = 111_320.0
        let mPerDegLon = mPerDegLat * cos(b.latitude * .pi / 180)
        let v1x = (b.longitude - a.longitude) * mPerDegLon
        let v1y = (b.latitude - a.latitude) * mPerDegLat
        let v2x = (c.longitude - b.longitude) * mPerDegLon
        let v2y = (c.latitude - b.latitude) * mPerDegLat
        let dot = v1x * v2x + v1y * v2y
        let m1 = (v1x * v1x + v1y * v1y).squareRoot()
        let m2 = (v2x * v2x + v2y * v2y).squareRoot()
        guard m1 > 0, m2 > 0 else { return 0 }
        let cosA = max(-1, min(1, dot / (m1 * m2)))
        return acos(cosA) * 180 / .pi   // 0 = straight, 180 = full reversal
    }

    // MARK: - 3) Douglas-Peucker simplification

    private static func douglasPeucker(_ points: [CLLocationCoordinate2D], epsilonMeters: Double) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        simplifySegment(points, 0, points.count - 1, epsilonMeters, &keep)
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    private static func simplifySegment(_ pts: [CLLocationCoordinate2D], _ start: Int, _ end: Int, _ epsilon: Double, _ keep: inout [Bool]) {
        guard end > start + 1 else { return }
        var maxDist = 0.0
        var index = start
        for i in (start + 1)..<end {
            let d = perpendicularDistance(pts[i], lineStart: pts[start], lineEnd: pts[end])
            if d > maxDist { maxDist = d; index = i }
        }
        if maxDist > epsilon {
            keep[index] = true
            simplifySegment(pts, start, index, epsilon, &keep)
            simplifySegment(pts, index, end, epsilon, &keep)
        }
    }

    private static func perpendicularDistance(_ p: CLLocationCoordinate2D, lineStart a: CLLocationCoordinate2D, lineEnd b: CLLocationCoordinate2D) -> Double {
        let mPerDegLat = 111_320.0
        let mPerDegLon = mPerDegLat * cos(p.latitude * .pi / 180)
        let px = (p.longitude - a.longitude) * mPerDegLon
        let py = (p.latitude - a.latitude) * mPerDegLat
        let bx = (b.longitude - a.longitude) * mPerDegLon
        let by = (b.latitude - a.latitude) * mPerDegLat
        let segLenSq = bx * bx + by * by
        guard segLenSq > 0 else { return (px * px + py * py).squareRoot() }
        let t = max(0, min(1, (px * bx + py * by) / segLenSq))
        let cx = t * bx
        let cy = t * by
        let dx = px - cx
        let dy = py - cy
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - 4) Chaikin corner-cutting smoothing

    private static func chaikin(_ points: [CLLocationCoordinate2D], iterations: Int) -> [CLLocationCoordinate2D] {
        guard points.count > 2, iterations > 0 else { return points }
        var pts = points
        for _ in 0..<iterations {
            guard pts.count > 2 else { break }
            var next: [CLLocationCoordinate2D] = [pts[0]]   // keep first point
            for i in 0..<(pts.count - 1) {
                let p = pts[i]
                let q = pts[i + 1]
                let qPoint = CLLocationCoordinate2D(
                    latitude: 0.75 * p.latitude + 0.25 * q.latitude,
                    longitude: 0.75 * p.longitude + 0.25 * q.longitude
                )
                let rPoint = CLLocationCoordinate2D(
                    latitude: 0.25 * p.latitude + 0.75 * q.latitude,
                    longitude: 0.25 * p.longitude + 0.75 * q.longitude
                )
                next.append(qPoint)
                next.append(rPoint)
            }
            next.append(pts[pts.count - 1])  // keep last point
            pts = next
        }
        return pts
    }
}
