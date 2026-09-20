import Foundation
import CoreML
import os.log

/// The neural half of the speed comparison: a recurrent network that reads 40 seconds of
/// vibration instead of the four seconds the nearest-neighbour store sees.
///
/// WHY THIS EXISTS AND WHAT IT IS ALLOWED TO CLAIM. Seven attempts at replacing the old model
/// failed before this one: a per-window CNN, an ensemble of the two, a CNN given the old
/// model's calibration and gates, a CNN with spectral input and augmentation, a residual net
/// stacked on top of the old model and initialised to copy it, and distillation. The first six
/// never beat 10.6 km/h mean error on held-out rides. This one does — 8.9 km/h, with distance
/// landing within 0% — and the reason is not capacity. It is that speed is expressed over tens
/// of seconds and the old model forgets after four. Reading longer was the whole gain.
///
/// It is NOT better everywhere, and the log records both so the claim can be checked rather
/// than trusted:
///
///     ground (46 rides, held out)   old 10.6 km/h  +1%      this net 8.9 km/h   0%
///     flight (one flight)           old 34.4 km/h  +1%      this net 57.1 km/h +10%
///
/// So in the air it declines and the old model answers. It was trained on ground rides only,
/// and a model that has never seen cruise has nothing to say about it.
///
/// Two further things it gives up, which is why the old model is still the default: the store
/// learns roughly 450 new samples from every ride with no retraining, and it answers from the
/// first four seconds rather than needing forty.
final class NeuralSpeedEstimator {

    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "euleryu.gps",
                                   category: "NeuralSpeed")

    // MARK: - Shape, fixed at export time

    private let contextWindows = 80      // 80 windows x 0.5 s = 40 s of context
    private let featureCount = 11
    /// One feature vector per 25 accelerometer samples — 0.5 s at 50 Hz, matching the stride
    /// the net was trained on. Paced by sample count rather than by wall clock so a device
    /// delivering motion at something other than exactly 50 Hz still feeds it the same way the
    /// training data was built.
    let strideSamples = 25

    // MARK: - Loaded state

    private var model: MLModel?
    private var calibrationIn: [Double] = []
    private var calibrationOut: [Double] = []
    private var inputArray: MLMultiArray?

    /// Which compute units Core ML actually assigned the work to, counted per operation.
    /// Requested `.all`, which permits the Neural Engine — but a GRU is a recurrent layer and
    /// the Neural Engine does not take those, so in practice this reports GPU and CPU. Logged
    /// as measured rather than as hoped.
    private(set) var computePlacement = "not loaded"
    private(set) var loadStatus = "loading"
    private(set) var isLoaded = false

    // MARK: - Rolling context

    /// The rolling context is written on the motion queue, 50 times a second, and read on the
    /// tick thread. Swift enforces exclusive access to a class's stored properties at runtime,
    /// so an unguarded `ring[i] = x` landing during a read is not a stale number, it is a trap.
    private let lock = NSLock()
    private var ring: [Float]
    private var ringWindows = 0
    private var ringIndex = 0
    private var hasNewWindowSinceEstimate = false

    private(set) var lastRawAnswer: Double?      // km/h before calibration
    private(set) var lastAnswer: Double?         // m/s after calibration
    private(set) var lastCost = InferenceCost()
    private(set) var sessionCost = InferenceCost()
    private(set) var windowsSeen = 0

    /// How much more context it needs before it will answer at all.
    var warmupWindowsRemaining: Int {
        lock.lock(); defer { lock.unlock() }
        return max(0, contextWindows - ringWindows)
    }

    init() {
        ring = [Float](repeating: 0, count: contextWindows * featureCount)
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.load() }
    }

    // MARK: - Loading

    private func load() {
        guard let metaURL = Bundle.main.url(forResource: "speed_gru_meta", withExtension: "json"),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] else {
            loadStatus = "meta json missing"
            os_log("neural speed model: %{public}@", log: Self.log, type: .error, loadStatus)
            return
        }
        calibrationIn = (meta["calibrationIn"] as? [Double]) ?? []
        calibrationOut = (meta["calibrationOut"] as? [Double]) ?? []

        let config = MLModelConfiguration()
        // Let Core ML place the work wherever it runs best, Neural Engine included. What it
        // actually chose is read back below rather than assumed.
        config.computeUnits = .all

        let loaded: MLModel
        do {
            loaded = try Self.loadModel(configuration: config)
        } catch {
            loadStatus = "load failed: \(error.localizedDescription)"
            os_log("neural speed model: %{public}@", log: Self.log, type: .error, loadStatus)
            return
        }

        // SELF-CHECK. The weights were trained in PyTorch and converted; the conversion agreed
        // with PyTorch to 0.00025 km/h on the Mac. Confirm that still holds on this device
        // before the model is allowed to drive a recorded route.
        if let check = meta["selfCheckInput"] as? [Double],
           let expected = meta["selfCheckRawOutput"] as? Double,
           check.count == contextWindows * featureCount {
            if let got = Self.rawPredict(model: loaded, flatFeatures: check.map { Float($0) },
                                         shape: [1, contextWindows, featureCount]) {
                let delta = abs(got - expected)
                guard delta < 0.5 else {
                    loadStatus = String(format: "self-check FAILED: %.4f vs %.4f", got, expected)
                    os_log("neural speed model: %{public}@", log: Self.log, type: .fault, loadStatus)
                    return
                }
                loadStatus = String(format: "ok, self-check %.4f vs %.4f", got, expected)
            } else {
                loadStatus = "self-check could not run"
                return
            }
        } else {
            loadStatus = "ok, no self-check vector"
        }

        inputArray = try? MLMultiArray(shape: [1, NSNumber(value: contextWindows),
                                               NSNumber(value: featureCount)], dataType: .float32)
        model = loaded
        isLoaded = true
        os_log("neural speed model: %{public}@", log: Self.log, type: .info, loadStatus)
        readComputePlacement(configuration: config)
    }

    /// Xcode's Core ML build rule turns the .mlpackage into a compiled .mlmodelc in the bundle.
    /// If for any reason it did not, fall back to compiling the package at first run and caching
    /// the result, so the model ships either way.
    private static func loadModel(configuration: MLModelConfiguration) throws -> MLModel {
        let name = "SpeedGRU"
        if let compiled = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }
        guard let pkg = Bundle.main.url(forResource: name, withExtension: "mlpackage") else {
            throw NSError(domain: "NeuralSpeedEstimator", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) not in the bundle"])
        }
        let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
        let cached = cacheDir.appendingPathComponent("\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: cached.path) {
            if let m = try? MLModel(contentsOf: cached, configuration: configuration) { return m }
            try? FileManager.default.removeItem(at: cached)
        }
        let built = try MLModel.compileModel(at: pkg)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: cached)
        try? FileManager.default.copyItem(at: built, to: cached)
        let url = FileManager.default.fileExists(atPath: cached.path) ? cached : built
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    /// Ask Core ML which device it plans to run each operation on. This is the only honest way
    /// to answer "is it using the Neural Engine" — the framework will silently place work
    /// wherever it likes and never mentions it.
    private func readComputePlacement(configuration: MLModelConfiguration) {
        guard #available(iOS 17.4, *) else {
            computePlacement = "placement unavailable before iOS 17.4"
            return
        }
        let name = "SpeedGRU"
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: name, withExtension: "mlpackage") else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
                guard case let .program(program) = plan.modelStructure,
                      let main = program.functions["main"] else {
                    self.computePlacement = "plan has no program"
                    return
                }
                var counts: [String: Int] = [:]
                for op in main.block.operations {
                    guard let usage = plan.deviceUsage(for: op) else { continue }
                    // MLComputeDevice is an enum, not a class hierarchy — matching on the
                    // types silently reports every operation as "other".
                    let name: String
                    switch usage.preferred {
                    case .cpu: name = "CPU"
                    case .gpu: name = "GPU"
                    case .neuralEngine: name = "ANE"
                    @unknown default: name = "other"
                    }
                    counts[name, default: 0] += 1
                }
                self.computePlacement = counts.isEmpty
                    ? "no placement reported"
                    : counts.sorted { $0.value > $1.value }
                            .map { "\($0.key) \($0.value)" }.joined(separator: " / ")
                os_log("neural speed model placement: %{public}@", log: Self.log, type: .info,
                       self.computePlacement)
            } catch {
                self.computePlacement = "plan failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Feeding

    func beginSession() {
        lock.lock()
        defer { lock.unlock() }
        ring = [Float](repeating: 0, count: contextWindows * featureCount)
        ringWindows = 0
        ringIndex = 0
        hasNewWindowSinceEstimate = false
        lastRawAnswer = nil
        lastAnswer = nil
        windowsSeen = 0
        sessionCost = InferenceCost()
        lastCost = InferenceCost()
    }

    /// Called with the SAME feature vector the old model uses, from the same window, so the two
    /// are compared on identical input and any difference is the estimator rather than the
    /// front end.
    func ingest(features: [Double]) {
        guard features.count == featureCount else { return }
        lock.lock()
        let base = ringIndex * featureCount
        for i in 0..<featureCount { ring[base + i] = Float(features[i]) }
        ringIndex = (ringIndex + 1) % contextWindows
        if ringWindows < contextWindows { ringWindows += 1 }
        windowsSeen += 1
        hasNewWindowSinceEstimate = true
        lock.unlock()
    }

    // MARK: - Answering

    /// Speed in m/s, or nil when it has nothing trustworthy to say: still loading, not yet 40
    /// seconds of context, or airborne — where it was measured at 57 km/h mean error against
    /// the old model's 34, having never been trained on a flight.
    func estimate(airborne: Bool) -> Double? {
        guard !airborne else { return nil }
        guard let model, let array = inputArray else { return nil }

        // Copy the context out under the lock and let go of it before the model runs: inference
        // takes milliseconds and the motion queue must not wait on it.
        lock.lock()
        guard ringWindows >= contextWindows else { lock.unlock(); return nil }
        if !hasNewWindowSinceEstimate, let held = lastAnswer { lock.unlock(); return held }
        // Oldest window first, matching how the training sequences were cut.
        array.withUnsafeMutableBytes { raw, _ in
            guard let dst = raw.bindMemory(to: Float.self).baseAddress else { return }
            for w in 0..<contextWindows {
                let src = ((ringIndex + w) % contextWindows) * featureCount
                for i in 0..<featureCount { dst[w * featureCount + i] = ring[src + i] }
            }
        }
        hasNewWindowSinceEstimate = false
        lock.unlock()

        let (raw, cost) = PowerMeter.measure { () -> Double? in
            guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(
                dictionary: ["features": MLFeatureValue(multiArray: array)])) else { return nil }
            guard let v = out.featureValue(for: "speed")?.multiArrayValue else { return nil }
            return v[0].doubleValue
        }
        lastCost = cost
        sessionCost.accumulate(cost)
        guard let raw else { return lastAnswer }
        lastRawAnswer = raw
        let kmh = calibrated(raw)
        lastAnswer = kmh / 3.6
        return lastAnswer
    }

    private static func rawPredict(model: MLModel, flatFeatures: [Float], shape: [Int]) -> Double? {
        guard let array = try? MLMultiArray(shape: shape.map { NSNumber(value: $0) },
                                            dataType: .float32) else { return nil }
        array.withUnsafeMutableBytes { raw, _ in
            guard let dst = raw.bindMemory(to: Float.self).baseAddress else { return }
            for i in 0..<flatFeatures.count { dst[i] = flatFeatures[i] }
        }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["features": MLFeatureValue(multiArray: array)])),
              let v = out.featureValue(for: "speed")?.multiArrayValue else { return nil }
        return v[0].doubleValue
    }

    /// The same quantile mapping the old model uses, fitted at export time on a slice held out
    /// of training. It maps the distribution of the net's answers onto the distribution of real
    /// speeds, which is what fixed the slow-speed over-read on the old model and is applied here
    /// so the two are calibrated the same way. Deliberately no upper clamp.
    private func calibrated(_ raw: Double) -> Double {
        guard calibrationIn.count >= 2, calibrationIn.count == calibrationOut.count else {
            return max(0, raw)
        }
        if raw <= calibrationIn[0] {
            return max(0, calibrationOut[0] * (raw / max(calibrationIn[0], 1e-6)))
        }
        if raw >= calibrationIn[calibrationIn.count - 1] {
            let n = calibrationIn.count
            let slope = (calibrationOut[n - 1] - calibrationOut[n - 2])
                / max(calibrationIn[n - 1] - calibrationIn[n - 2], 1e-9)
            return max(0, calibrationOut[n - 1] + slope * (raw - calibrationIn[n - 1]))
        }
        var lo = 0, hi = calibrationIn.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if calibrationIn[mid] <= raw { lo = mid } else { hi = mid }
        }
        let t = (raw - calibrationIn[lo]) / max(calibrationIn[hi] - calibrationIn[lo], 1e-9)
        return max(0, calibrationOut[lo] + t * (calibrationOut[hi] - calibrationOut[lo]))
    }

    /// For the developer screen.
    var summary: String {
        var lines = ["status: \(loadStatus)", "placement: \(computePlacement)"]
        lines.append("context: \(ringWindows)/\(contextWindows) windows"
                     + (warmupWindowsRemaining > 0
                        ? " (\(Int(Double(warmupWindowsRemaining) * 0.5)) s to go)" : " (ready)"))
        if sessionCost.calls > 0 {
            lines.append(String(format: "per call: %.2f ms wall, %.2f ms cpu",
                                sessionCost.wallMicros / Double(sessionCost.calls) / 1000,
                                sessionCost.cpuMicros / Double(sessionCost.calls) / 1000))
            lines.append(String(format: "session: %d calls, %.1f mJ, %.0f ms gpu",
                                sessionCost.calls,
                                Double(sessionCost.energyNanojoules) / 1e6,
                                Double(sessionCost.gpuNanos) / 1e6))
        }
        if let raw = lastRawAnswer, let cal = lastAnswer {
            lines.append(String(format: "last: %.1f raw -> %.1f km/h", raw, cal * 3.6))
        }
        return lines.joined(separator: "\n")
    }
}
