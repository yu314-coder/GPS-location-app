import Foundation

/// A small network that reads speed from the same 11-number vibration fingerprint as the learned
/// store, for a phone that has learned too little to answer for itself - a first install, or a
/// store the user has cleared.
///
/// WHY IT EXISTS. With an empty store the only way Velocity Mode could answer used to be the
/// current trip's own GPS-labelled samples, aged two minutes (the warm-up pool). That made a
/// first-ever Force Velocity workout partly GPS-powered. This network was trained offline on
/// recorded trips and ships with the app, so it needs nothing from the current trip: no GPS, no
/// learning, no history.
///
/// WHAT IT IS. 11 inputs, two hidden layers of 32 (ReLU), one softplus output: about 1,500
/// numbers, evaluated once a second on the CPU. Its inputs are normalised with fixed constants
/// from its training set, never with the store's running statistics, so clearing the store
/// cannot change it. Like the store it answers through a 21-point quantile calibration (an
/// averaging model squeezes its answers toward the middle; the calibration stretches them back),
/// and like the store it may refuse: a fingerprint farther from all 32 training cluster centres
/// than 99.5% of its training fingerprints gets no answer rather than a guess.
///
/// Measured on recordings each network never saw (see paper/velocity_mode.tex) it reads close to
/// the store; the store takes over once it holds enough of the user's own examples.
struct SpeedNetwork {
    private let mean: [Double]
    private let scale: [Double]
    private let w1: [[Double]], b1: [Double]
    private let w2: [[Double]], b2: [Double]
    private let w3: [Double], b3: Double
    private let calIn: [Double], calOut: [Double]
    private let centres: [[Double]]
    private let gate: Double

    private struct File: Decodable {
        let mean, scale: [Double]
        let w1: [[Double]], b1: [Double]
        let w2: [[Double]], b2: [Double]
        let w3: [Double], b3: Double
        let cal_in, cal_out: [Double]
        let centres: [[Double]]
        let gate: Double
    }

    /// The copy bundled with the app, or nil if it is missing or malformed.
    static let bundled: SpeedNetwork? = {
        guard let url = Bundle.main.url(forResource: "speed_network", withExtension: "json") else { return nil }
        return SpeedNetwork(url: url)
    }()

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(File.self, from: data),
              f.mean.count == 11, f.scale.count == 11, f.w1.count == f.b1.count,
              f.w1.allSatisfy({ $0.count == 11 }), f.w2.count == f.b2.count,
              f.w2.allSatisfy({ $0.count == f.b1.count }), f.w3.count == f.b2.count,
              f.cal_in.count == f.cal_out.count, f.cal_in.count >= 5,
              f.centres.allSatisfy({ $0.count == 11 }) else { return nil }
        mean = f.mean; scale = f.scale; w1 = f.w1; b1 = f.b1; w2 = f.w2; b2 = f.b2; w3 = f.w3; b3 = f.b3
        calIn = f.cal_in; calOut = f.cal_out; centres = f.centres; gate = f.gate
    }

    /// Speed in m/s for one fingerprint, or nil when the fingerprint is unlike the training data.
    func speed(features f: [Double]) -> Double? {
        guard f.count == 11 else { return nil }
        let z = (0..<11).map { (f[$0] - mean[$0]) / scale[$0] }
        var nearest = Double.greatestFiniteMagnitude
        for c in centres {
            var d = 0.0
            for i in 0..<11 { let e = z[i] - c[i]; d += e * e }
            nearest = min(nearest, d)
        }
        guard nearest <= gate else { return nil }
        let h1 = zip(w1, b1).map { row, b in max(0, zip(row, z).reduce(b) { $0 + $1.0 * $1.1 }) }
        let h2 = zip(w2, b2).map { row, b in max(0, zip(row, h1).reduce(b) { $0 + $1.0 * $1.1 }) }
        let o = zip(w3, h2).reduce(b3) { $0 + $1.0 * $1.1 }
        let raw = o > 20 ? o : log1p(exp(o))                     // softplus
        return max(0, calibrated(raw))
    }

    /// Monotone piecewise-linear map from the network's quantiles to the true speed quantiles,
    /// extended past the top point along the slope of the last four segments.
    private func calibrated(_ p: Double) -> Double {
        var x = calIn, y = calOut
        for i in 1..<x.count { x[i] = max(x[i], x[i - 1]); y[i] = max(y[i], y[i - 1]) }
        if p <= x[0] { return y[0] }
        let n = x.count
        if p > x[n - 1] {
            let slope = (y[n - 1] - y[n - 5]) / max(x[n - 1] - x[n - 5], 1e-6)
            return y[n - 1] + (p - x[n - 1]) * slope
        }
        var j = 1
        while j < n - 1 && x[j] < p { j += 1 }
        let span = x[j] - x[j - 1]
        return span > 0 ? y[j - 1] + (p - x[j - 1]) / span * (y[j] - y[j - 1]) : y[j]
    }
}
