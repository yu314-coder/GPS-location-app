import Foundation

/// THE FLIGHT ENGINES THE LOG RECORDS, BESIDE THE SPEED THAT IS USED. Since build 112 the speed in the air is
/// FlightProfile's medians; these two are only written to the log, every airborne second, so a real flight can grade
/// them on the same seconds.
///
/// NETWORK (build 118): the neural form of FlightProfile. A 5-32-32-1 network on the same two clocks, minutes since
/// the takeoff roll and minutes since the cabin started down (clockFeatures), trained with an L1 loss (so it fits a
/// median) on the same pooled data: NASA's 302 DASHlink flights and 1,194 jet takeoffs from a day of the OpenSky
/// Network's ADS-B data (see FlightProfile). Held out by aircraft it came within 10% of the distance on 76% of
/// OpenSky flights (the medians as shipped: 72%) and on 48% of NASA's (36%), mostly from the descent; on BR215 it counted 95%
/// like the medians, and on August, without the takeoff's measured speed, it read minutes 1-3 42 km/h off GPS where
/// the medians with that speed carried read 17. So it stays in the log until a real flight shows it ahead.
///
/// STORE: the build-64 store of NASA examples read by the phone's tilt from the still moment before the roll. On
/// BR215 the 16 Pro turned over in its bag at the takeoff push and its tilt stayed above anything NASA flew; it is
/// kept only so older logs and new ones read the same column.
///
/// NO GPS. The inputs are the phone's own; ground speeds were used only to train, offline.
enum FlightSpeedEngines {

    /// The network: clockFeatures. The store: minutes since the roll began, mean tilt over the last 60 s and 300 s,
    /// and tilt accumulated since the roll began (degree-minutes).
    typealias Features = [Double]

    /// The network's inputs: hours and log-minutes since the roll, whether the cabin has started down, and hours and
    /// log-minutes since it did (osday_lib.features).
    static func clockFeatures(sinceRoll t: TimeInterval, sinceDescent d: TimeInterval?) -> Features {
        let m = max(t, 0) / 60
        guard let d, d >= 0 else { return [m / 60, log1p(m), 0, 0, 0] }
        let k = d / 60
        return [m / 60, log1p(m), 1, k / 60, log1p(k)]
    }

    struct Network {
        private let mean: [Double], scale: [Double], fmin: [Double], fmax: [Double]
        private let w1: [[Double]], b1: [Double], w2: [[Double]], b2: [Double], w3: [Double], b3: Double
        private let outKmh: Double
        private struct File: Decodable {
            let mean, scale, fmin, fmax: [Double]
            let w1: [[Double]], b1: [Double], w2: [[Double]], b2: [Double], w3: [Double], b3: Double
            let out_kmh: Double
        }
        static let bundled: Network? = {
            guard let url = Bundle.main.url(forResource: "flight_network", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return Network(data: data)
        }()
        init?(data: Data) {
            guard let f = try? JSONDecoder().decode(File.self, from: data), !f.mean.isEmpty, f.scale.count == f.mean.count,
                  f.fmin.count == f.mean.count, f.fmax.count == f.mean.count,
                  f.w1.count == f.b1.count, f.w1.allSatisfy({ $0.count == f.mean.count }), f.w2.count == f.b2.count,
                  f.w2.allSatisfy({ $0.count == f.b1.count }), f.w3.count == f.b2.count else { return nil }
            mean = f.mean; scale = f.scale; fmin = f.fmin; fmax = f.fmax
            w1 = f.w1; b1 = f.b1; w2 = f.w2; b2 = f.b2; w3 = f.w3; b3 = f.b3; outKmh = f.out_kmh
        }
        /// Ground speed in km/h. Inputs outside what the flights covered are held at the edge.
        func speedKmh(_ x: Features) -> Double {
            guard x.count == mean.count else { return 0 }
            let z = mean.indices.map { (min(max(x[$0], fmin[$0]), fmax[$0]) - mean[$0]) / scale[$0] }
            let h1 = zip(w1, b1).map { row, b in max(0, zip(row, z).reduce(b) { $0 + $1.0 * $1.1 }) }
            let h2 = zip(w2, b2).map { row, b in max(0, zip(row, h1).reduce(b) { $0 + $1.0 * $1.1 }) }
            return max(0, zip(w3, h2).reduce(b3) { $0 + $1.0 * $1.1 } * outKmh)
        }
    }

    struct Store {
        private let mean: [Double], scale: [Double], fmin: [Double], fmax: [Double]
        private let points: [[Double]], speeds: [Double], k: Int
        private struct File: Decodable {
            let mean, scale, fmin, fmax: [Double]
            let points: [[Double]]
            let speeds_kmh: [Double]
            let k: Int
        }
        static let bundled: Store? = {
            guard let url = Bundle.main.url(forResource: "flight_store", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return Store(data: data)
        }()
        init?(data: Data) {
            guard let f = try? JSONDecoder().decode(File.self, from: data), f.mean.count == 4,
                  f.points.count == f.speeds_kmh.count, f.points.count >= f.k, f.k > 0,
                  f.points.allSatisfy({ $0.count == 4 }) else { return nil }
            mean = f.mean; scale = f.scale; fmin = f.fmin; fmax = f.fmax
            points = f.points; speeds = f.speeds_kmh; k = f.k
        }
        /// Ground speed in km/h: the k nearest flight examples, nearer ones counting more (1/d^2), as the
        /// learned store answers on the ground.
        func speedKmh(_ x: Features) -> Double {
            let z = (0..<4).map { (min(max(x[$0], fmin[$0]), fmax[$0]) - mean[$0]) / scale[$0] }
            var nearest: [(d2: Double, v: Double)] = []
            nearest.reserveCapacity(k + 1)
            for (p, v) in zip(points, speeds) {
                var d2 = 0.0
                for i in 0..<4 { let e = p[i] - z[i]; d2 += e * e }
                if nearest.count < k {
                    nearest.append((d2, v)); if nearest.count == k { nearest.sort { $0.d2 < $1.d2 } }
                } else if d2 < nearest[k - 1].d2 {
                    nearest[k - 1] = (d2, v); nearest.sort { $0.d2 < $1.d2 }
                }
            }
            var num = 0.0, den = 0.0
            for n in nearest { let w = 1 / max(n.d2, 1e-12); num += w * n.v; den += w }
            return den > 0 ? num / den : 0
        }
    }

    /// The phone's tilt, one value a second from the still moment before the takeoff roll
    /// (LaunchIntegrator's anchor), measured from the way gravity pointed then.
    struct Tilt {
        private var anchorCount = -1
        private var base: [Double]?
        private var sum = [0.0, 0.0, 0.0], sumTime = 0.0
        private var perSecond: [Double] = []
        private var cumulative: [Double] = [0]          // running sum of perSecond, for window means

        mutating func reset() { self = Tilt() }

        /// One device-motion sample: gravity (unit-free) and its interval.
        mutating func ingest(gravity g: [Double], dt: Double, launch: LaunchIntegrator) {
            guard g.count == 3, dt > 0, dt < 0.5 else { return }
            if launch.anchorCount != anchorCount {
                anchorCount = launch.anchorCount
                base = launch.anchorGravity
                sum = [0, 0, 0]; sumTime = 0; perSecond = []; cumulative = [0]
            }
            guard let base else { return }
            for i in 0..<3 { sum[i] += g[i] * dt }
            sumTime += dt
            guard sumTime >= 1.0 else { return }
            let n = (sum[0] * sum[0] + sum[1] * sum[1] + sum[2] * sum[2]).squareRoot()
            if n > 1e-9 {
                let c = (sum[0] * base[0] + sum[1] * base[1] + sum[2] * base[2]) / n
                let tilt = acos(min(max(c, -1), 1)) * 180 / .pi
                perSecond.append(tilt)
                cumulative.append((cumulative.last ?? 0) + tilt)
            }
            sum = [0, 0, 0]; sumTime = 0
        }

        /// The engines' inputs, or nil before the first second since the anchor.
        var features: Features? {
            guard let j = perSecond.indices.last else { return nil }
            func mean(over w: Int) -> Double {
                let lo = max(0, j - w + 1)
                return (cumulative[j + 1] - cumulative[lo]) / Double(j + 1 - lo)
            }
            return [Double(j) / 60, mean(over: 60), mean(over: 300), cumulative[j + 1] / 60]
        }
    }
}
