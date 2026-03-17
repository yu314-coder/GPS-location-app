import SwiftUI
import CoreLocation
import HealthKit

struct LiveSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var workoutSession = WorkoutSession.shared
    @State private var showStopConfirmation = false
    @State private var showWorkoutTypeSelector = false
    @State private var selectedWorkoutType: HKWorkoutActivityType = .walking
    @State private var showLogs = false
    @State private var showSummary = false
    @State private var completedFlight: Flight?
    @State private var isStopping = false

    // High-precision timer for smooth workout time display (0.01s updates)
    @State private var displayTime: TimeInterval = 0
    let precisionTimer = Timer.publish(every: 0.01, on: .main, in: .common).autoconnect()

    // Available workout types
    let workoutTypes: [(HKWorkoutActivityType, String, String)] = [
        (.cycling, "Cycling", "bicycle"),
        (.running, "Running", "figure.run"),
        (.walking, "Walking", "figure.walk"),
        (.hiking, "Hiking", "mountain.2.fill"),
        (.other, "Flight", "airplane"),
        (.traditionalStrengthTraining, "General", "figure.mixed.cardio")
    ]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 8) {
                    Text("Flight Tracking")
                        .font(.headline)
                        .foregroundColor(.white)

                    if workoutSession.isActive {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(workoutSession.isPaused ? Color.orange : Color.red)
                                .frame(width: 8, height: 8)
                            Text(workoutSession.isPaused ? "PAUSED" : "LIVE")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)

                // Content
                ScrollView {
                    VStack(spacing: 20) {
                        // Metrics Display
                        if workoutSession.isActive {
                            // Workout Type Display
                            HStack {
                                Image(systemName: getWorkoutIcon(selectedWorkoutType))
                                Text(getWorkoutName(selectedWorkoutType))
                                    .font(.headline)
                                Spacer()
                                Text(formatDuration(displayTime))
                                    .font(.headline)
                                    .foregroundColor(.blue)
                            }
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(12)
                            .padding(.horizontal)

                        // Live metrics with modern design
                        VStack(spacing: 16) {
                            ModernLiveMetricCard(
                                title: "Distance",
                                value: String(format: "%.2f", workoutSession.currentMetrics.totalDistance / 1000),
                                unit: "km",
                                icon: "figure.walk",
                                color: .green
                            )

                            HStack(spacing: 12) {
                                ModernLiveMetricCard(
                                    title: "Speed",
                                    value: String(format: "%.1f", workoutSession.currentMetrics.currentSpeed * 3.6),
                                    unit: "km/h",
                                    icon: "speedometer",
                                    color: .blue
                                )

                                if let heartRate = workoutSession.currentMetrics.currentHeartRate {
                                    ModernLiveMetricCard(
                                        title: "Heart Rate",
                                        value: String(format: "%.0f", heartRate),
                                        unit: "bpm",
                                        icon: "heart.fill",
                                        color: .red
                                    )
                                } else {
                                    ModernLiveMetricCard(
                                        title: "Avg Speed",
                                        value: String(format: "%.1f", workoutSession.currentMetrics.averageSpeed * 3.6),
                                        unit: "km/h",
                                        icon: "gauge.medium",
                                        color: .orange
                                    )
                                }
                            }

                            HStack(spacing: 12) {
                                ModernLiveMetricCard(
                                    title: "Altitude",
                                    value: String(format: "%.0f", workoutSession.currentMetrics.currentAltitude),
                                    unit: "m",
                                    icon: "mountain.2.fill",
                                    color: .purple
                                )

                                if let pressure = workoutSession.locationManager.currentPressure {
                                    ModernLiveMetricCard(
                                        title: "Pressure",
                                        value: String(format: "%.1f", pressure * 10), // Convert kPa to hPa (millibars)
                                        unit: "hPa",
                                        icon: "gauge",
                                        color: .cyan
                                    )
                                } else {
                                    ModernLiveMetricCard(
                                        title: "Calories",
                                        value: String(format: "%.0f", workoutSession.currentMetrics.caloriesBurned),
                                        unit: "kcal",
                                        icon: "flame.fill",
                                        color: .orange
                                    )
                                }
                            }

                            // Additional row if pressure is available (to show calories)
                            if workoutSession.locationManager.currentPressure != nil {
                                HStack(spacing: 12) {
                                    ModernLiveMetricCard(
                                        title: "Calories",
                                        value: String(format: "%.0f", workoutSession.currentMetrics.caloriesBurned),
                                        unit: "kcal",
                                        icon: "flame.fill",
                                        color: .orange
                                    )

                                    // Placeholder for symmetry
                                    Color.clear
                                        .frame(maxWidth: .infinity)
                                }
                            }

                            // Additional Stats
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Max Speed:")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f km/h", workoutSession.currentMetrics.maxSpeed * 3.6))
                                        .fontWeight(.medium)
                                }

                                HStack {
                                    Text("Max Altitude:")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.0f m", workoutSession.currentMetrics.maxAltitude))
                                        .fontWeight(.medium)
                                }

                                HStack {
                                    Text("Avg Speed:")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f km/h", workoutSession.currentMetrics.averageSpeed * 3.6))
                                        .fontWeight(.medium)
                                }

                                HStack {
                                    Text("Location Points:")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(workoutSession.flight.locations.count)")
                                        .fontWeight(.medium)
                                }
                            }
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(12)

                            // Show/Hide Logs Button
                            Button(action: {
                                showLogs.toggle()
                            }) {
                                HStack {
                                    Image(systemName: showLogs ? "eye.slash" : "eye")
                                    Text(showLogs ? "Hide Logs" : "Show Logs")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(.systemGray5))
                                .foregroundColor(.primary)
                                .cornerRadius(12)
                            }

                            // Logs Section
                            if showLogs {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Live Tracking Data")
                                        .font(.headline)
                                        .padding(.bottom, 4)

                                    ScrollView(.vertical, showsIndicators: true) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            let locations = Array(workoutSession.flight.locations.suffix(100))

                                            ForEach(Array(locations.enumerated()), id: \.offset) { index, location in
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        HStack {
                                                            Text("[\(formatTime(location.timestamp))]")
                                                                .font(.caption2)
                                                                .foregroundColor(.secondary)

                                                            // Show time delta between GPS points
                                                            if index > 0 {
                                                                let prevLocation = locations[index - 1]
                                                                let timeDelta = location.timestamp.timeIntervalSince(prevLocation.timestamp)
                                                                Text(String(format: "Δt: %.2fs", timeDelta))
                                                                    .font(.caption2)
                                                                    .foregroundColor(timeDelta <= 0.2 ? .green : .orange)
                                                            }
                                                        }

                                                        HStack {
                                                            Text("📍 Lat: \(String(format: "%.6f", location.latitude))")
                                                            Text("Lon: \(String(format: "%.6f", location.longitude))")
                                                        }
                                                        .font(.caption)

                                                        HStack {
                                                            Text("⛰ Alt: \(String(format: "%.1f", location.altitude))m")
                                                            Text("🎯 Acc: ±\(String(format: "%.1f", location.horizontalAccuracy))m")
                                                            if location.isFiltered {
                                                                Image(systemName: "waveform.path.ecg")
                                                                    .foregroundColor(.green)
                                                            }
                                                        }
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)

                                                        Divider()
                                                    }
                                            }

                                            if let heartRate = workoutSession.currentMetrics.currentHeartRate {
                                                HStack {
                                                    Text("❤️ Heart Rate:")
                                                    Text("\(Int(heartRate)) bpm")
                                                        .fontWeight(.bold)
                                                    if let avg = workoutSession.currentMetrics.averageHeartRate {
                                                        Text("(Avg: \(Int(avg)))")
                                                            .foregroundColor(.secondary)
                                                    }
                                                }
                                                .font(.caption)
                                                .padding(.top, 4)
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 300)
                                }
                                .padding()
                                .background(Color(.systemBackground))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color(.systemGray4), lineWidth: 1)
                                )
                            }

                            // Speed Graph
                            SpeedGraphView(speedHistory: workoutSession.currentMetrics.speedHistory)

                            // Altitude Graph
                            AltitudeGraphView(altitudeHistory: workoutSession.currentMetrics.altitudeHistory)

                            // Pressure Graph
                            if !workoutSession.currentMetrics.pressureHistory.isEmpty {
                                PressureGraphView(pressureHistory: workoutSession.currentMetrics.pressureHistory)
                            }
                        }
                        .padding()
                    } else {
                        // Not tracking
                        VStack(spacing: 20) {
                            Image(systemName: "location.fill.viewfinder")
                                .font(.system(size: 80))
                                .foregroundColor(.blue)

                            Text("GPS Tracking Ready")
                                .font(.title2)
                                .fontWeight(.bold)

                            Text("Start workout tracking on iPhone")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)

                            // Workout Type Selector
                            Button(action: {
                                showWorkoutTypeSelector = true
                            }) {
                                HStack {
                                    Image(systemName: getWorkoutIcon(selectedWorkoutType))
                                    Text("Workout Type: \(getWorkoutName(selectedWorkoutType))")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .padding()
                                .background(Color(.systemGray6))
                                .cornerRadius(12)
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal)
                        }
                        .padding()
                    }
                    }
                }

                // Control Buttons
                VStack(spacing: 12) {
                    if workoutSession.isActive {
                        // Pause/Resume button
                        if workoutSession.isPaused {
                            Button(action: {
                                workoutSession.resumeWorkout()
                            }) {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("Resume Tracking")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .disabled(!workoutSession.isPaused || !workoutSession.isActive)
                        } else {
                            Button(action: {
                                workoutSession.pauseWorkout()
                            }) {
                                HStack {
                                    Image(systemName: "pause.fill")
                                    Text("Pause Tracking")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .disabled(workoutSession.isPaused || !workoutSession.isActive)
                        }

                        // Stop tracking
                        Button(action: {
                            showStopConfirmation = true
                        }) {
                            HStack {
                                Image(systemName: "stop.fill")
                                Text("Stop Tracking")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isStopping)
                    } else {
                        // Start options
                        Button(action: {
                            workoutSession.setWorkoutType(selectedWorkoutType)
                            workoutSession.startWorkout()
                        }) {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("Start Tracking")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }

                        // REMOVED: "Start on Watch" button
                        // Workouts are now independent - start Watch workouts from Watch app
                    }
                }
                .padding()
            }

            if isStopping {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Stopping & saving...")
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
                .padding(20)
                .background(Color.black.opacity(0.7))
                .cornerRadius(12)
            }
        }
        .sheet(isPresented: $showWorkoutTypeSelector) {
            WorkoutTypeSelectorView(selectedType: $selectedWorkoutType)
        }
        .confirmationDialog("Stop Tracking", isPresented: $showStopConfirmation) {
            Button("Stop & Save", role: .destructive) {
                guard !isStopping else { return }
                isStopping = true
                DispatchQueue.main.async {
                    workoutSession.stopWorkout { success in
                        DispatchQueue.main.async {
                            isStopping = false
                            if success {
                                print("✅ Workout stopped successfully")
                                completedFlight = workoutSession.flight
                                // Show summary instead of dismissing
                                showSummary = true
                            } else {
                                print("⚠️ Workout stop had issues")
                                dismiss()
                            }
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stop and save your workout?")
        }
        .sheet(isPresented: $showSummary) {
            if let flight = completedFlight {
                NavigationView {
                    SummaryView(flight: flight)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") {
                                    showSummary = false
                                    dismiss()
                                }
                            }
                        }
                }
            }
        }
        .onAppear {
            print("📱 LiveSessionView appeared")

            // Check and request permissions
            let locationStatus = workoutSession.locationManager.authorizationStatus
            let healthKitAuthorized = workoutSession.healthKitManager.isAuthorized

            print("📍 Location status: \(locationStatus.rawValue)")
            print("🏥 HealthKit authorized: \(healthKitAuthorized)")

            // Request location permission if not determined
            if locationStatus == .notDetermined {
                print("📍 Requesting location permission...")
                workoutSession.locationManager.requestAuthorization()
            }

            // Request HealthKit permission if not authorized
            if !healthKitAuthorized {
                print("🏥 Requesting HealthKit permission...")
                workoutSession.healthKitManager.requestAuthorization { success, error in
                    if success {
                        print("✅ HealthKit authorized")
                    } else {
                        print("❌ HealthKit denied: \(error?.localizedDescription ?? "Unknown")")
                    }
                }
            }
        }
        .onReceive(precisionTimer) { _ in
            // Update timer every 0.01s for smooth, precise display
            // IMPORTANT: Only update when active AND not paused
            if workoutSession.isActive && !workoutSession.isPaused {
                displayTime = workoutSession.activeDuration
            }
            // When paused, displayTime stays frozen at the value it had when pause was pressed
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        let centiseconds = Int((duration.truncatingRemainder(dividingBy: 1.0)) * 100)

        if hours > 0 {
            return String(format: "%d:%02d:%02d.%02d", hours, minutes, seconds, centiseconds)
        } else {
            return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeString = formatter.string(from: date)

        // Add milliseconds for 0.1s precision
        let milliseconds = Int((date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1.0)) * 1000)
        return String(format: "%@.%03d", timeString, milliseconds)
    }

    private func getWorkoutName(_ type: HKWorkoutActivityType) -> String {
        workoutTypes.first(where: { $0.0 == type })?.1 ?? "Unknown"
    }

    private func getWorkoutIcon(_ type: HKWorkoutActivityType) -> String {
        workoutTypes.first(where: { $0.0 == type })?.2 ?? "figure.mixed.cardio"
    }
}

// MARK: - Workout Type Selector

struct WorkoutTypeSelectorView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedType: HKWorkoutActivityType

    let workoutTypes: [(HKWorkoutActivityType, String, String)] = [
        (.cycling, "Cycling", "bicycle"),
        (.running, "Running", "figure.run"),
        (.walking, "Walking", "figure.walk"),
        (.hiking, "Hiking", "mountain.2.fill"),
        (.other, "Flight", "airplane"),
        (.traditionalStrengthTraining, "General", "figure.mixed.cardio")
    ]

    var body: some View {
        NavigationView {
            List {
                ForEach(workoutTypes, id: \.0.rawValue) { type in
                    Button(action: {
                        selectedType = type.0
                        dismiss()
                    }) {
                        HStack {
                            Image(systemName: type.2)
                                .foregroundColor(.blue)
                                .frame(width: 30)
                            Text(type.1)
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedType == type.0 {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Workout Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Modern Live Metric Card Component

private struct ModernLiveMetricCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title)
                    .fontWeight(.bold)
                Text(unit)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - LiveMetricCard Component

private struct LiveMetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)

            Text(value)
                .font(.title3)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct LiveSessionView_Previews: PreviewProvider {
    static var previews: some View {
        LiveSessionView()
    }
}
