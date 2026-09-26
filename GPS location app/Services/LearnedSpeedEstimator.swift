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

    /// Vibration amplitude of the most recent window, m/s^2. The caller compares it against this
    /// vehicle's own moving level to recognise a standstill; see WorkoutSession.vibrationSaysParked.
    private(set) var lastWindowAmplitude: Double?
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
        lastWindowAmplitude = sd
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
        /// When this was recorded. Only set while quarantined, and only used to decide when a
        /// held-back observation has aged far enough to be safe to answer from.
        var t: Date? = nil
        /// WHICH WORKOUT TAUGHT THIS, so regimes can be told apart later.
        ///
        /// A store that has seen several vehicles and several carries holds several internally
        /// consistent regimes, and a single 4-second window cannot say which one a query belongs
        /// to. Measured: mounted-car sessions sit 0.54-1.70 apart in mean normalised feature
        /// space, mounted-to-in-hand 1.81-2.87, and anything-to-motorcycle 4.30-6.97. A WHOLE
        /// SESSION identifies its regime cleanly where one window cannot.
        ///
        /// Restricting the search to fingerprint-matched sessions was measured and did NOT
        /// predict better (mounted car 4.6 -> 4.1 km/h, in-hand 10.5 -> 10.8, motorcycle 4.0 ->
        /// 4.0), so nothing about the estimate changes yet. What changes is that the evidence
        /// needed to build and check that partition is now being kept, instead of having to be
        /// collected again from scratch once there is a motorcycle ride with usable GPS.
        var session: Int = 0
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
    /// Set by the last estimate() call: true when the answer came from within-session evidence
    /// rather than the store built on previous trips. The distinction has to reach the log,
    /// because only the second kind predicts what happens when GPS has been gone for hours.
    /// Why the store's last lookup gave what it gave - for the log only, never read by the tick.
    enum StoreStatus: String {
        case answered = "answered"
        case tooFewExamples = "too few examples"
        case unlearnedRegime = "unlearned regime"
        case noCloseMatch = "no close match"
        case locallyUnreliable = "locally unreliable"
    }
    private(set) var lastStoreStatus: StoreStatus = .tooFewExamples
    /// The last estimate came from the bundled SpeedNetwork, not the store.
    private(set) var lastEstimateUsedNetwork = false
    /// Below this many ground observations the store is less accurate than the bundled network.
    private let NETWORK_UNTIL_OBSERVATIONS = 3000
    private var groundObservationCount: Int { observations.reduce(0) { $0 + ($1.airborne ? 0 : 1) } }

    /// Fingerprint distance beyond which this workout is a regime the model has never learned,
    /// and its answers about it should not be trusted however close the individual matches look.
    ///
    /// Calibrated against the eight instrumented sessions in the paper: the same vehicle carried
    /// the same way sits 0.54-1.70 apart, the same vehicle carried differently 1.81-2.87, and a
    /// different vehicle 4.30-6.97. Three separates "a carry I can absorb" from "something I have
    /// not seen". The motorcycle-in-pocket ride that produced the worst result yet measured sat
    /// at 3.51 for its whole 19 minutes.
    private let REGIME_DISTANCE_LIMIT = 3.0

    /// How many of this workout's own observations its fingerprint must rest on before the
    /// distance may REFUSE an answer. Twenty is enough to compute one and far too few to act on.
    ///
    /// A motorcycle ride (2026-09-15) collected its first 20 observations while stopping, pulling
    /// away and briefly holding the phone; GPS then stopped reporting a usable speed, so nothing
    /// more was ever learned. The fingerprint froze at 6.12 - "a different vehicle" - on the
    /// same motorcycle that had sat at 0.29-1.88 that morning, and the gate refused every tick
    /// for 9.5 minutes: 4.3 km ridden, 20 m recorded.
    ///
    /// SIXTY WAS STILL TOO FEW. It was chosen because across 21 sessions the distance never
    /// passed 2.57 after sixty observations; the next ride (2026-09-17) read 4.27 at sixty-four
    /// and refused 21 ticks, 201 m, before settling to 1.2 by two hundred. Replayed over every
    /// recording since, 150 observations produces no refusal at all, and neither does 100 - so
    /// this threshold currently costs nothing and the only refusals it has ever produced on real
    /// data were wrong.
    ///
    /// Two reasons not to delete the gate outright. A genuinely different vehicle would hold a
    /// large distance with hundreds of observations, which this still catches; and the ride the
    /// gate was built for - a pocketed motorcycle reporting a flat 50 km/h - turned out to be the
    /// store's own composition rather than an unlearned regime, which naturalSpeedCounts now
    /// corrects at source. The gate is the backstop, not the fix.
    private let REGIME_MIN_OBSERVATIONS = 150
    /// How long the distance must stay past the limit before it may refuse. A fingerprint built
    /// while stopping and pulling away starts unrepresentative and settles: on the ride above it
    /// sat above 3 for about 40 s out of 19 minutes.
    private let REGIME_CONFIRM_SECONDS: TimeInterval = 60
    private var regimeUnlearnedSince: Date?

    /// SPEED BINS AS THEY WERE ACTUALLY RIDDEN, not as the store ended up holding them.
    ///
    /// insert() evicts from the most crowded speed bin, which is what stops a rare 100 km/h
    /// sample being squeezed out by thousands of red lights. The cost was invisible until it was
    /// replayed: the store stops resembling the riding. Measured over 44 recordings, 24% of
    /// observations are under 5 km/h and 45% above 30, while the store that rule produces holds
    /// 5% and 69%. A lookup that lands between regimes then averages mostly fast neighbours,
    /// which is exactly the measured failure - 15-30 km/h reported as ~50, +30-50% distance on
    /// six rides - while 50+ km/h, where the store is dense either way, reads correctly.
    ///
    /// So each neighbour is weighted by how over- or under-represented its speed is. Replayed
    /// leave-one-ride-out with the TRUE riding distribution, that takes mean distance error from
    /// 20% to 8%.
    ///
    /// ON ITS OWN IT DID NOT CONVERGE, and 1.4 (14)'s prior_w column showed it: median weight
    /// 1.01 at 15-30 km/h where about 4 was needed. A decayed count describes the last few rides,
    /// while the store was built over months, so the ratio between them is not the correction the
    /// store needs - replayed as shipped it gave 22% against 22% with no weighting at all. What
    /// converges is changing the eviction itself (evictionIndex). The weighting stays as a small
    /// residual correction while an old store turns over, worth 13% -> 11% in that replay.
    ///
    /// Decayed rather than cumulative: a half-life of about 1400 observations means this tracks
    /// how the phone is being used now, and that a store carried over from an older build stops
    /// dominating after two or three rides.
    private static let PRIOR_BINS = 101
    private static let PRIOR_BIN_WIDTH = 2.0 / 3.6            // 2 km/h, in m/s
    private let PRIOR_DECAY = 0.9995
    private var naturalSpeedCounts = [Double](repeating: 0, count: LearnedSpeedEstimator.PRIOR_BINS)
    private var naturalSpeedTotal: Double = 0
    private var storeSpeedCounts = [Double](repeating: 0, count: LearnedSpeedEstimator.PRIOR_BINS)
    private var storeDistributionIsStale = true

    private func speedBin(_ speed: Double) -> Int {
        min(max(Int(speed / Self.PRIOR_BIN_WIDTH), 0), Self.PRIOR_BINS - 1)
    }

    /// Record what was actually ridden, before any eviction decides what to keep.
    private func noteNaturalSpeed(_ speed: Double) {
        for i in 0..<naturalSpeedCounts.count { naturalSpeedCounts[i] *= PRIOR_DECAY }
        naturalSpeedCounts[speedBin(speed)] += 1
        naturalSpeedTotal = naturalSpeedTotal * PRIOR_DECAY + 1
    }

    private func refreshStoreDistributionIfNeeded() {
        guard storeDistributionIsStale else { return }
        storeDistributionIsStale = false
        storeSpeedCounts = [Double](repeating: 0, count: Self.PRIOR_BINS)
        for o in observations where !o.airborne { storeSpeedCounts[speedBin(o.speed)] += 1 }
    }

    /// How much a neighbour's speed should count, given how over-represented that speed is in
    /// the store. 1 while the store is faithful to the riding; below 1 for the fast samples
    /// eviction preserves, above 1 for the slow ones it thins. Clamped so a bin holding almost
    /// nothing cannot carry an answer on its own, and inert until there is a distribution worth
    /// trusting - a fresh install answers exactly as before.
    private func representationWeight(for speed: Double) -> Double {
        let storeTotal = storeSpeedCounts.reduce(0, +)
        guard naturalSpeedTotal > 200, storeTotal > 0 else { return 1 }
        let bin = speedBin(speed)
        let natural = naturalSpeedCounts[bin] / naturalSpeedTotal
        let held = storeSpeedCounts[bin] / storeTotal
        guard natural > 0, held > 0 else { return 1 }
        return min(max(natural / held, 0.05), 20)
    }

    /// True when the last estimate was refused because the workout is an unlearned regime.
    /// Recorded so a log can tell "declined, correctly" from "answered, wrongly" - the two are
    /// indistinguishable from the outside and need opposite fixes.
    private(set) var lastEstimateDeclinedUnlearnedRegime = false

    /// Mean absolute error, in m/s, of the neighbourhood the last estimate was drawn from —
    /// measured by holding each near neighbour out and predicting it from the others.
    private(set) var lastLocalError: Double?
    /// Mean representation weight over the neighbours the last estimate used, or nil when it did
    /// not answer. 1 means the store's speed mix matched the riding and the weighting changed
    /// nothing; above 1 means the answer was pulled toward under-represented (slow) neighbours.
    /// Recorded because a correction that silently fails to engage is indistinguishable from one
    /// that engaged and did not help - which is the position this project was in for three weeks.
    private(set) var lastNeighbourWeight: Double?
    /// True when the last estimate was refused because that error was too large to interpolate
    /// through.
    private(set) var lastEstimateDeclinedUnreliableLocally = false
    /// Above this, the stored labels around the query disagree so much that a weighted mean of
    /// them is not a measurement of anything. 4 m/s is 14 km/h — larger than the worst honest
    /// band error in the paper, so it fires on genuinely incoherent neighbourhoods rather than
    /// on ordinary spread.
    private let MAX_LOCAL_ERROR: Double = 4.0
    /// How many neighbours to hold out, and how many to predict each from.
    private let LOO_HELD_OUT = 8
    private let LOO_POOL = 24

    /// `distanceToNearestKnownRegime` walks every observation of every session to rebuild the
    /// fingerprints, which is far too much to repeat per tick. It only moves as the session
    /// accumulates evidence, so it is recomputed on a slow cadence and held in between.
    private var cachedRegimeDistance: Double?
    private var cachedRegimeDistanceAt: Date = .distantPast
    private let REGIME_CACHE_TTL: TimeInterval = 20

    /// The cached view of how far this workout sits from anything already learned.
    var regimeDistanceCached: Double? {
        if Date().timeIntervalSince(cachedRegimeDistanceAt) > REGIME_CACHE_TTL {
            cachedRegimeDistance = distanceToNearestKnownRegime
            cachedSessionObservations = observations.filter { $0.session == currentSession }.count
                + quarantined.filter { $0.session == currentSession }.count
            cachedRegimeDistanceAt = Date()
        }
        return cachedRegimeDistance
    }
    private var cachedSessionObservations = 0
    /// How many observations the current fingerprint was built from, refreshed with the distance.
    var regimeObservationsCached: Int {
        _ = regimeDistanceCached
        return cachedSessionObservations
    }

    /// Whether this workout looks like something the model has never been taught.
    ///
    /// Deliberately false when the answer is unknown. The distance needs 20 observations in the
    /// session before it means anything, and needs at least one other session to compare with, so
    /// a first-ever workout has no answer - and refusing on "no answer" would record nothing at
    /// all, which is the worse failure of the two.
    var regimeIsUnlearned: Bool {
        guard let d = regimeDistanceCached,
              cachedSessionObservations >= REGIME_MIN_OBSERVATIONS,
              d > REGIME_DISTANCE_LIMIT else {
            regimeUnlearnedSince = nil
            return false
        }
        guard let since = regimeUnlearnedSince else {
            regimeUnlearnedSince = Date()
            return false
        }
        return Date().timeIntervalSince(since) >= REGIME_CONFIRM_SECONDS
    }

    /// Observations recorded while Velocity Mode was forced. Held apart from the searchable
    /// store until the workout ends — see learn(gpsSpeed:quarantined:).
    private var quarantined: [Observation] = []

    /// Identifies the workout currently teaching the model.
    ///
    /// DERIVED, NOT STORED. Build 149 kept a parallel table of running signatures, which was
    /// wrong twice over: it lived only in memory, so it was empty on every launch and the
    /// regime_distance column came out blank on all 340 ticks of the first drive that used it;
    /// and it duplicated information the observations already carry. A fingerprint is just the
    /// mean normalised signature of a session's observations, so it is computed from them and
    /// persists exactly as long as they do.
    private(set) var currentSession: Int = 0

    /// Begin a new workout. Numbered above every session already in the store, so a restart
    /// cannot reuse an id and merge two unrelated regimes into one.
    func beginSession() {
        let highest = max(observations.map(\.session).max() ?? 0,
                          quarantined.map(\.session).max() ?? 0)
        currentSession = highest + 1
    }

    private func normalised(_ f: [Double]) -> [Double] {
        guard featureMean.count == f.count else { return f }
        var z = [Double](repeating: 0, count: f.count)
        for i in 0..<f.count {
            z[i] = (f[i] - featureMean[i]) / max(featureVar[i].squareRoot(), 1e-6)
        }
        return z
    }

    /// Mean normalised signature of one session - its fingerprint. Measured across six real
    /// sessions: same vehicle and carry 0.54-1.70 apart, same vehicle different carry 1.81-2.87,
    /// different vehicle 4.30-6.97. A whole session separates regimes that a single 4-second
    /// window cannot.
    func fingerprint(of session: Int) -> [Double]? {
        let pool = observations.filter { $0.session == session }
            + quarantined.filter { $0.session == session }
        guard pool.count >= 20, !featureMean.isEmpty else { return nil }
        var sum = [Double](repeating: 0, count: featureMean.count)
        for o in pool {
            let z = normalised(o.f)
            guard z.count == sum.count else { continue }
            for i in 0..<sum.count { sum[i] += z[i] }
        }
        return sum.map { $0 / Double(pool.count) }
    }

    /// How far the workout in progress sits from the closest regime the model already knows.
    /// Small means it has seen this vehicle and carry before; large means the speed it is
    /// reporting is an answer about something it has never observed.
    var distanceToNearestKnownRegime: Double? {
        guard let here = fingerprint(of: currentSession) else { return nil }
        var best: Double?
        for id in Set(observations.map(\.session)) where id != currentSession {
            guard let other = fingerprint(of: id), other.count == here.count else { continue }
            var d = 0.0
            for i in 0..<here.count { let z = here[i] - other[i]; d += z * z }
            let dist = d.squareRoot()
            if best == nil || dist < best! { best = dist }
        }
        return best
    }

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
        let observation = Observation(f: f, speed: gpsSpeed, airborne: airborne,
                                      t: isQuarantined ? Date() : nil,
                                      session: currentSession)
        if isQuarantined {
            // The speed tally waits for the quarantine too. Every answer weights its neighbours by
            // how common their speed is in naturalSpeedCounts, so counting this fix now would pull
            // Velocity Mode's answers toward the speeds GPS is measuring on this very trip.
            if quarantined.count < capacity { quarantined.append(observation) }
            return
        }
        if !airborne { noteNaturalSpeed(gpsSpeed) }
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
        storeDistributionIsStale = true
        insertsSinceProtectionUpdate += 1
        if observations.count < capacity {
            observations.append(observation)
        } else if let victim = evictionIndex(for: observation) {
            observations[victim] = observation
        }
    }

    /// Fold everything learned during a forced session into the searchable store. Called when
    /// the workout ends, so the evidence is never available to the estimate that produced it.
    func commitQuarantinedObservations() {
        guard !quarantined.isEmpty else { return }
        let count = quarantined.count
        for var o in quarantined {
            if !o.airborne { noteNaturalSpeed(o.speed) }
            o.t = nil; insert(o)
        }
        quarantined.removeAll()
        observationsAtLastCalibration = 0
        recalibrate()
        print("🧠 Learned speed model: folded in \(count) observations held back during Velocity Mode")
    }

    /// Which stored observation to give up for an incoming one, once the store is full.
    ///
    /// RANDOM, NOT THE MOST CROWDED SPEED BIN.
    ///
    /// Evicting from the most crowded bin kept the store flat across speeds, which is what let a
    /// rare fast sample survive thousands of red lights - and it is also why the store stopped
    /// resembling the riding (5% of it below 5 km/h, where the riding is 24%) and why every
    /// ambiguous lookup averaged mostly fast neighbours. Worse, it cannot recover: the rule
    /// throws away incoming slow observations for exactly as long as slow is the crowded bin.
    /// Replayed from a store built that way through seven motorcycle rides in order, it stayed at
    /// 5% slow the whole time and the last four rides averaged 82% distance error.
    ///
    /// Replacing a random observation lets real riding flow back in. The same replay reaches 11%
    /// slow and 13% mean error over those four rides - improving from the very next ride - and 11%
    /// with the representation weighting kept alongside. Nothing is deleted; old observations are
    /// simply outlived.
    ///
    /// Two things random replacement would eventually lose, so they are protected:
    /// - FLIGHT DATA. Ground observations never evict airborne ones. An airborne observation
    ///   evicts a ground one while the air partition holds under a quarter of the store, so a
    ///   flight is still learned into a store full of roads.
    /// - THE FASTEST GROUND SPEEDS. The top 2% are never chosen, so the store keeps the evidence
    ///   that lets it answer at speeds it rarely sees rather than capping itself at a commute.
    private func evictionIndex(for incoming: Observation) -> Int? {
        guard !observations.isEmpty else { return nil }
        refreshProtectedSpeedIfNeeded()
        let airCount = observations.reduce(0) { $0 + ($1.airborne ? 1 : 0) }
        let victimsAreAirborne = incoming.airborne && airCount >= capacity / 4
        func eligible(_ o: Observation) -> Bool {
            guard o.airborne == victimsAreAirborne else { return false }
            return o.airborne || o.speed < protectedGroundSpeed
        }
        for _ in 0..<16 {
            let i = Int.random(in: 0..<observations.count)
            if eligible(observations[i]) { return i }
        }
        // A heavily partitioned store can defeat a handful of random draws; scan instead so new
        // evidence is still accepted.
        return observations.indices.filter { eligible(observations[$0]) }.randomElement()
    }

    /// Ground speed at or above which an observation is never evicted: the 98th percentile of
    /// what the store holds, re-measured every 200 insertions. Unset until there are enough ground
    /// observations to make a percentile mean something.
    private var protectedGroundSpeed: Double = .greatestFiniteMagnitude
    private var insertsSinceProtectionUpdate = 200

    private func refreshProtectedSpeedIfNeeded() {
        guard insertsSinceProtectionUpdate >= 200 else { return }
        insertsSinceProtectionUpdate = 0
        let ground = observations.filter { !$0.airborne }.map(\.speed).sorted()
        guard ground.count >= 50 else {
            protectedGroundSpeed = .greatestFiniteMagnitude
            return
        }
        protectedGroundSpeed = ground[Int(Double(ground.count - 1) * 0.98)]
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
        lastEstimateUsedNetwork = false
        lastEstimateDeclinedUnlearnedRegime = false
        lastEstimateDeclinedUnreliableLocally = false
        lastLocalError = nil
        lastNeighbourWeight = nil
        guard let f = currentFeatures() else { return nil }

        // TOO LITTLE OF THE USER'S OWN DATA: THE BUNDLED NETWORK ANSWERS.
        //
        // Replayed on every recording, a store of 60 examples missed by 10.6 km/h a half-minute,
        // 1,000 by 8.8 and 2,000 by 8.5, while the network - trained offline, scored only on
        // recordings it never saw - missed by 8.3; the store draws level at about 3,000 (8.4).
        // So until the ground store holds NETWORK_UNTIL_OBSERVATIONS of the user's own
        // examples, the network answers; after that the store, which keeps adapting to this
        // user's own vehicle and phone placement, takes over.
        // It needs nothing from the current trip, which is what lets Velocity Mode stay free of
        // GPS on a first install or after the store is cleared: the old fallback here answered
        // from this trip's own GPS-labelled samples. Ground only; the air partition is its own.
        if !airborne, groundObservationCount < NETWORK_UNTIL_OBSERVATIONS,
           let network = SpeedNetwork.bundled {
            lastEstimateUsedNetwork = true
            return network.speed(features: f)
        }
        return storeEstimate(f, airborne: airborne)
    }

    /// The learned store's own answer for one fingerprint. Split out of estimate() so the log can
    /// record it every tick, even while the bundled network is the one being used.
    private func storeEstimate(_ f: [Double], airborne: Bool) -> Double? {
        lastStoreStatus = .tooFewExamples
        guard featureMean.count == f.count else { return nil }

        // REFUSE TO ANSWER ABOUT A REGIME THIS WORKOUT HAS NEVER BEEN TAUGHT.
        //
        // The per-match gate below asks "have I seen a signature like this one?". That is not
        // the same question as "does the speed attached to it transfer to what I am riding now",
        // and the difference is where the worst measured result in this project came from.
        //
        // A motorcycle with the phone in a trouser pocket: every individual 4-second signature
        // matched something in the store closely enough to clear MAX_MATCH_DISTANCE_SQUARED, so
        // the model answered on essentially every tick - and the answers carried no information
        // at all. Reported speed against real speed came out at R = +0.13, the vibration feature
        // against real speed at R = -0.02, and it read a steady ~50 km/h whether the motorcycle
        // was at 64 km/h or standing at a red light. Engine vibration through clothing tracks
        // engine speed, not road speed, and is undiminished at a standstill in gear; there is no
        // speed in the input for any estimator to recover.
        //
        // What did know was the fingerprint: 3.51 for the entire ride, outside the same-vehicle
        // range and heading toward different-vehicle. It was computed every tick, written to the
        // diagnostics file, and never consulted. Consulting it is this gate.
        //
        // Declining is not the same as failing. The caller falls through to the last speed GPS
        // actually measured, which is a far better answer than a confident number about a
        // vehicle the model has never ridden - and, unlike that number, it is honest about what
        // it is. Airborne is exempt: the air partition is small and separately judged, and there
        // is no ground truth to have built fingerprints from in the first place.
        if !airborne, regimeIsUnlearned {
            lastEstimateDeclinedUnlearnedRegime = true
            lastStoreStatus = .unlearnedRegime
            return nil
        }

        // COLD START MUST NOT MEAN NO ROUTE.
        //
        // A 16 km drive recorded ZERO metres: every tick fell through to HOLD, because the
        // store had just been reset and everything this session taught was quarantined until
        // the workout ended. The quarantine reasoning was right and its consequence was not -
        // an empty model made the whole workout unrecordable, which is a worse failure than
        // the leak it was guarding against.
        //
        // That case is now the network's (above). The aged quarantine that used to stand in here
        // answered from this trip's own GPS-labelled samples, so it is gone: quarantined samples
        // are never searched before the workout ends.
        guard isUsable(airborne: airborne) else { return nil }
        let pool = observations.filter { $0.airborne == airborne }

        var best = [(d: Double, s: Double)]()
        best.reserveCapacity(K + 1)
        for o in pool {
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
        lastStoreStatus = .noCloseMatch

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

        // IS THIS NEIGHBOURHOOD ACTUALLY ABLE TO PREDICT?
        //
        // Closeness says the signature has been seen before. It says nothing about whether the
        // speeds attached to those signatures agree well enough for a weighted mean of them to
        // mean anything. Where the store holds a region labelled with a wide range of speeds —
        // the same vibration recorded at a crawl and at a cruise — the lookup still returns a
        // confident number, and it is an average of contradictions.
        //
        // Neighbour SPREAD does not measure this; the paper reports it failing in the wrong
        // direction, because out-of-distribution queries land consistently in one wrong region
        // and so look tighter than honest ones. What does measure it is holding each near
        // neighbour out and predicting it from the others: that asks whether interpolation
        // works HERE, which is the assumption the whole estimate rests on, rather than whether
        // the neighbours happen to resemble each other.
        //
        // Note what this cannot do, so it is not mistaken for a general safety net: a query that
        // lands in a region that is internally consistent and simply wrong — walking vibration
        // matching stored motorcycle observations that all agree on 38 km/h — has a LOW local
        // error and passes. Consistency is not correctness. That case needs evidence from
        // outside the model, which is why the caller also refuses to hold a vehicle speed while
        // the pedometer is counting steps.
        if let mae = localError(around: f, pool: pool), mae > MAX_LOCAL_ERROR {
            lastLocalError = mae
            lastEstimateDeclinedUnreliableLocally = true
            lastStoreStatus = .locallyUnreliable
            return nil
        }

        refreshStoreDistributionIfNeeded()
        var num = 0.0, den = 0.0, weightSum = 0.0
        for b in best {
            // Undo the store's rebalancing; see naturalSpeedCounts. The air partition is small
            // and separately judged, so it answers unweighted.
            let representation = airborne ? 1 : representationWeight(for: b.s)
            weightSum += representation
            let w = (1.0 / (b.d + 1e-6)) * representation
            num += w * b.s
            den += w
        }
        guard den > 0 else { return nil }
        lastNeighbourWeight = weightSum / Double(best.count)
        // The compression curve is fitted on GROUND observations, where there are thousands of
        // them. Applying it to the air partition would be extrapolating a road correction into a
        // regime it has never seen, so the air answers raw until it has enough of its own.
        // The air curve is empty until the air partition has its own evidence, and calibrated()
        // returns the raw value unchanged in that case - so a first flight behaves as before.
        lastStoreStatus = .answered
        return max(0, calibrated(num / den, airborne: airborne))
    }

    /// BOTH ENGINES, FOR THE LOG.
    ///
    /// Only one of them drives the speed at a time - the network until the store holds
    /// NETWORK_UNTIL_OBSERVATIONS, the store after - but a log that recorded only the one in use
    /// could never show how close the other would have come on the same seconds. This asks both,
    /// and leaves every flag the tick reads (declines, local error, neighbour weight, which engine
    /// answered) exactly as the real estimate set them.
    func bothAnswers(airborne: Bool)
        -> (network: Double?, networkFamiliarity: Double?, store: Double?, storeStatus: String) {
        let saved = (lastEstimateUsedNetwork, lastEstimateDeclinedUnlearnedRegime,
                     lastEstimateDeclinedUnreliableLocally, lastLocalError, lastNeighbourWeight)
        defer {
            (lastEstimateUsedNetwork, lastEstimateDeclinedUnlearnedRegime,
             lastEstimateDeclinedUnreliableLocally, lastLocalError, lastNeighbourWeight) = saved
        }
        guard let f = currentFeatures() else { return (nil, nil, nil, "no window yet") }
        // The network is logged in the air as well: it never drives there, but what it would have
        // said is exactly what a log is for.
        let net = SpeedNetwork.bundled?.diagnose(features: f)
        let store = storeEstimate(f, airborne: airborne)
        return (net?.speed, net?.familiarity, store, lastStoreStatus.rawValue)
    }

    /// Whether estimate() would use the bundled network right now.
    func networkIsInUse(airborne: Bool) -> Bool {
        !airborne && groundObservationCount < NETWORK_UNTIL_OBSERVATIONS && SpeedNetwork.bundled != nil
    }

    /// Mean absolute error of predicting each of the nearest few observations from the others.
    ///
    /// Bounded work: the nearest `LOO_POOL` are collected in one pass, then `LOO_HELD_OUT` of
    /// them are predicted from the rest of that set — a few hundred operations, not a rescan of
    /// several thousand observations per tick.
    private func localError(around f: [Double], pool: [Observation]) -> Double? {
        var near = [(d: Double, o: Observation)]()
        near.reserveCapacity(LOO_POOL + 1)
        for o in pool {
            var d = 0.0
            for i in 0..<f.count {
                let sd = max(featureVar[i].squareRoot(), 1e-6)
                let z = (f[i] - featureMean[i]) / sd - (o.f[i] - featureMean[i]) / sd
                d += z * z
            }
            if near.count < LOO_POOL {
                near.append((d, o))
                if near.count == LOO_POOL { near.sort { $0.d < $1.d } }
            } else if d < near[LOO_POOL - 1].d {
                near[LOO_POOL - 1] = (d, o)
                var i = LOO_POOL - 1
                while i > 0 && near[i].d < near[i - 1].d { near.swapAt(i, i - 1); i -= 1 }
            }
        }
        guard near.count >= LOO_HELD_OUT + 4 else { return nil }

        var total = 0.0, counted = 0
        for h in 0..<min(LOO_HELD_OUT, near.count) {
            let held = near[h].o
            var num = 0.0, den = 0.0
            for (j, other) in near.enumerated() where j != h {
                var d = 0.0
                for i in 0..<held.f.count {
                    let sd = max(featureVar[i].squareRoot(), 1e-6)
                    let z = (held.f[i] - featureMean[i]) / sd - (other.o.f[i] - featureMean[i]) / sd
                    d += z * z
                }
                let w = 1.0 / (d + 1e-6)
                num += w * other.o.speed; den += w
            }
            guard den > 0 else { continue }
            total += abs(num / den - held.speed); counted += 1
        }
        guard counted > 0 else { return nil }
        let mae = total / Double(counted)
        lastLocalError = mae
        return mae
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
    ///
    /// MAPPED BY QUANTILE, NOT BY NEIGHBOUR AVERAGE. Binning held-out predictions and mapping
    /// each bin's mean to its mean actual cannot undo the flattening, because a conditional mean
    /// IS the flattening: averaging twelve neighbours pulls every answer toward the middle of
    /// whatever the store holds. Matching the distributions instead - the estimate's tenth
    /// percentile to the true tenth percentile - restores the spread. Replayed over eight recent
    /// rides against the old fit: 5-15 km/h +162% -> +99%, 15-30 +45% -> +28%, 50-80 -22%
    /// unchanged, whole-ride +7% -> -4%, with mean absolute speed error identical at 9.7 km/h.
    ///
    /// Fitted on EVERY observation, not only moving ones. Excluding the stationary ones was right
    /// when eviction kept the store artificially flat and they would have dominated the fit; with
    /// the store now holding what was actually ridden they belong in it, and leaving them out is
    /// what made the old fit map a raw 9 km/h estimate onto 30.
    private var calibrationCurve: [(estimate: Double, actual: Double)] = []
    /// THE AIR NEEDS ITS OWN CURVE, and used to get none.
    ///
    /// The ground curve is fitted on road observations, so applying it in the air would
    /// extrapolate a road correction into a regime it has never seen - which is why the air
    /// answered raw. But raw is not neutral: a nearest-neighbour mean flattens in the air exactly
    /// as it does on the road. Replayed on the 14 August flight, learning from alternate two-minute
    /// blocks and predicting the others, the air answer improves from 49.5 to 34.4 km/h mean error
    /// and from -11% to +1% distance once it is calibrated against air observations alone.
    ///
    /// It stays empty until the air partition has enough of its own evidence, so a first flight
    /// still answers raw rather than through a curve borrowed from the road.
    private var calibrationCurveAir: [(estimate: Double, actual: Double)] = []

    private func calibrated(_ raw: Double, airborne: Bool = false) -> Double {
        let calibrationCurve = airborne ? calibrationCurveAir : self.calibrationCurve
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
        recalibrate(airborne: false)
        recalibrate(airborne: true)
    }

    private func recalibrate(airborne: Bool) {
        refreshStoreDistributionIfNeeded()
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
            guard held.airborne == airborne else { index += stride; continue }
            var best = [(d: Double, s: Double)]()
            best.reserveCapacity(K)
            for (j, o) in observations.enumerated() where j != index && o.airborne == airborne {
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
            for b in best {
                let w = (1.0 / (b.d + 1e-6)) * (airborne ? 1 : representationWeight(for: b.s))
                num += w * b.s
                den += w
            }
            guard den > 0 else { continue }
            let predicted = num / den
            n += 1; sx += predicted; sy += held.speed
            sxx += predicted * predicted; sxy += predicted * held.speed
            samples.append((predicted, held.speed))
        }

        guard n >= 40 else { return }
        // Quantile mapping: the q-th percentile of what the model predicts becomes the q-th
        // percentile of what was actually measured. Monotone by construction, and it restores the
        // spread that averaging neighbours removes.
        let predictedSorted = samples.map(\.predicted).sorted()
        let actualSorted = samples.map(\.actual).sorted()
        let points = 21
        var curve: [(estimate: Double, actual: Double)] = []
        for i in 0..<points {
            let q = Double(i) / Double(points - 1)
            let index = Int((Double(samples.count - 1) * q).rounded())
            let estimate = predictedSorted[index], actual = actualSorted[index]
            // Interpolation needs strictly increasing estimates; repeated values carry no extra
            // information, and a flat segment would divide by zero in calibrated().
            if let previous = curve.last, estimate <= previous.estimate + 1e-6 { continue }
            curve.append((estimate, actual))
        }
        let fitted = curve.count >= 4 ? curve : []
        if airborne { calibrationCurveAir = fitted } else { calibrationCurve = fitted }
        if !fitted.isEmpty {
            print("🧠 Learned speed curve (\(airborne ? "air" : "ground")) over \(Int(n)) held-out samples: " +
                  fitted.map { String(format: "%.0f→%.0f", $0.estimate * 3.6, $0.actual * 3.6) }
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
        guard !airborne else { return }
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
        // A STORE FROM AN OLDER BUILD HAS NO RECORD OF WHAT WAS RIDDEN, only of what survived
        // eviction. Seeding the prior from it makes every weight 1, so the first ride behaves
        // exactly as before and the decay in noteNaturalSpeed lets real riding take over within
        // two or three of them. Inventing a distribution here would be worse than waiting.
        if let pdata = try? Data(contentsOf: Self.priorURL),
           let counts = try? JSONDecoder().decode([Double].self, from: pdata),
           counts.count == Self.PRIOR_BINS {
            naturalSpeedCounts = counts
        } else {
            naturalSpeedCounts = [Double](repeating: 0, count: Self.PRIOR_BINS)
            for o in saved where !o.airborne { naturalSpeedCounts[speedBin(o.speed)] += 1 }
        }
        naturalSpeedTotal = naturalSpeedCounts.reduce(0, +)
        storeDistributionIsStale = true
        print("🧠 Learned speed model: restored \(saved.count) observations")
        // Re-measure the compression against everything restored, so the first drive after a
        // launch is corrected too rather than waiting for 200 fresh observations.
        recalibrate()
    }

    /// What was ridden, kept beside what was stored. Without it every launch would start with a
    /// flat prior and answer unweighted until a few minutes of fresh evidence arrived.
    private static let priorURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("learned_speed_prior_v1.json")
    }()

    func save() {
        guard !observations.isEmpty, let data = try? JSONEncoder().encode(observations) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
        if let pdata = try? JSONEncoder().encode(naturalSpeedCounts) {
            try? pdata.write(to: Self.priorURL, options: .atomic)
        }
        print("🧠 Learned speed model: saved \(observations.count) observations")
    }

    /// Per-workout signal state only. The learned observations deliberately survive.
    func resetWindow() {
        ring = [Double](repeating: 0, count: windowSize); ringFilled = 0; ringIndex = 0
    }
}
