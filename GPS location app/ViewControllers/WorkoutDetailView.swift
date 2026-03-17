import SwiftUI
import HealthKit
import MapKit
import Charts

struct WorkoutDetailView: View {
    let flight: Flight
    @ObservedObject private var healthKitManager = HealthKitManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingShareSheet = false
    @State private var gpxFileURL: URL?
    @State private var mapRegion: MKCoordinateRegion?
    @State private var detailedFlight: Flight?
    @State private var isLoadingDetails = false
    @State private var hasAttemptedDetailLoad = false
    @State private var isResyncing = false
    @State private var showResyncAlert = false
    @State private var resyncMessage = ""
    @State private var isRecalculating = false
    @State private var showRecalculateAlert = false
    @State private var recalculateMessage = ""

    private var activeFlight: Flight {
        detailedFlight ?? flight
    }

    private var activityName: String {
        guard let rawValue = activeFlight.workoutType,
              let type = HKWorkoutActivityType(rawValue: rawValue) else {
            return "Workout"
        }

        switch type {
        case .cycling:
            return "Cycling"
        case .running:
            return "Running"
        case .walking:
            return "Walking"
        case .hiking:
            return "Hiking"
        case .other:
            return "Flight"
        case .traditionalStrengthTraining:
            return "General"
        default:
            return "Workout"
        }
    }

    private var workoutActivityType: HKWorkoutActivityType? {
        guard let rawValue = activeFlight.workoutType else { return nil }
        return HKWorkoutActivityType(rawValue: rawValue)
    }

    private var shouldShowPaceChart: Bool {
        guard let type = workoutActivityType else { return false }
        // Only show pace for running, walking, and hiking activities
        return type == .running || type == .walking || type == .hiking
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Route Map (if available)
                if !activeFlight.locations.isEmpty {
                    ZStack(alignment: .topTrailing) {
                        StaticMapView(locations: activeFlight.locations)
                            .frame(height: 300)
                            .onAppear {
                                calculateMapRegion()
                            }

                        // Map stats overlay
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(.white)
                                Text("\(activeFlight.locations.count) points")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)

                            if let metrics = activeFlight.metrics {
                                HStack(spacing: 4) {
                                    Image(systemName: "chart.xyaxis.line")
                                        .foregroundColor(.white)
                                    Text("\(String(format: "%.1f", metrics.signalCoverage))% GPS quality")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(8)
                            }
                        }
                        .padding(12)
                    }
                } else {
                    // No route available
                    VStack(spacing: 12) {
                        Image(systemName: "map")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text(isLoadingDetails ? "Loading route data..." : "No route data available")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray6))
                }

                // Workout Header
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            if let origin = activeFlight.origin, let destination = activeFlight.destination {
                                Text("\(origin) → \(destination)")
                                    .font(.title2)
                                    .fontWeight(.bold)
                            } else {
                                Text(activityName)
                                    .font(.title2)
                                    .fontWeight(.bold)
                            }

                            Text(activeFlight.startDate, style: .date)
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Text(formatTimeRange())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color(.systemBackground))
                }

                Divider()

                // Main Metrics Grid
                if let metrics = activeFlight.metrics {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        DetailMetricCard(
                            icon: "figure.walk",
                            title: "Distance",
                            value: String(format: "%.2f", metrics.distanceInKilometers),
                            unit: "km",
                            color: .green
                        )

                        DetailMetricCard(
                            icon: "clock",
                            title: "Duration",
                            value: metrics.formattedDuration,
                            unit: "",
                            color: .blue
                        )

                        DetailMetricCard(
                            icon: "speedometer",
                            title: "Avg Speed",
                            value: String(format: "%.1f", metrics.averageSpeedKmh),
                            unit: "km/h",
                            color: .orange
                        )

                        DetailMetricCard(
                            icon: "bolt.fill",
                            title: "Max Speed",
                            value: String(format: "%.1f", metrics.maxSpeedKmh),
                            unit: "km/h",
                            color: .red
                        )

                        DetailMetricCard(
                            icon: "mountain.2.fill",
                            title: "Max Altitude",
                            value: String(format: "%.0f", metrics.maxAltitude),
                            unit: "m",
                            color: .purple
                        )

                        DetailMetricCard(
                            icon: "flame.fill",
                            title: "Calories",
                            value: String(format: "%.0f", metrics.caloriesBurned),
                            unit: "kcal",
                            color: .orange
                        )

                        // Show steps count if available
                        if let steps = metrics.stepsCount, steps > 0 {
                            DetailMetricCard(
                                icon: "figure.walk",
                                title: "Steps",
                                value: String(format: "%.0f", steps),
                                unit: "",
                                color: .cyan
                            )
                        }
                    }
                    .padding()

                    Divider()

                    // No GPS Data Message
                    if metrics.speedHistory.isEmpty && metrics.altitudeHistory.isEmpty && activeFlight.locations.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 50))
                                .foregroundColor(.gray)

                            VStack(spacing: 8) {
                                Text("No GPS Route Data")
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                Text("This workout doesn't have GPS tracking data saved")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)

                                Text("New workouts will include speed and altitude graphs")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        .padding(.horizontal)

                        Divider()
                    }

                    // Graphs Section
                    if !metrics.speedHistory.isEmpty || !metrics.altitudeHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Activity Graphs")
                                .font(.headline)
                                .padding(.horizontal)

                            // Speed Graph
                            if !metrics.speedHistory.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Speed Over Time")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)

                                    if #available(iOS 16.0, *) {
                                        SpeedChartView(speedHistory: metrics.speedHistory, maxSpeed: metrics.maxSpeed)
                                            .frame(height: 200)
                                            .padding(.horizontal)
                                    }
                                }
                            }

                            // Altitude Graph
                            if !metrics.altitudeHistory.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Altitude Profile")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)

                                    if #available(iOS 16.0, *) {
                                        AltitudeChartView(
                                            altitudeHistory: metrics.altitudeHistory,
                                            maxAltitude: metrics.maxAltitude,
                                            minAltitude: metrics.minAltitude
                                        )
                                        .frame(height: 200)
                                        .padding(.horizontal)
                                    }
                                }
                            }

                            // Pressure Graph
                            if !metrics.pressureHistory.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Atmospheric Pressure")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)

                                    if #available(iOS 16.0, *) {
                                        PressureChartView(pressureHistory: metrics.pressureHistory)
                                            .frame(height: 200)
                                            .padding(.horizontal)
                                    }
                                }
                            }

                            // Pace Graph (derived from speed) - Only show for running/walking/hiking
                            if !metrics.speedHistory.isEmpty && shouldShowPaceChart {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Pace Over Time")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)

                                    if #available(iOS 16.0, *) {
                                        PaceChartView(speedHistory: metrics.speedHistory, activityType: workoutActivityType)
                                            .frame(height: 200)
                                            .padding(.horizontal)
                                    }
                                }
                            }
                        }
                        .padding(.vertical)

                        Divider()
                    }

                    // Detailed Stats Section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Detailed Statistics")
                            .font(.headline)
                            .padding(.horizontal)

                        VStack(spacing: 12) {
                            DetailRow(icon: "arrow.up.circle.fill", title: "Altitude Gain", value: String(format: "%.0f m", metrics.totalAltitudeGain), color: .green)
                            DetailRow(icon: "arrow.down.circle.fill", title: "Altitude Loss", value: String(format: "%.0f m", metrics.totalAltitudeLoss), color: .red)
                            DetailRow(icon: "mountain.2", title: "Min Altitude", value: String(format: "%.0f m", metrics.minAltitude), color: .gray)

                            Divider()

                            DetailRow(icon: "gauge", title: "Avg Pace", value: metrics.formattedAveragePace, color: .blue)
                            DetailRow(icon: "point.3.connected.trianglepath.dotted", title: "Total GPS Points", value: "\(metrics.totalPoints)", color: .cyan)
                            DetailRow(icon: "checkmark.circle.fill", title: "Valid Points", value: "\(metrics.validPoints)", color: .green)
                            DetailRow(icon: "antenna.radiowaves.left.and.right", title: "GPS Coverage", value: String(format: "%.1f%%", metrics.signalCoverage), color: .blue)
                            DetailRow(icon: "scope", title: "Avg Accuracy", value: String(format: "±%.1f m", metrics.averageAccuracy), color: .purple)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical)

                    // Heart Rate Section (if available)
                    if metrics.averageHeartRate != nil || metrics.maxHeartRate != nil {
                        Divider()

                        VStack(alignment: .leading, spacing: 16) {
                            Text("Heart Rate")
                                .font(.headline)
                                .padding(.horizontal)

                            VStack(spacing: 12) {
                                if let currentHR = metrics.currentHeartRate {
                                    DetailRow(icon: "heart.fill", title: "Current", value: String(format: "%.0f bpm", currentHR), color: .red)
                                }
                                if let avgHR = metrics.averageHeartRate {
                                    DetailRow(icon: "waveform.path.ecg", title: "Average", value: String(format: "%.0f bpm", avgHR), color: .pink)
                                }
                                if let maxHR = metrics.maxHeartRate {
                                    DetailRow(icon: "bolt.heart.fill", title: "Maximum", value: String(format: "%.0f bpm", maxHR), color: .red)
                                }
                                if let minHR = metrics.minHeartRate {
                                    DetailRow(icon: "heart", title: "Minimum", value: String(format: "%.0f bpm", minHR), color: .orange)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical)
                    }

                    // Splits Section
                    if !metrics.splits.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 16) {
                            Text("Splits")
                                .font(.headline)
                                .padding(.horizontal)

                            VStack(spacing: 8) {
                                ForEach(metrics.splits) { split in
                                    HStack {
                                        Text("Km \(split.number)")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                            .frame(width: 60, alignment: .leading)

                                        Spacer()

                                        Text(split.formattedDistance)
                                            .font(.caption)
                                            .foregroundColor(.secondary)

                                        Text(split.formattedPace)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .foregroundColor(.blue)
                                            .frame(width: 60, alignment: .trailing)

                                        if let hr = split.averageHeartRate {
                                            HStack(spacing: 2) {
                                                Image(systemName: "heart.fill")
                                                    .font(.caption2)
                                                Text(String(format: "%.0f", hr))
                                                    .font(.caption)
                                            }
                                            .foregroundColor(.red)
                                            .frame(width: 50, alignment: .trailing)
                                        }
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical)
                    }
                }

                // Action Buttons
                VStack(spacing: 12) {
                    if activeFlight.workoutUUID != nil {
                        Button(action: {
                            openInFitnessApp()
                        }) {
                            HStack {
                                Image(systemName: "heart.text.square.fill")
                                Text("View in Fitness App")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }

                    if !activeFlight.locations.isEmpty {
                        Button(action: {
                            exportGPX()
                        }) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Export GPX Route")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }

                    // Recalculate Distance button
                    if !activeFlight.locations.isEmpty {
                        Button(action: {
                            recalculateDistance()
                        }) {
                            HStack {
                                if isRecalculating {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    Text("Recalculating...")
                                } else {
                                    Image(systemName: "function")
                                    Text("Recalculate Distance")
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isRecalculating ? Color.gray : Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isRecalculating)
                    }

                    // Resync to HealthKit button
                    if !activeFlight.locations.isEmpty {
                        Button(action: {
                            resyncToHealthKit()
                        }) {
                            HStack {
                                if isResyncing {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    Text("Resyncing...")
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("Resend to HealthKit")
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isResyncing ? Color.gray : Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isResyncing)
                    }
                }
                .padding()
                .alert("HealthKit Resync", isPresented: $showResyncAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(resyncMessage)
                }
                .alert("Recalculate Distance", isPresented: $showRecalculateAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(recalculateMessage)
                }
            }
        }
        .onAppear {
            loadDetailsIfNeeded()
        }
        .onDisappear {
            detailedFlight = nil
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingShareSheet) {
            if let url = gpxFileURL {
                ShareSheet(items: [url])
            }
        }
    }

    private func calculateMapRegion() {
        guard !activeFlight.locations.isEmpty else { return }

        let coordinates = activeFlight.locations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let minLat = coordinates.map { $0.latitude }.min() ?? 0
        let maxLat = coordinates.map { $0.latitude }.max() ?? 0
        let minLon = coordinates.map { $0.longitude }.min() ?? 0
        let maxLon = coordinates.map { $0.longitude }.max() ?? 0

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // Ensure minimum span to avoid zero-size map issues
        let latDelta = max((maxLat - minLat) * 1.2, 0.001)
        let lonDelta = max((maxLon - minLon) * 1.2, 0.001)

        let span = MKCoordinateSpan(
            latitudeDelta: latDelta,
            longitudeDelta: lonDelta
        )

        // Ensure UI update happens on main thread
        DispatchQueue.main.async {
            self.mapRegion = MKCoordinateRegion(center: center, span: span)
        }
    }

    private func formatTimeRange() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short

        let startTime = formatter.string(from: activeFlight.startDate)
        if let endDate = activeFlight.endDate {
            let endTime = formatter.string(from: endDate)
            return "\(startTime) - \(endTime)"
        }
        return "Started at \(startTime)"
    }

    private func openInFitnessApp() {
        // Open Fitness app (workouts section)
        if let url = URL(string: "x-apple-health://") {
            UIApplication.shared.open(url)
        }
    }

    private func exportGPX() {
        if let url = GPXExporter.exportToGPX(flight: activeFlight) {
            gpxFileURL = url
            showingShareSheet = true
        }
    }

    private func resyncToHealthKit() {
        print("🔄 User requested resync to HealthKit")

        // Ensure we have HealthKit authorization
        guard healthKitManager.isAuthorized else {
            print("❌ HealthKit not authorized")
            resyncMessage = "Please authorize HealthKit access in Settings to resync workouts."
            showResyncAlert = true
            return
        }

        // Ensure we have location data
        guard !activeFlight.locations.isEmpty, let metrics = activeFlight.metrics else {
            print("❌ No location data or metrics available")
            resyncMessage = "This workout has no location data to resync."
            showResyncAlert = true
            return
        }

        isResyncing = true
        print("📊 Resyncing flight:")
        print("   Distance: \(String(format: "%.2f", metrics.totalDistance/1000))km")
        print("   Locations: \(activeFlight.locations.count)")

        // Resync to HealthKit
        healthKitManager.resyncFlightToHealthKit(
            flight: activeFlight,
            locations: activeFlight.locations,
            metrics: metrics
        ) { success, error, workout in
            DispatchQueue.main.async {
                self.isResyncing = false

                if let workout = workout {
                    FlightDataStore.shared.updateWorkoutUUID(for: activeFlight.id, workoutUUID: workout.uuid)
                    if var detail = self.detailedFlight {
                        detail.workoutUUID = workout.uuid
                        self.detailedFlight = detail
                    }
                }

                if success {
                    print("✅ Resync successful")
                    let signature = FlightDataStore.shared.resyncSignature(for: activeFlight)
                    FlightDataStore.shared.markResynced(flightID: activeFlight.id, signature: signature)
                    self.resyncMessage = "Workout successfully resynced to HealthKit!\n\nDistance: \(String(format: "%.2f", metrics.totalDistance/1000))km\n\nGo back to the Flights tab and pull down to refresh, or reopen the app to see the updated distance."
                } else {
                    print("❌ Resync failed: \(error?.localizedDescription ?? "Unknown error")")
                    self.resyncMessage = "Failed to resync workout: \(error?.localizedDescription ?? "Unknown error")"
                }

                self.showResyncAlert = true
            }
        }
    }

    private func recalculateDistance() {
        print("🧮 ========== RECALCULATE DISTANCE DEBUG ==========")
        print("🧮 User requested distance recalculation")

        guard !activeFlight.locations.isEmpty, var metrics = activeFlight.metrics else {
            recalculateMessage = "❌ This workout has no location data or metrics."
            showRecalculateAlert = true
            return
        }

        isRecalculating = true

        // Run recalculation on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            print("🧮 Starting recalculation...")
            print("📊 Current stored metrics:")
            print("   Distance: \(String(format: "%.2f", metrics.totalDistance/1000))km (\(metrics.totalDistance)m)")
            print("   Locations: \(self.activeFlight.locations.count)")
            print("   Duration: \(String(format: "%.1f", metrics.duration))s")

            // Recalculate distance from GPS points
            var recalculatedDistance: Double = 0
            var validSegments = 0
            var invalidSegments = 0

            print("🧮 Calculating distance from GPS coordinates...")
            for i in 1..<self.activeFlight.locations.count {
                let current = self.activeFlight.locations[i]
                let previous = self.activeFlight.locations[i - 1]

                // Only count valid GPS points
                guard current.isValid && previous.isValid else {
                    invalidSegments += 1
                    continue
                }

                // Calculate distance
                let distance = current.distance(to: previous)

                // Sanity check: ignore impossible jumps (GPS glitches)
                if distance < 1000.0 { // Less than 1km jump
                    recalculatedDistance += distance
                    validSegments += 1

                    // Log every 500 segments for progress
                    if validSegments % 500 == 0 {
                        print("   Progress: \(validSegments) segments, distance so far: \(String(format: "%.2f", recalculatedDistance/1000))km")
                    }
                } else {
                    print("   ⚠️ Skipping GPS glitch at segment \(i): \(String(format: "%.0f", distance))m jump")
                    invalidSegments += 1
                }
            }

            print("🧮 Recalculation complete:")
            print("   Valid segments: \(validSegments)")
            print("   Invalid/glitch segments: \(invalidSegments)")
            print("   📊 STORED Distance: \(String(format: "%.2f", metrics.totalDistance/1000))km (\(metrics.totalDistance)m)")
            print("   📊 RECALCULATED Distance: \(String(format: "%.2f", recalculatedDistance/1000))km (\(recalculatedDistance)m)")

            let difference = abs(recalculatedDistance - metrics.totalDistance)
            let percentDiff = (difference / metrics.totalDistance) * 100.0
            print("   📊 DIFFERENCE: \(String(format: "%.2f", difference/1000))km (\(String(format: "%.1f", percentDiff))%)")

            // Update metrics with recalculated values
            let oldDistance = metrics.totalDistance
            metrics.totalDistance = recalculatedDistance

            // Recalculate average speed
            if metrics.duration > 0 {
                let oldAvgSpeed = metrics.averageSpeed
                metrics.averageSpeed = recalculatedDistance / metrics.duration
                print("   🏃 Average Speed: \(String(format: "%.1f", oldAvgSpeed * 3.6))km/h → \(String(format: "%.1f", metrics.averageSpeed * 3.6))km/h")
            }

            // Recalculate steps if needed
            let activityType = self.activeFlight.workoutType.flatMap { HKWorkoutActivityType(rawValue: $0) } ?? .walking
            if activityType == .running || activityType == .walking || activityType == .hiking {
                let strideLength: Double = activityType == .running ? 1.2 : 0.75
                let oldSteps = metrics.stepsCount ?? 0
                metrics.stepsCount = recalculatedDistance / strideLength
                print("   👟 Steps: \(String(format: "%.0f", oldSteps)) → \(String(format: "%.0f", metrics.stepsCount ?? 0))")
            }

            // Save updated flight back to local storage
            var updatedFlight = self.activeFlight
            updatedFlight.metrics = metrics

            print("💾 Saving recalculated metrics to local storage...")
            print("   Flight ID: \(updatedFlight.id)")
            print("   Locations count: \(updatedFlight.locations.count)")
            print("   Distance: \(String(format: "%.2f", metrics.totalDistance/1000))km")
            FlightDataStore.shared.saveFlight(updatedFlight)
            print("✅ Saved to local storage - full details persisted")

            print("🧮 ========================================")

            // Update UI
            DispatchQueue.main.async {
                self.isRecalculating = false

                // Update the detailed flight with new metrics
                self.detailedFlight = updatedFlight

                if difference > 100.0 { // More than 100m difference
                    self.recalculateMessage = """
                    ✅ Distance Recalculated!

                    BEFORE: \(String(format: "%.2f", oldDistance/1000))km
                    AFTER: \(String(format: "%.2f", recalculatedDistance/1000))km

                    Difference: \(String(format: "%.2f", difference/1000))km (\(String(format: "%.1f", percentDiff))%)

                    Valid GPS segments: \(validSegments)
                    Invalid/glitch segments: \(invalidSegments)

                    The corrected distance has been saved. The UI will update automatically.
                    """
                } else {
                    self.recalculateMessage = """
                    ✅ Distance Verified!

                    Distance: \(String(format: "%.2f", recalculatedDistance/1000))km

                    No significant corruption detected.
                    Valid GPS segments: \(validSegments)
                    """
                }

                self.showRecalculateAlert = true
            }
        }
    }

    private func loadDetailsIfNeeded() {
        guard !hasAttemptedDetailLoad else { return }
        hasAttemptedDetailLoad = true
        guard activeFlight.locations.isEmpty else { return }

        isLoadingDetails = true
        DispatchQueue.global(qos: .userInitiated).async {
            let details = FlightDataStore.shared.loadFlightDetails(id: flight.id)
            DispatchQueue.main.async {
                self.detailedFlight = details
                self.isLoadingDetails = false
            }
        }
    }
}

// MARK: - Supporting Views

struct DetailMetricCard: View {
    let icon: String
    let title: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)

            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.title3)
                        .fontWeight(.bold)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct DetailRow: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)

            Text(title)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .fontWeight(.medium)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Chart Views

@available(iOS 16.0, *)
struct SpeedChartView: View {
    let speedHistory: [SpeedSample]
    let maxSpeed: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(Array(speedHistory.enumerated()), id: \.offset) { index, sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Speed", sample.speed * 3.6) // Convert to km/h
                    )
                    .foregroundStyle(Color.blue.gradient)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Speed", sample.speed * 3.6)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

                // Max speed reference line
                RuleMark(y: .value("Max", maxSpeed * 3.6))
                    .foregroundStyle(Color.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
            .chartYAxisLabel("Speed (km/h)")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            // Legend
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                    Text("Speed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Color.red.opacity(0.5))
                        .frame(width: 12, height: 2)
                    Text("Max: \(String(format: "%.1f", maxSpeed * 3.6)) km/h")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }
}

@available(iOS 16.0, *)
struct AltitudeChartView: View {
    let altitudeHistory: [AltitudeSample]
    let maxAltitude: Double
    let minAltitude: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(Array(altitudeHistory.enumerated()), id: \.offset) { index, sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Altitude", sample.altitude)
                    )
                    .foregroundStyle(Color.purple.gradient)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Altitude", sample.altitude)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.3), Color.purple.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

                // Max altitude reference line
                RuleMark(y: .value("Max", maxAltitude))
                    .foregroundStyle(Color.green.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))

                // Min altitude reference line
                RuleMark(y: .value("Min", minAltitude))
                    .foregroundStyle(Color.orange.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
            .chartYAxisLabel("Altitude (m)")
            .chartYScale(domain: (minAltitude - 10)...(maxAltitude + 10))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            // Legend
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.purple)
                        .frame(width: 8, height: 8)
                    Text("Altitude")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Color.green.opacity(0.5))
                        .frame(width: 12, height: 2)
                    Text("Max: \(String(format: "%.0f", maxAltitude))m")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Color.orange.opacity(0.5))
                        .frame(width: 12, height: 2)
                    Text("Min: \(String(format: "%.0f", minAltitude))m")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }
}

@available(iOS 16.0, *)
struct PaceChartView: View {
    let speedHistory: [SpeedSample]
    let activityType: HKWorkoutActivityType?

    // Convert speed (m/s) to pace (min/km)
    private var paceHistory: [(timestamp: Date, pace: Double)] {
        speedHistory.compactMap { sample in
            guard sample.speed > 0.01 else { return nil } // Avoid division by very small numbers

            // Formula: pace (min/km) = 1000 meters / speed (m/s) / 60 seconds
            // Example: speed = 2.78 m/s (10 km/h) → pace = 1000/2.78/60 = 6.0 min/km ✓
            let paceSecondsPerKm = 1000.0 / sample.speed  // seconds per kilometer
            let paceMinPerKm = paceSecondsPerKm / 60.0    // convert to minutes per kilometer

            // Adjust pace filter based on activity type
            let paceRange = getPaceRange()
            guard paceMinPerKm >= paceRange.min && paceMinPerKm <= paceRange.max else { return nil }
            return (sample.timestamp, paceMinPerKm)
        }
    }

    private func getPaceRange() -> (min: Double, max: Double) {
        switch activityType {
        case .running:
            // Running: typically 3-10 min/km (6-20 km/h)
            return (3.0, 10.0)
        case .walking:
            // Walking: typically 8-20 min/km (3-7.5 km/h)
            return (8.0, 20.0)
        case .hiking:
            // Hiking: typically 10-30 min/km (2-6 km/h)
            return (10.0, 30.0)
        default:
            // Default range for other activities
            return (2.0, 30.0)
        }
    }

    private var averagePace: Double {
        guard !paceHistory.isEmpty else { return 0 }
        return paceHistory.map { $0.pace }.reduce(0, +) / Double(paceHistory.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !paceHistory.isEmpty {
                Chart {
                    ForEach(Array(paceHistory.enumerated()), id: \.offset) { index, sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Pace", sample.pace)
                        )
                        .foregroundStyle(Color.orange.gradient)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Pace", sample.pace)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.3), Color.orange.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }

                    // Average pace reference line
                    if averagePace > 0 {
                        RuleMark(y: .value("Avg", averagePace))
                            .foregroundStyle(Color.blue.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    }
                }
                .chartYAxisLabel("Pace (min/km)")
                .chartYScale(domain: .automatic(includesZero: false, reversed: true)) // Reversed: faster pace = lower min/km (top), slower pace = higher min/km (bottom)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                // Legend and Info
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                            Text("Pace")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if averagePace > 0 {
                            HStack(spacing: 4) {
                                Rectangle()
                                    .fill(Color.blue.opacity(0.5))
                                    .frame(width: 12, height: 2)
                                Text("Avg: \(formatPace(averagePace))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Explanation
                    Text("Note: Pace is inverse of speed. Lower = faster (e.g. 10 km/h = 6:00 min/km)")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .padding(.horizontal)
            } else {
                Text("Not enough data for pace calculation")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
            }
        }
    }

    private func formatPace(_ pace: Double) -> String {
        let minutes = Int(pace)
        let seconds = Int((pace - Double(minutes)) * 60)
        return String(format: "%d:%02d /km", minutes, seconds)
    }
}

@available(iOS 16.0, *)
struct PressureChartView: View {
    let pressureHistory: [PressureSample]

    private var maxPressure: Double {
        pressureHistory.map { $0.pressure * 10 }.max() ?? 1013.0
    }

    private var minPressure: Double {
        pressureHistory.map { $0.pressure * 10 }.min() ?? 1013.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(Array(pressureHistory.enumerated()), id: \.offset) { index, sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Pressure", sample.pressure * 10) // Convert kPa to hPa
                    )
                    .foregroundStyle(Color.cyan.gradient)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Pressure", sample.pressure * 10)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.3), Color.cyan.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

                // Max pressure reference line
                RuleMark(y: .value("Max", maxPressure))
                    .foregroundStyle(Color.blue.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))

                // Min pressure reference line
                RuleMark(y: .value("Min", minPressure))
                    .foregroundStyle(Color.orange.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
            .chartYAxisLabel("Pressure (hPa)")
            .chartYScale(domain: (minPressure - 5)...(maxPressure + 5))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            // Legend
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 8, height: 8)
                    Text("Pressure")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Color.blue.opacity(0.5))
                        .frame(width: 12, height: 2)
                    Text("Max: \(String(format: "%.1f", maxPressure)) hPa")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Color.orange.opacity(0.5))
                        .frame(width: 12, height: 2)
                    Text("Min: \(String(format: "%.1f", minPressure)) hPa")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }
}
