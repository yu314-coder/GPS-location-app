import Foundation
import CoreLocation

/// On-device HMM map matching (Newson & Krumm 2009) against the locally cached
/// OSM road network — the same model Valhalla/OSRM use, run fully OFFLINE.
///
/// Observations = GPS points, hidden states = candidate road positions.
/// - Emission:   Gaussian on point→road distance (σ = GPS noise)
/// - Transition: exponential on |great-circle Δ − matched Δ| (β), with a bonus
///               for staying on the same OSM way
/// - Decoding:   Viterbi
enum OfflineMapMatcher {

    private static let sigmaZ = 7.0            // meters — consumer GPS noise
    private static let beta = 4.0              // meters — route-vs-gc tolerance
    private static let searchRadius = 42.0     // meters — candidate search
    private static let maxCandidates = 6
    private static let sameWayBonus = 0.4      // log-prob bonus for way continuity
    private static let maxInputPoints = 500

    /// Match a GPS trace to roads. Returns the snapped polyline, or nil when the
    /// trace doesn't fit the cached road network well enough (caller falls back).
    static func match(coordinates: [CLLocationCoordinate2D], index: RoadNetworkStore.RoadIndex) -> [CLLocationCoordinate2D]? {
        guard coordinates.count > 2 else { return nil }

        // Bound the work: thin very dense traces.
        var pts = coordinates
        if pts.count > maxInputPoints {
            let stride = max(1, pts.count / maxInputPoints)
            var thinned: [CLLocationCoordinate2D] = []
            var i = 0
            while i < pts.count { thinned.append(pts[i]); i += stride }
            if let last = pts.last { thinned.append(last) }
            pts = thinned
        }

        // Candidate states per observation.
        var states: [[RoadNetworkStore.Candidate]] = []
        states.reserveCapacity(pts.count)
        var matchable = 0
        for p in pts {
            let cands = index.candidates(near: p, maxDistance: searchRadius, maxCount: maxCandidates)
            if !cands.isEmpty { matchable += 1 }
            states.append(cands)
        }
        // Require most of the trace to be near roads, otherwise this isn't a
        // road workout (trail/open field) and snapping would lie.
        guard matchable >= (pts.count * 6) / 10 else {
            print("🧭 Offline match skipped: only \(matchable)/\(pts.count) points near roads")
            return nil
        }

        // Viterbi.
        let minLog = -1e9
        var prevScores: [Double] = []
        var backPointers: [[Int]] = []
        var prevCands: [RoadNetworkStore.Candidate] = []
        var lastObservedIdx: Int? = nil   // observation index of prevCands
        var columns: [(obs: Int, cands: [RoadNetworkStore.Candidate])] = []

        for (t, cands) in states.enumerated() {
            guard !cands.isEmpty else { continue }
            let emissions = cands.map { -($0.distanceMeters * $0.distanceMeters) / (2 * sigmaZ * sigmaZ) }

            if prevCands.isEmpty {
                prevScores = emissions
                backPointers.append(Array(repeating: -1, count: cands.count))
                prevCands = cands
                lastObservedIdx = t
                columns.append((t, cands))
                continue
            }

            let gcDist = meters(pts[lastObservedIdx!], pts[t])
            var scores = Array(repeating: minLog, count: cands.count)
            var back = Array(repeating: 0, count: cands.count)
            for j in 0..<cands.count {
                var best = minLog
                var bestI = 0
                for i in 0..<prevCands.count {
                    let matchedDist = meters(prevCands[i].location, cands[j].location)
                    var logT = -abs(gcDist - matchedDist) / beta
                    if prevCands[i].wayID == cands[j].wayID { logT += sameWayBonus }
                    let s = prevScores[i] + logT
                    if s > best { best = s; bestI = i }
                }
                scores[j] = best + emissions[j]
                back[j] = bestI
            }
            prevScores = scores
            backPointers.append(back)
            prevCands = cands
            lastObservedIdx = t
            columns.append((t, cands))
        }

        guard columns.count > 2 else { return nil }

        // Backtrack.
        var stateIdx = prevScores.indices.max(by: { prevScores[$0] < prevScores[$1] }) ?? 0
        var picked = Array(repeating: 0, count: columns.count)
        for c in stride(from: columns.count - 1, through: 0, by: -1) {
            picked[c] = stateIdx
            stateIdx = backPointers[c][stateIdx]
            if stateIdx < 0 { stateIdx = 0 }
        }

        // Snapped polyline (skip consecutive duplicates).
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(columns.count)
        for (c, column) in columns.enumerated() {
            let loc = column.cands[picked[c]].location
            if let last = result.last, meters(last, loc) < 0.5 { continue }
            result.append(loc)
        }
        return result.count > 1 ? result : nil
    }

    private static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let mPerDegLat = 111_320.0
        let mPerDegLon = mPerDegLat * cos(a.latitude * .pi / 180)
        let dx = (b.longitude - a.longitude) * mPerDegLon
        let dy = (b.latitude - a.latitude) * mPerDegLat
        return (dx * dx + dy * dy).squareRoot()
    }
}
