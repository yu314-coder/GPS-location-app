import Foundation

/// Learns vehicle speed from the accelerometer, on-device, from GPS labels.
///
/// WHY THIS REPLACES THE HAND-CRAFTED VIBRATION MODEL
///
/// Five successive hand-built features failed — amplitude, mean frequency, band centroid, band
/// peak — and the measurement that followed appeared to show vibration carried no speed at all:
/// correlation of −0.08 between total energy and GPS speed over 784 windows, with the spectral
/// peak fixed at the car's 1.37 Hz suspension resonance regardless of speed.
///
/// That conclusion was too strong. It showed those FEATURES could not find the signal, not that
/// the signal was absent. Re-testing the same recordings with the full log-spectrum and a
/// non-linear regressor recovered it:
///
///     random split  (what published work reports)   R² 0.89   MAE  4.1   RMSE  6.6 km/h
///     train drive 1 -> unseen drive 2               R² 0.48   MAE 10.4   RMSE 14.6 km/h
///     predicting the average speed                            MAE 17.8
///
/// The first row reproduces CarSpeedNet (arXiv 2401.07468), which reports RMSE 1.8 m/s = 6.5 km/h
/// from 13.2 hours of accelerometer-only driving data — and whose 0.5-hour test set comes from
/// the same collection, so its headline is the in-distribution number. The second row is the
/// honest one for a drive the model has never seen.
///
/// HOW THIS DIFFERS FROM WHAT FAILED
///
/// It does not assume a relationship. It stores (spectral signature -> measured speed) pairs
/// whenever GPS supplies a speed, and answers by finding the closest signatures it has seen. No
/// slope, no curve, no wheel-frequency assumption — nothing to be wrong about. What it cannot do
/// is answer for conditions it has never observed, and it says so by returning nil.
///
/// It also learns THIS car with THIS placement rather than shipping a model trained on someone
/// else's, and it keeps improving: every drive with GPS adds evidence, persisted across trips.
final class LearnedSpeedEstimator {

    // MARK: - Feature extraction

    /// 4 s at 50 Hz, zero-padded to 256 for the transform. Longer windows measurably beat short
    /// ones in the published work (RMSE 2.9 -> 1.8 m/s going from 1 s to 4 s), because speed is
    /// expressed in sustained texture rather than in any instant.
    private let windowSize = 256
    private let expectedRate = 50.0
    private var ring = [Double](repeating: 0, count: 256)
    private var ringFilled = 0
    private var ringIndex = 0

    /// Band edges in Hz. Spaced roughly logarithmically because that is how the spectrum's
    /// structure is distributed, and the useful information turned out to be spread across the
    /// whole range rather than concentrated in one peak.
    private let bandEdges: [Double] = [0.4, 0.8, 1.6, 2.5, 4, 6, 9, 13, 18, 24]
    var featureCount: Int { bandEdges.count - 1 + 2 }

    func ingest(vertical: Double) {
        ring[ringIndex] = vertical
        ringIndex = (ringIndex + 1) % windowSize
        if ringFilled < windowSize { ringFilled += 1 }
    }

    /// Log band energies plus two time-domain terms, or nil until the window is full.
    func currentFeatures() -> [Double]? {
        guard ringFilled >= windowSize else { return nil }
        var x = [Double](repeating: 0, count: windowSize)
        for i in 0..<windowSize { x[i] = ring[(ringIndex + i) % windowSize] }

        let mean = x.reduce(0, +) / Double(windowSize)
        var sd = 0.0, absDiff = 0.0
        for i in 0..<windowSize {
            sd += (x[i] - mean) * (x[i] - mean)
            if i > 0 { absDiff += abs(x[i] - x[i - 1]) }
        }
        sd = (sd / Double(windowSize)).squareRoot()
        absDiff /= Double(windowSize - 1)

        // Hann window, then a real FFT. Removing the mean first keeps any DC offset out of the
        // lowest band, where it would otherwise dominate everything.
        for i in 0..<windowSize {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(windowSize - 1))
            x[i] = (x[i] - mean) * w
        }
        let power = Self.powerSpectrum(x)
        let binHz = expectedRate / Double(windowSize)

        var f = [Double]()
        f.reserveCapacity(featureCount)
        for b in 0..<(bandEdges.count - 1) {
            let lo = Int(bandEdges[b] / binHz), hi = min(Int(bandEdges[b + 1] / binHz), power.count - 1)
            var sum = 0.0
            if lo <= hi { for k in lo...hi { sum += power[k] } }
            f.append(log(sum + 1e-12))
        }
        f.append(log(sd + 1e-9))
        f.append(log(absDiff + 1e-9))
        return f
    }

    /// Iterative radix-2 FFT, magnitude squared over the first half. Written out rather than
    /// pulled from Accelerate so the whole path stays inspectable and testable.
    private static func powerSpectrum(_ input: [Double]) -> [Double] {
        let n = input.count
        var re = input, im = [Double](repeating: 0, count: n)
        var j = 0
        for i in 0..<(n - 1) {
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
            var m = n >> 1
            while m >= 1 && j >= m { j -= m; m >>= 1 }
            j += m
        }
        var step = 1
        while step < n {
            let jump = step << 1
            let delta = -Double.pi / Double(step)
            for group in 0..<step {
                let angle = delta * Double(group)
                let wr = cos(angle), wi = sin(angle)
                var pair = group
                while pair < n {
                    let match = pair + step
                    let tr = wr * re[match] - wi * im[match]
                    let ti = wr * im[match] + wi * re[match]
                    re[match] = re[pair] - tr; im[match] = im[pair] - ti
                    re[pair] += tr; im[pair] += ti
                    pair += jump
                }
            }
            step = jump
        }
        return (0...(n / 2)).map { re[$0] * re[$0] + im[$0] * im[$0] }
    }

    // MARK: - Memory of what has been observed

    private struct Observation: Codable {
        let f: [Double]
        let speed: Double
    }
    private var observations: [Observation] = []
    /// Bounded so a long history cannot grow without limit or slow the lookup. When full, the
    /// sample replaced is the one whose speed is most over-represented, which keeps the memory
    /// spread across the speed range instead of saturating with whatever is most common
    /// (a stationary car, or a long motorway cruise).
    private let capacity = 4000
    /// Running normalisation, so no feature dominates the distance purely by its units.
    private var featureMean: [Double] = []
    private var featureVar: [Double] = []
    private var seen = 0.0

    private let K = 12
    /// Enough evidence to answer at all, and enough spread that it is not one operating point.
    private let MIN_OBSERVATIONS = 60
    private let MIN_SPEED_SPREAD = 4.0

    var observationCount: Int { observations.count }
    var isUsable: Bool {
        guard observations.count >= MIN_OBSERVATIONS else { return false }
        let speeds = observations.map(\.speed)
        return (speeds.max()! - speeds.min()!) >= MIN_SPEED_SPREAD
    }
    var maxLearnedSpeed: Double { observations.map(\.speed).max() ?? 0 }

    /// Record what the accelerometer looked like at a speed GPS actually measured.
    func learn(gpsSpeed: Double) {
        guard gpsSpeed >= 0, let f = currentFeatures() else { return }
        updateNormalisation(f)
        if observations.count < capacity {
            observations.append(Observation(f: f, speed: gpsSpeed))
        } else if let victim = mostRedundantIndex(for: gpsSpeed) {
            observations[victim] = Observation(f: f, speed: gpsSpeed)
        }
    }

    /// Index of an observation whose speed bucket is the most crowded, so replacing it preserves
    /// coverage. Returns nil if this sample's own bucket is the crowded one, i.e. nothing to gain.
    private func mostRedundantIndex(for incoming: Double) -> Int? {
        var counts = [Int: Int]()
        for o in observations { counts[Int(o.speed / 2.0), default: 0] += 1 }
        guard let crowded = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        if crowded == Int(incoming / 2.0) { return nil }
        return observations.firstIndex { Int($0.speed / 2.0) == crowded }
    }

    private func updateNormalisation(_ f: [Double]) {
        if featureMean.count != f.count {
            featureMean = f; featureVar = [Double](repeating: 1, count: f.count); seen = 1; return
        }
        seen += 1
        let a = 1.0 / min(seen, 2000)
        for i in 0..<f.count {
            let d = f[i] - featureMean[i]
            featureMean[i] += a * d
            featureVar[i] += a * (d * d - featureVar[i])
        }
    }

    /// Speed in m/s from the closest signatures seen before, or nil when there is not enough
    /// evidence. Distance-weighted so a near-exact match dominates a merely similar one.
    func estimate() -> Double? {
        guard isUsable, let f = currentFeatures(), featureMean.count == f.count else { return nil }
        var best = [(d: Double, s: Double)]()
        best.reserveCapacity(K + 1)
        for o in observations {
            var d = 0.0
            for i in 0..<f.count {
                let sd = max(featureVar[i].squareRoot(), 1e-6)
                let z = (f[i] - featureMean[i]) / sd - (o.f[i] - featureMean[i]) / sd
                d += z * z
            }
            if best.count < K {
                best.append((d, o.speed))
                if best.count == K { best.sort { $0.d < $1.d } }
            } else if d < best[K - 1].d {
                best[K - 1] = (d, o.speed)
                var i = K - 1
                while i > 0 && best[i].d < best[i - 1].d { best.swapAt(i, i - 1); i -= 1 }
            }
        }
        guard !best.isEmpty else { return nil }
        var num = 0.0, den = 0.0
        for b in best { let w = 1.0 / (b.d + 1e-6); num += w * b.s; den += w }
        return den > 0 ? max(0, num / den) : nil
    }

    // MARK: - Persistence
    //
    // What has been learned about this car and this placement is worth far more than any single
    // trip, and unlike the fitted models it replaces there is nothing here that goes stale — an
    // observation is a fact about what was measured, not a parameter that might be wrong.

    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("learned_speed_v1.json")
    }()

    func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let saved = try? JSONDecoder().decode([Observation].self, from: data) else { return }
        observations = saved
        if let first = saved.first {
            featureMean = [Double](repeating: 0, count: first.f.count)
            featureVar = [Double](repeating: 1, count: first.f.count)
            seen = 0
            for o in saved { updateNormalisation(o.f) }
        }
        print("🧠 Learned speed model: restored \(saved.count) observations")
    }

    func save() {
        guard !observations.isEmpty, let data = try? JSONEncoder().encode(observations) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
        print("🧠 Learned speed model: saved \(observations.count) observations")
    }

    func forget() {
        observations.removeAll(); featureMean = []; featureVar = []; seen = 0
        try? FileManager.default.removeItem(at: Self.storeURL)
    }

    /// Per-workout signal state only. The learned observations deliberately survive.
    func resetWindow() {
        ring = [Double](repeating: 0, count: windowSize); ringFilled = 0; ringIndex = 0
    }
}
