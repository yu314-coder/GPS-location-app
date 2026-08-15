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
        /// AIR AND GROUND ARE SEPARATE MEMORIES.
        ///
        /// One store for both is wrong in BOTH directions, and each direction has now been
        /// measured. A ground-only model answering in the air reported 19 km/h at a 900 km/h
        /// cruise, because cruise is quieter than taxiing and the slowest thing it knew was the
        /// closest match. Then the flight's own observations went into the same store, and on the
        /// next car journey it reported a mean of 337 km/h against a true 30 - peaking at 580 -
        /// because a smooth road is also quiet and now matched a cruise signature.
        ///
        /// The mistake is treating "quiet" as one thing. Quiet in a car means slow; quiet at
        /// altitude means fast. No single nearest-neighbour lookup can hold both, so the lookup
        /// is partitioned and only ever searches the regime it is currently in.
        var airborne: Bool = false
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
    /// Squared distance in normalised feature space beyond which the closest stored signature is
    /// too dissimilar to answer from. 2.0 squared; see estimate() for the measurements.
    private let MAX_MATCH_DISTANCE_SQUARED = 4.0
    /// Enough evidence to answer at all, and enough spread that it is not one operating point.
    private let MIN_OBSERVATIONS = 60
    private let MIN_SPEED_SPREAD = 4.0

    var observationCount: Int { observations.count }
    /// Judged within one regime: a store full of flight data does not make the ground model
    /// usable, and vice versa.
    func isUsable(airborne: Bool) -> Bool {
        let speeds = observations.filter { $0.airborne == airborne }.map(\.speed)
        guard speeds.count >= MIN_OBSERVATIONS else { return false }
        return (speeds.max()! - speeds.min()!) >= MIN_SPEED_SPREAD
    }
    var isUsable: Bool { isUsable(airborne: false) || isUsable(airborne: true) }
    var maxLearnedSpeed: Double { observations.map(\.speed).max() ?? 0 }
    var airborneObservationCount: Int { observations.filter(\.airborne).count }
    /// The compression correction currently in force, so a log can distinguish "the model has
    /// never seen this speed" from "it has, and the correction for its flattening is not being
    /// applied". Those need opposite fixes and look identical from the outside.
    var calibration: (slope: Double, intercept: Double) { (calibrationSlope, calibrationIntercept) }
    var quarantinedCount: Int { quarantined.count }

    /// Observations recorded while Velocity Mode was forced. Held apart from the searchable
    /// store until the workout ends — see learn(gpsSpeed:quarantined:).
    private var quarantined: [Observation] = []

    /// Record what the accelerometer looked like at a speed GPS actually measured.
    ///
    /// `quarantined` exists because of a leak that made Velocity Mode dishonest. Teaching the
    /// model from a live fix and then estimating from the SAME 4-second window means the
    /// nearest neighbour is the observation just stored: its distance is ~0, its weight is
    /// enormous, and the answer collapses onto the GPS speed that was just handed in. The mode
    /// exists to predict what happens when GPS is gone, so a reading secretly sourced from GPS
    /// makes it a test that cannot fail — it would look excellent on the ground and reveal
    /// nothing about a flight.
    ///
    /// Discarding the evidence would be the wrong fix: these are exactly the labelled samples
    /// the model needs, and forced sessions are when most driving happens here. So keep them,
    /// but out of reach — they join the searchable store when the workout ends, teaching the
    /// NEXT trip while contributing nothing to this one's estimate.
    func learn(gpsSpeed: Double, quarantined isQuarantined: Bool = false, airborne: Bool = false) {
        guard gpsSpeed >= 0, let f = currentFeatures() else { return }
        updateNormalisation(f)
        let observation = Observation(f: f, speed: gpsSpeed, airborne: airborne)
        if isQuarantined {
            if quarantined.count < capacity { quarantined.append(observation) }
            return
        }
        insert(observation)
        // Re-measure the model's own compression as evidence accumulates. Rare enough that the
        // leave-one-out pass costs nothing noticeable, often enough that a drive which visits
        // new speeds is reflected before the next one.
        sinceLastCalibration += 1
        if sinceLastCalibration >= 200 {
            sinceLastCalibration = 0
            observationsAtLastCalibration = 0
            recalibrate()
        }
    }
    private var sinceLastCalibration = 0

    private func insert(_ observation: Observation) {
        if observations.count < capacity {
            observations.append(observation)
        } else if let victim = mostRedundantIndex(for: observation.speed) {
            observations[victim] = observation
        }
    }

    /// Fold everything learned during a forced session into the searchable store. Called when
    /// the workout ends, so the evidence is never available to the estimate that produced it.
    func commitQuarantinedObservations() {
        guard !quarantined.isEmpty else { return }
        let count = quarantined.count
        for o in quarantined { insert(o) }
        quarantined.removeAll()
        observationsAtLastCalibration = 0
        recalibrate()
        print("🧠 Learned speed model: folded in \(count) observations held back during Velocity Mode")
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
    func estimate(airborne: Bool = false) -> Double? {
        guard isUsable(airborne: airborne), let f = currentFeatures(), featureMean.count == f.count else { return nil }
        var best = [(d: Double, s: Double)]()
        best.reserveCapacity(K + 1)
        for o in observations where o.airborne == airborne {
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

        // REFUSE TO ANSWER FROM A DISTANT MATCH.
        //
        // A nearest-neighbour lookup always produces a number, even when nothing resembling the
        // current signature has ever been seen — and that is where its worst answers come from.
        // Reported live: 70 km/h while the car was stationary, alongside readings that were
        // "quite accurate" at other times. Measured on a real drive, error scales directly with
        // how far the closest stored signature actually is:
        //
        //     nearest distance   < 1.03   1.03-1.35   1.35-2.12   2.12-4.36
        //     MAE                5.3      7.1         11.0        16.9  km/h
        //
        // Beyond about 2 the answer is worse than useless. Declining there costs a quarter of
        // the ticks and takes MAE from 9.3 to 7.8 on the rest; the declined ticks fall through
        // to the last GPS-measured speed, which is a far better guess than an unrecognised
        // signature. Knowing when it does not know is the property a lookup can offer and a
        // fitted curve cannot.
        if best[0].d > MAX_MATCH_DISTANCE_SQUARED { return nil }

        var num = 0.0, den = 0.0
        for b in best { let w = 1.0 / (b.d + 1e-6); num += w * b.s; den += w }
        guard den > 0 else { return nil }
        // The compression curve is fitted on GROUND observations, where there are thousands of
        // them. Applying it to the air partition would be extrapolating a road correction into a
        // regime it has never seen, so the air answers raw until it has enough of its own.
        return max(0, airborne ? num / den : calibrated(num / den))
    }

    // MARK: - Self-calibration against its own measured bias

    /// A weighted average of neighbours is a LOCAL CONSTANT fit, and every local constant fit
    /// regresses to the mean: near the top of the speeds ever seen, all twelve neighbours lie
    /// below the query, so the answer is dragged down; near the bottom they all lie above, so
    /// it is dragged up. That is not a tuning problem, it is what averaging does at the edges
    /// of a distribution, and it showed up on a real drive as a straight line through the
    /// middle of the range (velocity_debug_20260811_085038):
    ///
    ///     true  14.6  24.8  35.1  46.3  55.7  63.6  72.3 km/h
    ///     est   20.7  28.1  36.7  42.0  48.1  48.6  51.1 km/h
    ///
    /// A slope of about 0.53 — the estimate moves half as far as the road does, which under-
    /// reports every fast stretch and over-reports every slow one. Correcting it needs no new
    /// sensor and no new assumption: the compression is measurable from the observations
    /// already stored, by predicting each one from the others and regressing what was predicted
    /// against what GPS actually measured. Inverting that line removes the bias, and because it
    /// is re-measured as evidence accumulates, it tracks this phone and this car rather than a
    /// constant baked in from one drive.
    private var calibrationSlope: Double = 1.0
    private var calibrationIntercept: Double = 0.0
    private var observationsAtLastCalibration = 0
    /// Piecewise (estimate -> actual) points, ascending. A STRAIGHT LINE CANNOT UNDO A
    /// SATURATION, and the flattening is a saturation: on one drive the estimate sat at about
    /// 45 km/h whether the road was doing 60, 70 or 80, while the fitted slope came out at 1.05
    /// because the bulk of the data is slow and fits fine. Correcting the top of the range
    /// needs a curve, and one measured the same way — each stored observation predicted from
    /// the others, so it is out-of-sample by construction.
    ///
    /// Tested by fitting on one drive and scoring on another, all six ordered pairs of three
    /// drives. The curve beat the line on error in every one, and average distance bias across
    /// them fell from 21% to 10%.
    private var calibrationCurve: [(estimate: Double, actual: Double)] = []

    private func calibrated(_ raw: Double) -> Double {
        guard calibrationCurve.count >= 2 else {
            return calibrationIntercept + calibrationSlope * raw
        }
        // BELOW THE FIRST BIN, RUN TO THE ORIGIN — do not clamp to it.
        //
        // The curve is fitted on MOVING observations only, so its lowest bin sits around 5 km/h.
        // Clamping everything below that to the bin's value meant a stopped car reading 0.5 km/h
        // came out at 5-8. Measured on a 16-minute drive: 345 seconds of near-stationary traffic
        // reported at 7.9 km/h against a true 1.0, about 660 m of invented distance — which was
        // quietly cancelling the shortfall at the top of the range and making the total look
        // better than either half deserved.
        //
        // Zero estimate means zero speed, so interpolate from the origin instead.
        if raw <= calibrationCurve[0].estimate {
            let first = calibrationCurve[0]
            guard first.estimate > 1e-6 else { return first.actual }
            return first.actual * (raw / first.estimate)
        }
        for i in 1..<calibrationCurve.count where raw <= calibrationCurve[i].estimate {
            let a = calibrationCurve[i - 1], b = calibrationCurve[i]
            let span = max(b.estimate - a.estimate, 1e-9)
            return a.actual + (b.actual - a.actual) * (raw - a.estimate) / span
        }
        // Above everything ever predicted: continue the last segment rather than clamping, so a
        // faster road than any yet seen is not pinned to the top of the curve.
        let a = calibrationCurve[calibrationCurve.count - 2], b = calibrationCurve[calibrationCurve.count - 1]
        let span = max(b.estimate - a.estimate, 1e-9)
        return b.actual + (b.actual - a.actual) / span * (raw - b.estimate)
    }

    /// Leave-one-out over a sample of the stored observations: predict each from the others and
    /// fit actual ≈ intercept + slope × predicted. Sampled and capped so the cost stays bounded
    /// as the store fills, and only adopted when the fit is sane — a degenerate or wild fit
    /// leaves the estimate uncorrected rather than making it worse.
    func recalibrate() {
        guard observations.count >= MIN_OBSERVATIONS * 2, !featureMean.isEmpty else { return }
        guard observations.count != observationsAtLastCalibration else { return }
        observationsAtLastCalibration = observations.count

        let stride = max(1, observations.count / 300)
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        var samples: [(predicted: Double, actual: Double)] = []
        var index = 0
        while index < observations.count {
            let held = observations[index]
            // Fit on the MOVING regime only. Stationary samples are the most numerous thing in
            // the store and would dominate a least-squares fit, flattening the very slope being
            // measured; and a stopped vehicle is now recognised directly rather than estimated,
            // so the correction has no reason to describe it. Measured on the drive above:
            // fitting on everything gives x1.15 and MAE 5.3, fitting on movement x1.26 and 5.0.
            guard held.speed >= 1.5, !held.airborne else { index += stride; continue }
            var best = [(d: Double, s: Double)]()
            best.reserveCapacity(K)
            for (j, o) in observations.enumerated() where j != index && !o.airborne {
                var d = 0.0
                for i in 0..<held.f.count {
                    let sd = max(featureVar[i].squareRoot(), 1e-6)
                    let z = (held.f[i] - o.f[i]) / sd
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
            index += stride
            guard best.count == K, best[0].d <= MAX_MATCH_DISTANCE_SQUARED else { continue }
            var num = 0.0, den = 0.0
            for b in best { let w = 1.0 / (b.d + 1e-6); num += w * b.s; den += w }
            guard den > 0 else { continue }
            let predicted = num / den
            n += 1; sx += predicted; sy += held.speed
            sxx += predicted * predicted; sxy += predicted * held.speed
            samples.append((predicted, held.speed))
        }

        guard n >= 40 else { return }
        // The curve, in equal-count bins so every part of the range carries the same evidence.
        samples.sort { $0.predicted < $1.predicted }
        let binCount = min(8, max(2, samples.count / 20))
        let perBin = samples.count / binCount
        var curve: [(estimate: Double, actual: Double)] = []
        var binStart = 0
        while binStart + perBin <= samples.count, curve.count < binCount {
            let chunk = samples[binStart..<(binStart + perBin)]
            let meanPredicted = chunk.reduce(0.0) { $0 + $1.predicted } / Double(chunk.count)
            var meanActual = chunk.reduce(0.0) { $0 + $1.actual } / Double(chunk.count)
            // Monotone: a faster signature must never map to a slower answer, whatever the
            // sampling noise in one bin says.
            if let previous = curve.last, meanActual < previous.actual { meanActual = previous.actual }
            curve.append((meanPredicted, meanActual))
            binStart += perBin
        }
        calibrationCurve = curve.count >= 4 ? curve : []
        if !calibrationCurve.isEmpty {
            print("🧠 Learned speed curve over \(Int(n)) held-out samples: " +
                  calibrationCurve.map { String(format: "%.0f→%.0f", $0.estimate * 3.6, $0.actual * 3.6) }
                      .joined(separator: " "))
        }

        let denominator = n * sxx - sx * sx
        guard abs(denominator) > 1e-9 else { return }
        let slope = (n * sxy - sx * sy) / denominator
        let intercept = (sy - slope * sx) / n
        // A correction that stretches by more than 4x, or shrinks at all, is not a compression
        // being undone — it is a bad fit, and applying it would be worse than leaving the
        // estimate alone.
        guard slope >= 1.0, slope <= 4.0, intercept.isFinite, abs(intercept) < 20.0 else {
            print("🧠 Calibration rejected (slope \(String(format: "%.2f", slope)), intercept \(String(format: "%.1f", intercept)))")
            return
        }
        calibrationSlope = slope
        calibrationIntercept = intercept
        print("🧠 Learned speed calibrated over \(Int(n)) held-out samples: ×\(String(format: "%.2f", slope)) \(String(format: "%+.1f", intercept)) m/s")
    }

    // MARK: - Persistence
    //
    // What has been learned about this car and this placement is worth far more than any single
    // trip, and unlike the fitted models it replaces there is nothing here that goes stale — an
    // observation is a fact about what was measured, not a parameter that might be wrong.

    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // v2: the v1 store holds flight and road observations mixed together with nothing to
        // distinguish them, which is what produced 580 km/h on a car. It cannot be repaired
        // after the fact, so it is abandoned rather than migrated.
        return base.appendingPathComponent("learned_speed_v2.json")
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
        // Re-measure the compression against everything restored, so the first drive after a
        // launch is corrected too rather than waiting for 200 fresh observations.
        recalibrate()
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
