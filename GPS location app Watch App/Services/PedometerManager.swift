import Foundation
import CoreMotion
import Combine

#if os(watchOS)
class PedometerManager: NSObject, ObservableObject {
    private let pedometer = CMPedometer()

    @Published var currentStepCount: Int = 0
    @Published var currentDistance: Double = 0.0 // meters
    @Published var currentPace: Double = 0.0 // seconds per meter
    @Published var currentCadence: Double = 0.0 // steps per second
    @Published var isPedometerAvailable: Bool = false
    @Published var isDistanceAvailable: Bool = false
    @Published var nativeCallbackHz: Double = 0.0
    @Published var nativeCallbackAgeSeconds: TimeInterval = 0.0
    @Published var queryRefreshAgeSeconds: TimeInterval = 0.0

    private var startDate: Date?
    private var isTracking = false
    private var lastNativeUpdateAt: Date?
    private var lastQueryRefreshAt: Date?
    private var nativeUpdateCount = 0
    private var nativeUpdateIntervalSum: TimeInterval = 0
    private var queryRefreshTimer: Timer?
    private var diagnosticsTimer: Timer?
    private var queryRefreshCount = 0
    private var queryRefreshAppliedCount = 0

    private let queryRefreshInterval: TimeInterval = 0.5

    override init() {
        super.init()
        checkAvailability()
    }

    private func checkAvailability() {
        isPedometerAvailable = CMPedometer.isStepCountingAvailable()
        isDistanceAvailable = CMPedometer.isDistanceAvailable()
        let authStatus = CMPedometer.authorizationStatus()

        if isPedometerAvailable {
            print("⌚ 👟 Pedometer is available - real step counting enabled")
        } else {
            print("⌚ ⚠️ Pedometer not available - will use GPS-based step estimation")
        }
        print("⌚ 👟 Pedometer distance availability: \(isDistanceAvailable ? "available" : "unavailable")")
        print("⌚ 👟 Pedometer authorization status: \(authStatus.rawValue)")
    }

    func startTracking(from date: Date = Date()) {
        guard isPedometerAvailable else {
            print("⌚ ⚠️ Cannot start pedometer - not available on this device")
            return
        }

        guard !isTracking else {
            print("⌚ ⚠️ Pedometer already tracking")
            return
        }

        startDate = date
        isTracking = true
        currentStepCount = 0
        currentDistance = 0.0
        currentPace = 0.0
        currentCadence = 0.0
        lastNativeUpdateAt = nil
        nativeUpdateCount = 0
        nativeUpdateIntervalSum = 0
        nativeCallbackHz = 0.0
        nativeCallbackAgeSeconds = 0.0
        queryRefreshAgeSeconds = 0.0
        lastQueryRefreshAt = nil
        queryRefreshCount = 0
        queryRefreshAppliedCount = 0

        print("⌚ 👟 Starting pedometer tracking from \(date)")
        print("⌚ 👟 Query refresh polling every \(String(format: "%.1f", queryRefreshInterval))s")

        // Start pedometer updates
        pedometer.startUpdates(from: date) { [weak self] (data, error) in
            guard let self = self else { return }

            if let error = error {
                print("⌚ ❌ Pedometer error: \(error.localizedDescription)")
                return
            }

            guard let data = data else {
                print("⌚ ⚠️ Pedometer data is nil")
                return
            }

            // Update step count on main thread
            DispatchQueue.main.async {
                self.currentStepCount = data.numberOfSteps.intValue

                // Distance in meters (if available)
                if let distance = data.distance {
                    self.currentDistance = distance.doubleValue
                }

                // Current pace in seconds per meter (if available)
                if let pace = data.currentPace {
                    self.currentPace = pace.doubleValue
                }

                // Current cadence in steps per second (if available)
                if let cadence = data.currentCadence {
                    self.currentCadence = cadence.doubleValue
                }

                let now = Date()
                if let lastUpdate = self.lastNativeUpdateAt {
                    let delta = now.timeIntervalSince(lastUpdate)
                    self.nativeUpdateIntervalSum += delta
                    let hz = delta > 0 ? (1.0 / delta) : 0
                    print("⌚ 👟 Native pedometer callback #\(self.nativeUpdateCount + 1): Δt=\(String(format: "%.2f", delta))s (~\(String(format: "%.2f", hz))Hz), steps=\(self.currentStepCount)")
                } else {
                    print("⌚ 👟 Native pedometer callback #1: first sample, steps=\(self.currentStepCount)")
                }
                self.lastNativeUpdateAt = now
                self.nativeUpdateCount += 1
                self.nativeCallbackAgeSeconds = 0.0
                if self.nativeUpdateCount > 1 {
                    let avgDelta = self.nativeUpdateIntervalSum / Double(self.nativeUpdateCount - 1)
                    self.nativeCallbackHz = avgDelta > 0 ? (1.0 / avgDelta) : 0
                }

                // Log every 100 steps
                if self.currentStepCount % 100 == 0 && self.currentStepCount > 0 {
                    print("⌚ 👟 Steps: \(self.currentStepCount), Distance: \(String(format: "%.2f", self.currentDistance))m, Cadence: \(String(format: "%.2f", self.currentCadence * 60)) steps/min")
                }
            }
        }

        startQueryRefreshTimer()
        startDiagnosticsTimer()
    }

    func stopTracking() {
        guard isTracking else {
            print("⌚ ⚠️ Pedometer not tracking")
            return
        }

        pedometer.stopUpdates()
        stopQueryRefreshTimer()
        stopDiagnosticsTimer()
        isTracking = false

        print("⌚ 👟 Stopped pedometer tracking")
        print("   Final step count: \(currentStepCount) steps")
        print("   Final distance: \(String(format: "%.2f", currentDistance))m")
        if nativeUpdateCount > 1 {
            let avgDelta = nativeUpdateIntervalSum / Double(nativeUpdateCount - 1)
            let avgHz = avgDelta > 0 ? (1.0 / avgDelta) : 0
            print("   Native callback frequency: avg Δt=\(String(format: "%.2f", avgDelta))s (~\(String(format: "%.2f", avgHz))Hz), callbacks=\(nativeUpdateCount)")
        } else if nativeUpdateCount == 1 {
            print("   Native callback frequency: only 1 callback received")
        } else {
            print("   Native callback frequency: no callbacks received")
        }
        print("   Query refresh: polls=\(queryRefreshCount), applied updates=\(queryRefreshAppliedCount), interval=\(String(format: "%.1f", queryRefreshInterval))s")
        print("   Final callback staleness: \(String(format: "%.1f", nativeCallbackAgeSeconds))s")
    }

    func reset() {
        if isTracking {
            stopTracking()
        }

        currentStepCount = 0
        currentDistance = 0.0
        currentPace = 0.0
        currentCadence = 0.0
        startDate = nil
        lastNativeUpdateAt = nil
        nativeUpdateCount = 0
        nativeUpdateIntervalSum = 0
        nativeCallbackHz = 0.0
        nativeCallbackAgeSeconds = 0.0
        queryRefreshAgeSeconds = 0.0
        stopQueryRefreshTimer()
        stopDiagnosticsTimer()
        lastQueryRefreshAt = nil
        queryRefreshCount = 0
        queryRefreshAppliedCount = 0

        print("⌚ 👟 Pedometer reset")
    }

    private func startQueryRefreshTimer() {
        stopQueryRefreshTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: queryRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshFromPedometerQuery()
        }
        timer.tolerance = 0.2
        queryRefreshTimer = timer
        refreshFromPedometerQuery()
    }

    private func stopQueryRefreshTimer() {
        queryRefreshTimer?.invalidate()
        queryRefreshTimer = nil
    }

    private func startDiagnosticsTimer() {
        stopDiagnosticsTimer()
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateDiagnostics()
        }
        if let diagnosticsTimer {
            RunLoop.main.add(diagnosticsTimer, forMode: .common)
        }
    }

    private func stopDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    private func updateDiagnostics() {
        guard isTracking else { return }
        let now = Date()
        if let lastNativeUpdateAt {
            nativeCallbackAgeSeconds = max(0, now.timeIntervalSince(lastNativeUpdateAt))
        } else {
            nativeCallbackAgeSeconds = 0
        }
        if let lastQueryRefreshAt {
            queryRefreshAgeSeconds = max(0, now.timeIntervalSince(lastQueryRefreshAt))
        } else {
            queryRefreshAgeSeconds = 0
        }

        if queryRefreshCount > 0, queryRefreshCount % 10 == 0 {
            print(
                "⌚ 👟 Pedometer diag: nativeHz=\(String(format: "%.2f", nativeCallbackHz)), nativeAge=\(String(format: "%.1f", nativeCallbackAgeSeconds))s, queryAge=\(String(format: "%.1f", queryRefreshAgeSeconds))s, steps=\(currentStepCount), distance=\(String(format: "%.2f", currentDistance))m"
            )
        }
    }

    private func refreshFromPedometerQuery() {
        guard isTracking, isPedometerAvailable, let startDate else { return }
        queryRefreshCount += 1
        lastQueryRefreshAt = Date()

        pedometer.queryPedometerData(from: startDate, to: Date()) { [weak self] data, error in
            guard let self = self else { return }

            if let error = error {
                print("⌚ ⚠️ Pedometer query refresh failed: \(error.localizedDescription)")
                return
            }

            guard let data = data else {
                return
            }

            DispatchQueue.main.async {
                var applied = false
                let queriedSteps = data.numberOfSteps.intValue
                if queriedSteps > self.currentStepCount {
                    self.currentStepCount = queriedSteps
                    applied = true
                }

                if let queriedDistance = data.distance?.doubleValue, queriedDistance > self.currentDistance {
                    self.currentDistance = queriedDistance
                    applied = true
                }

                if let queriedPace = data.currentPace?.doubleValue {
                    self.currentPace = queriedPace
                }

                if let queriedCadence = data.currentCadence?.doubleValue {
                    self.currentCadence = queriedCadence
                }

                if applied {
                    self.queryRefreshAppliedCount += 1
                    print("⌚ 👟 Query refresh applied: steps=\(self.currentStepCount), distance=\(String(format: "%.2f", self.currentDistance))m")
                }
                self.queryRefreshAgeSeconds = 0.0
            }
        }
    }

    // Query step count for a specific time range (useful for paused workouts)
    func queryStepCount(from startDate: Date, to endDate: Date, completion: @escaping (Int?, Error?) -> Void) {
        guard isPedometerAvailable else {
            completion(nil, NSError(domain: "PedometerManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Pedometer not available"]))
            return
        }

        pedometer.queryPedometerData(from: startDate, to: endDate) { (data, error) in
            if let error = error {
                print("⌚ ❌ Failed to query pedometer data: \(error.localizedDescription)")
                completion(nil, error)
                return
            }

            guard let data = data else {
                completion(nil, NSError(domain: "PedometerManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "No pedometer data"]))
                return
            }

            let steps = data.numberOfSteps.intValue
            print("⌚ 👟 Queried \(steps) steps from \(startDate) to \(endDate)")
            completion(steps, nil)
        }
    }
}
#endif
