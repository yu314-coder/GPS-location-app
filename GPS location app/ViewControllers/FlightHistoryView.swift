import SwiftUI
import HealthKit

struct FlightHistoryView: View {
    @StateObject private var flightDataStore = FlightDataStore.shared
    @State private var workouts: [HKWorkout] = []
    @State private var selectedFlight: Flight?
    @State private var navigationPath = NavigationPath()
    @State private var isLoading = false
    @State private var isLoadingWorkoutDetails = false
    @StateObject private var healthKitManager = HealthKitManager()

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                if isLoading {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading workouts...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top)
                    }
                } else if flightDataStore.savedFlights.isEmpty && workouts.isEmpty {
                    EmptyFlightsView()
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Statistics Cards at Top
                            VStack(spacing: 12) {
                                Text("Your Activity")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)
                                    .padding(.top, 8)

                                HStack(spacing: 12) {
                                    StatCardView(
                                        icon: "figure.run",
                                        title: "Workouts",
                                        value: "\(flightDataStore.savedFlights.count + workouts.count)",
                                        color: .blue
                                    )

                                    StatCardView(
                                        icon: "map",
                                        title: "Distance",
                                        value: String(format: "%.1f", totalDistance),
                                        unit: "km",
                                        color: .green
                                    )
                                }
                                .padding(.horizontal)

                                HStack(spacing: 12) {
                                    StatCardView(
                                        icon: "clock",
                                        title: "Total Time",
                                        value: formatTotalDuration(totalDuration),
                                        color: .orange
                                    )

                                    StatCardView(
                                        icon: "flame.fill",
                                        title: "Avg Distance",
                                        value: String(format: "%.1f", totalDistance / Double(max(flightDataStore.savedFlights.count + workouts.count, 1))),
                                        unit: "km",
                                        color: .red
                                    )
                                }
                                .padding(.horizontal)
                            }
                            .padding(.bottom, 8)

                            // Workouts List
                            VStack(spacing: 12) {
                                Text("Recent Workouts")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)

                                // HealthKit workouts
                                if !workouts.isEmpty {
                                    ForEach(workouts, id: \.uuid) { workout in
                                        Button(action: {
                                            loadWorkoutDetails(workout)
                                        }) {
                                            HealthKitWorkoutCard(workout: workout)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .padding(.horizontal)
                                    }
                                }

                                // Saved flights (local)
                                if !flightDataStore.savedFlights.isEmpty {
                                    ForEach(flightDataStore.savedFlights) { flight in
                                        NavigationLink(destination: WorkoutDetailView(flight: flight)) {
                                            FlightCard(flight: flight)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .padding(.horizontal)
                                    }
                                }
                            }
                            .padding(.bottom, 20)
                        }
                        .padding(.top)
                    }
                }

                // Loading overlay for workout details
                if isLoadingWorkoutDetails {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))

                        Text("Loading workout details...")
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }
                    .padding(24)
                    .background(Color(.systemBackground).opacity(0.9))
                    .cornerRadius(16)
                }
            }
            .navigationTitle("Workouts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: loadFlights) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationDestination(item: $selectedFlight) { flight in
                WorkoutDetailView(flight: flight)
            }
            .onAppear {
                loadFlights()
            }
        }
    }

    private var totalDistance: Double {
        let flightDistance = flightDataStore.savedFlights.reduce(0.0) { $0 + ($1.metrics?.totalDistance ?? 0) }
        let workoutDistance = workouts.reduce(0.0) { sum, workout in
            if let distance = workout.totalDistance?.doubleValue(for: .meter()) {
                return sum + distance
            }
            return sum
        }
        return (flightDistance + workoutDistance) / 1000.0
    }

    private var totalDuration: TimeInterval {
        let flightDuration = flightDataStore.savedFlights.reduce(0.0) { $0 + $1.duration }
        let workoutDuration = workouts.reduce(0.0) { $0 + $1.duration }
        return flightDuration + workoutDuration
    }

    private func loadFlights() {
        isLoading = true

        // Load saved flights from local storage
        flightDataStore.loadFlights()
        print("📂 Loaded \(flightDataStore.savedFlights.count) flights from local storage")

        // Load from HealthKit
        if healthKitManager.isAuthorized {
            healthKitManager.fetchWorkouts { fetchedWorkouts, error in
                DispatchQueue.main.async {
                    self.isLoading = false
                    if let fetchedWorkouts = fetchedWorkouts {
                        self.workouts = fetchedWorkouts
                        print("✅ Loaded \(fetchedWorkouts.count) workouts from HealthKit")
                    } else if let error = error {
                        print("❌ Error loading workouts: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            // Request authorization if needed
            healthKitManager.requestAuthorization { success, error in
                if success {
                    self.loadFlights()
                } else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                    print("⚠️ HealthKit not authorized - can't load workouts")
                }
            }
        }
    }

    private func deleteFlights(at offsets: IndexSet) {
        for index in offsets {
            flightDataStore.deleteFlight(at: index)
        }
    }

    private func loadWorkoutDetails(_ workout: HKWorkout) {
        isLoadingWorkoutDetails = true
        print("📊 Loading details for workout:")
        print("   Workout ID: \(workout.uuid)")
        print("   Start: \(workout.startDate)")
        print("   Duration: \(workout.duration)s")

        // Fetch route from HealthKit
        healthKitManager.fetchRoute(for: workout) { locations, error in
            DispatchQueue.main.async {
                self.isLoadingWorkoutDetails = false

                if let error = error {
                    print("❌ Failed to load route: \(error.localizedDescription)")
                    print("   Showing workout WITHOUT route data - graphs will be empty")
                    // Show workout without route
                    self.selectedFlight = self.convertWorkoutToFlight(workout, locations: [])
                } else {
                    let locationCount = locations?.count ?? 0
                    print("✅ Loaded \(locationCount) locations from route")
                    if locationCount == 0 {
                        print("⚠️ WARNING: No locations in route - old workout may not have GPS data saved")
                        print("   This is expected for workouts recorded before route saving was implemented")
                    }
                    // Show workout with route
                    self.selectedFlight = self.convertWorkoutToFlight(workout, locations: locations ?? [])
                }
            }
        }
    }

    private func convertWorkoutToFlight(_ workout: HKWorkout, locations: [FlightLocation]) -> Flight {
        var flight = Flight(id: workout.uuid, startDate: workout.startDate)
        flight.workoutType = workout.workoutActivityType.rawValue
        flight.endDate = workout.endDate
        flight.locations = locations

        print("📊 Converting workout to flight:")
        print("   Workout ID: \(workout.uuid)")
        print("   Locations count: \(locations.count)")

        // Create metrics from workout data
        var metrics = FlightMetrics()

        // Distance
        if let distance = workout.totalDistance?.doubleValue(for: .meter()) {
            metrics.totalDistance = distance
        }

        // Duration
        metrics.duration = workout.duration
        if metrics.duration > 0 && metrics.totalDistance > 0 {
            metrics.averageSpeed = metrics.totalDistance / metrics.duration
        }

        // Calories
        if #available(iOS 18.0, *) {
            if let calories = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                metrics.caloriesBurned = calories
            }
        } else {
            if let calories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
                metrics.caloriesBurned = calories
            }
        }

        // Calculate altitude metrics from locations
        if !locations.isEmpty {
            metrics.maxAltitude = locations.map { $0.altitude }.max() ?? 0
            metrics.minAltitude = locations.map { $0.altitude }.min() ?? 0
            metrics.currentAltitude = locations.last?.altitude ?? 0

            // Build speed history and calculate max speed from locations
            var speedSamples: [SpeedSample] = []
            for i in 1..<locations.count {
                let distance = locations[i].distance(to: locations[i-1])
                let timeDelta = locations[i].timestamp.timeIntervalSince(locations[i-1].timestamp)
                if timeDelta > 0 {
                    let speed = distance / timeDelta

                    // Create speed sample
                    let speedSample = SpeedSample(timestamp: locations[i].timestamp, speed: speed)
                    speedSamples.append(speedSample)

                    if speed > metrics.maxSpeed {
                        metrics.maxSpeed = speed
                    }
                }
            }
            metrics.speedHistory = speedSamples
            print("   ✅ Built \(speedSamples.count) speed samples")

            // Build altitude history
            var altitudeSamples: [AltitudeSample] = []
            for location in locations {
                let altitudeSample = AltitudeSample(timestamp: location.timestamp, altitude: location.altitude)
                altitudeSamples.append(altitudeSample)
            }
            metrics.altitudeHistory = altitudeSamples
            print("   ✅ Built \(altitudeSamples.count) altitude samples")

            // GPS quality metrics
            metrics.totalPoints = locations.count
            metrics.validPoints = locations.filter { $0.isValid }.count
            if metrics.totalPoints > 0 {
                metrics.averageAccuracy = locations.map { $0.horizontalAccuracy }.reduce(0, +) / Double(metrics.totalPoints)
                metrics.signalCoverage = (Double(metrics.validPoints) / Double(metrics.totalPoints)) * 100.0
            }
        }

        flight.metrics = metrics

        return flight
    }

    private func formatTotalDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        return String(format: "%dh %dm", hours, minutes)
    }
}

struct HealthKitWorkoutCard: View {
    let workout: HKWorkout

    var body: some View {
        VStack(spacing: 0) {
            // Header with workout type and date
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: workoutIcon(workout.workoutActivityType))
                        .font(.title3)
                        .foregroundColor(workoutColor(workout.workoutActivityType))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(workoutTypeName(workout.workoutActivityType))
                            .font(.headline)

                        Text(workout.startDate, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding()
            .background(workoutColor(workout.workoutActivityType).opacity(0.1))

            // Metrics
            HStack(spacing: 0) {
                if let distance = workout.totalDistance?.doubleValue(for: .meter()) {
                    WorkoutMetricItem(
                        icon: "figure.walk",
                        value: String(format: "%.2f", distance / 1000.0),
                        unit: "km",
                        color: .green
                    )
                }

                Divider()
                    .frame(height: 40)

                WorkoutMetricItem(
                    icon: "clock",
                    value: formatDurationShort(workout.duration),
                    unit: "",
                    color: .blue
                )

                // Show calories if available
                if let caloriesType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                    Divider()
                        .frame(height: 40)

                    if #available(iOS 18.0, *) {
                        if let calories = workout.statistics(for: caloriesType)?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                            WorkoutMetricItem(
                                icon: "flame.fill",
                                value: String(format: "%.0f", calories),
                                unit: "kcal",
                                color: .orange
                            )
                        }
                    } else {
                        if let calories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
                            WorkoutMetricItem(
                                icon: "flame.fill",
                                value: String(format: "%.0f", calories),
                                unit: "kcal",
                                color: .orange
                            )
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    private func workoutTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .cycling: return "Cycling"
        case .running: return "Running"
        case .walking: return "Walking"
        case .hiking: return "Hiking"
        case .other: return "Flight"
        default: return "Workout"
        }
    }

    private func workoutIcon(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .cycling: return "bicycle"
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .hiking: return "mountain.2.fill"
        case .other: return "airplane"
        default: return "figure.mixed.cardio"
        }
    }

    private func workoutColor(_ type: HKWorkoutActivityType) -> Color {
        switch type {
        case .cycling: return .blue
        case .running: return .green
        case .walking: return .orange
        case .hiking: return .purple
        case .other: return .cyan
        default: return .gray
        }
    }

    private func formatDurationShort(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

struct FlightCard: View {
    let flight: Flight

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "airplane")
                        .font(.title3)
                        .foregroundColor(.cyan)

                    VStack(alignment: .leading, spacing: 2) {
                        if let origin = flight.origin, let destination = flight.destination {
                            Text("\(origin) → \(destination)")
                                .font(.headline)
                        } else {
                            Text("Workout")
                                .font(.headline)
                        }

                        Text(flight.startDate, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding()
            .background(Color.cyan.opacity(0.1))

            // Metrics
            if let metrics = flight.metrics {
                HStack(spacing: 0) {
                    WorkoutMetricItem(
                        icon: "figure.walk",
                        value: String(format: "%.2f", metrics.distanceInKilometers),
                        unit: "km",
                        color: .green
                    )

                    Divider()
                        .frame(height: 40)

                    WorkoutMetricItem(
                        icon: "clock",
                        value: formatDurationShort(flight.duration),
                        unit: "",
                        color: .blue
                    )

                    Divider()
                        .frame(height: 40)

                    WorkoutMetricItem(
                        icon: "flame.fill",
                        value: String(format: "%.0f", metrics.caloriesBurned),
                        unit: "kcal",
                        color: .orange
                    )
                }
                .padding()
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    private func formatDurationShort(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

struct EmptyFlightsView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 120, height: 120)

                Image(systemName: "figure.run")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
            }

            VStack(spacing: 12) {
                Text("No Workouts Yet")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Start tracking your first workout\nto see it here")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                Text("Workouts saved to HealthKit will\nappear automatically")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .padding()
    }
}

struct StatCardView: View {
    let icon: String
    let title: String
    let value: String
    var unit: String = ""
    let color: Color

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

struct WorkoutMetricItem: View {
    let icon: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct FlightHistoryView_Previews: PreviewProvider {
    static var previews: some View {
        FlightHistoryView()
    }
}
