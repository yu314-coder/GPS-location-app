import SwiftUI
import HealthKit
import CoreLocation

struct HealthKitSimulationTestView: View {
    @StateObject private var healthKitManager = HealthKitManager()
    @State private var isRunningSimulation = false
    @State private var lastSimulatedWorkoutUUID: UUID?
    @State private var logs: [String] = []

    private let simulationDurationSeconds: TimeInterval = 2 * 60 * 60
    private let simulationSpeedKmh: Double = 120.0
    private let simulationWorkoutType: HKWorkoutActivityType = .running
    private let simulationPointCount: Int = 2 * 60 * 60

    /// A developer tool (shown only with developer options on): saves a synthetic long workout to
    /// check what HealthKit keeps of it. Laid out for the watch in build 83 - one card saying what
    /// is saved, one prominent action, access asked for only while it is missing, and the log in
    /// its own card - instead of a stack of full-width buttons.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.pink)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("HealthKit test")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Developer")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Label(healthKitManager.isAuthorized ? "Health access allowed" : "Health access not allowed",
                      systemImage: healthKitManager.isAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(healthKitManager.isAuthorized ? .green : .orange)

                VStack(alignment: .leading, spacing: 5) {
                    Text("SAVES ONE WORKOUT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TestFactRow(symbol: "map.fill", text: "Taipei → Taichung")
                    TestFactRow(symbol: "clock.fill",
                                text: "\(Int(simulationDurationSeconds / 3600)) h at \(Int(simulationSpeedKmh)) km/h")
                    TestFactRow(symbol: "figure.run", text: "Running")
                    TestFactRow(symbol: "point.topleft.down.to.point.bottomright.curvepath.fill",
                                text: "\(simulationPointCount.formatted()) route points")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))

                Button {
                    runSimulationSave()
                } label: {
                    Group {
                        if isRunningSimulation {
                            ProgressView()
                        } else {
                            Label("Save test workout", systemImage: "square.and.arrow.down.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(isRunningSimulation)

                if lastSimulatedWorkoutUUID != nil {
                    Button(role: .destructive) {
                        deleteLastSimulatedWorkout()
                    } label: {
                        Label("Delete test workout", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunningSimulation)
                }

                if !healthKitManager.isAuthorized {
                    Button {
                        requestAuthorization()
                    } label: {
                        Label("Allow Health access", systemImage: "hand.raised.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if !logs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("LOG")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear") { logs.removeAll() }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.pink)
                                .buttonStyle(.plain)
                        }
                        ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                            Text(log)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            // Reads the current state; the system only prompts if access was never asked for.
            requestAuthorization()
        }
    }

    private func requestAuthorization() {
        healthKitManager.requestAuthorization { success, error in
            if success {
                appendLog("HealthKit auth: OK")
            } else {
                appendLog("HealthKit auth failed: \(error?.localizedDescription ?? "Unknown")")
            }
        }
    }

    private func runSimulationSave() {
        guard !isRunningSimulation else { return }
        isRunningSimulation = true

        if !healthKitManager.isAuthorized {
            appendLog("HealthKit not authorized, requesting...")
            healthKitManager.requestAuthorization { success, error in
                if success {
                    self.appendLog("HealthKit auth: OK")
                    self.executeSimulationSave()
                } else {
                    self.appendLog("HealthKit auth failed: \(error?.localizedDescription ?? "Unknown")")
                    self.isRunningSimulation = false
                }
            }
            return
        }

        executeSimulationSave()
    }

    private func executeSimulationSave() {
        let payload = makeTaipeiTaichungSimulation()
        let flight = payload.flight
        let locations = payload.locations
        let metrics = payload.metrics

        appendLog("Sim start: running, duration=2h, speed=120km/h")
        appendLog("Path mode: sequential moving coordinates, points=\(simulationPointCount)")
        appendLog("Channels -> gpsWR: \(fmtMeters(metrics.totalDistance)), nativeStepCount: \(Int(metrics.stepsCount ?? 0)), nativeStepDistance: \(fmtMeters(metrics.nativeStepDistance ?? 0)), nativeCycling: \(fmtMeters(metrics.nativeStepDistance ?? 0))")
        appendLog("Locations: \(locations.count)")

        healthKitManager.saveWorkoutWithResult(
            flight: flight,
            locations: locations,
            metrics: metrics
        ) { success, error, workout in
            DispatchQueue.main.async {
                self.isRunningSimulation = false
                if success, let workout {
                    self.lastSimulatedWorkoutUUID = workout.uuid
                    self.appendLog("Saved workout UUID: \(workout.uuid.uuidString)")
                    if let distance = workout.totalDistance?.doubleValue(for: .meter()) {
                        self.appendLog("Workout totalDistance: \(self.fmtMeters(distance))")
                    } else {
                        self.appendLog("Workout totalDistance: nil")
                    }
                    self.logPersistedMetrics(for: workout.uuid)
                } else {
                    self.appendLog("Simulation save failed: \(error?.localizedDescription ?? "Unknown")")
                }
            }
        }
    }

    private func deleteLastSimulatedWorkout() {
        guard let uuid = lastSimulatedWorkoutUUID else { return }
        appendLog("Deleting simulated workout \(uuid.uuidString)...")
        healthKitManager.deleteWorkout(uuid: uuid) { success, deleteError in
            DispatchQueue.main.async {
                if success {
                    self.appendLog("Deleted workout \(uuid.uuidString)")
                    self.lastSimulatedWorkoutUUID = nil
                } else {
                    self.appendLog("Delete failed: \(deleteError?.localizedDescription ?? "Unknown")")
                }
            }
        }
    }

    private func logPersistedMetrics(for workoutUUID: UUID) {
        appendLog("Verifying persisted samples for \(workoutUUID.uuidString)...")
        healthKitManager.fetchWorkout(uuid: workoutUUID) { workout, fetchError in
            guard let workout else {
                DispatchQueue.main.async {
                    self.appendLog("Verify failed: \(fetchError?.localizedDescription ?? "Workout not found")")
                }
                return
            }

            self.healthKitManager.fetchCumulativeQuantitySum(for: workout, identifier: .distanceWalkingRunning) { wrDistance, wrError in
                DispatchQueue.main.async {
                    if let wrDistance {
                        self.appendLog("Saved distanceWalkingRunning: \(self.fmtMeters(wrDistance))")
                    } else {
                        self.appendLog("Saved distanceWalkingRunning: nil (\(wrError?.localizedDescription ?? "no samples"))")
                    }
                }

                self.healthKitManager.fetchCumulativeQuantitySum(for: workout, identifier: .distanceCycling) { cyclingDistance, cyclingError in
                    DispatchQueue.main.async {
                        if let cyclingDistance {
                            self.appendLog("Saved distanceCycling: \(self.fmtMeters(cyclingDistance))")
                        } else {
                            self.appendLog("Saved distanceCycling: nil (\(cyclingError?.localizedDescription ?? "no samples"))")
                        }
                    }

                    self.healthKitManager.fetchCumulativeQuantitySum(for: workout, identifier: .stepCount) { stepCount, stepsError in
                        DispatchQueue.main.async {
                            if let stepCount {
                                self.appendLog("Saved stepCount: \(Int(stepCount))")
                            } else {
                                self.appendLog("Saved stepCount: nil (\(stepsError?.localizedDescription ?? "no samples"))")
                            }
                        }
                    }
                }
            }

            self.healthKitManager.fetchRouteWithRetry(for: workout, maxRetries: 8, retryDelay: 1.0) { routeLocations, routeError in
                DispatchQueue.main.async {
                    if let routeLocations {
                        self.appendLog("Saved route points: \(routeLocations.count)")
                    } else {
                        self.appendLog("Saved route: nil (\(routeError?.localizedDescription ?? "no route"))")
                    }
                }
            }
        }
    }

    private func makeTaipeiTaichungSimulation() -> (flight: Flight, locations: [FlightLocation], metrics: FlightMetrics) {
        let startCoordinate = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654) // Taipei
        let taichungCoordinate = CLLocationCoordinate2D(latitude: 24.1477, longitude: 120.6736)
        let speedMps = simulationSpeedKmh / 3.6
        let totalDistance = speedMps * simulationDurationSeconds
        let startDate = Date().addingTimeInterval(-simulationDurationSeconds)
        let endDate = Date()
        let pointCount = max(simulationPointCount, 2)
        let sampleInterval: TimeInterval = simulationDurationSeconds / Double(pointCount - 1)
        let headingToTaichung = initialBearingDegrees(from: startCoordinate, to: taichungCoordinate)

        var locations: [FlightLocation] = []
        var speedHistory: [SpeedSample] = []
        var altitudeHistory: [AltitudeSample] = []

        for index in 0..<pointCount {
            let fraction = Double(index) / Double(pointCount - 1)
            let timestamp = startDate.addingTimeInterval(Double(index) * sampleInterval)
            let distanceAlongPath = totalDistance * fraction
            let coordinate = coordinate(from: startCoordinate, bearingDegrees: headingToTaichung, distanceMeters: distanceAlongPath)
            let altitude = 20.0 + (60.0 * fraction)

            let clLocation = CLLocation(
                coordinate: coordinate,
                altitude: altitude,
                horizontalAccuracy: 5.0,
                verticalAccuracy: 8.0,
                course: headingToTaichung,
                speed: speedMps,
                timestamp: timestamp
            )

            locations.append(
                FlightLocation(
                    from: clLocation,
                    isFiltered: false,
                    isValid: true,
                    satelliteCount: 12,
                    signalStrength: 0.95
                )
            )
            speedHistory.append(SpeedSample(timestamp: timestamp, speed: speedMps))
            altitudeHistory.append(AltitudeSample(timestamp: timestamp, altitude: altitude))
        }

        var metrics = FlightMetrics()
        metrics.totalDistance = totalDistance
        metrics.averageSpeed = speedMps
        metrics.maxSpeed = speedMps
        metrics.currentSpeed = speedMps
        metrics.smoothedSpeed = speedMps
        metrics.tenSecondAverageSpeed = speedMps
        metrics.duration = simulationDurationSeconds
        metrics.caloriesBurned = 1800
        metrics.restingEnergyBurned = 150
        metrics.stepsCount = totalDistance / 0.78
        metrics.nativeStepDistance = totalDistance
        metrics.speedHistory = speedHistory
        metrics.altitudeHistory = altitudeHistory
        metrics.maxAltitude = altitudeHistory.map { $0.altitude }.max() ?? 0
        metrics.minAltitude = altitudeHistory.map { $0.altitude }.min() ?? 0
        metrics.currentAltitude = altitudeHistory.last?.altitude ?? 0
        metrics.totalPoints = locations.count
        metrics.validPoints = locations.count
        metrics.averageAccuracy = 5.0
        metrics.signalCoverage = 100.0

        var flight = Flight(startDate: startDate)
        flight.endDate = endDate
        flight.locations = locations
        flight.metrics = metrics
        flight.origin = "Taipei"
        flight.destination = "Taichung corridor"
        flight.notes = "Simulation test: 2h @120km/h running, 7200 moving points"
        flight.effort = 10
        flight.workoutType = simulationWorkoutType.rawValue

        return (flight, locations, metrics)
    }

    private func initialBearingDegrees(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return fmod(degrees + 360, 360)
    }

    private func coordinate(from start: CLLocationCoordinate2D, bearingDegrees: Double, distanceMeters: Double) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let distanceRadians = distanceMeters / earthRadius
        let bearing = bearingDegrees * .pi / 180
        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180

        let lat2 = asin(
            sin(lat1) * cos(distanceRadians) +
            cos(lat1) * sin(distanceRadians) * cos(bearing)
        )
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(distanceRadians) * cos(lat1),
            cos(distanceRadians) - sin(lat1) * sin(lat2)
        )

        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        logs.insert("[\(timestamp)] \(message)", at: 0)
        if logs.count > 120 {
            logs = Array(logs.prefix(120))
        }
    }

    private func fmtMeters(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.2fkm", value / 1000.0)
        }
        return String(format: "%.0fm", value)
    }
}

/// One fact about the test workout: a small symbol and a line of text.
private struct TestFactRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.pink)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 13))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}
