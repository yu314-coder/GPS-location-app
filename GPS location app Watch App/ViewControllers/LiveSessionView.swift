import SwiftUI
import CoreLocation
import HealthKit

struct LiveSessionView: View {
    @StateObject private var workoutSession = WorkoutSession()
    @Environment(\.dismiss) private var dismiss

    @State private var showStopConfirmation = false
    @State private var showWorkoutTypeSelector = false
    @State private var selectedWorkoutType: HKWorkoutActivityType = .walking

    // Performance optimization: Throttled UI updates
    @State private var displayMetrics = FlightMetrics()
    @State private var elapsedTime: TimeInterval = 0
    @State private var timeSinceLastGPS: TimeInterval = 0

    // Timer for smooth UI updates (updates every 1 second instead of every GPS point)
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // High-precision timer for workout time display (0.01s updates)
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
        ScrollView {
            VStack(spacing: 12) {
                // Status Header
                if workoutSession.isActive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(workoutSession.isPaused ? Color.orange : Color.red)
                            .frame(width: 6, height: 6)
                        Text(workoutSession.isPaused ? "PAUSED" : "LIVE")
                            .font(.caption2)
                            .foregroundColor(workoutSession.isPaused ? .orange : .red)
                    }
                }

                // Workout Type Display
                if workoutSession.isActive {
                    HStack {
                        Image(systemName: getWorkoutIcon(selectedWorkoutType))
                            .font(.caption)
                        Text(getWorkoutName(selectedWorkoutType))
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)
                }

                // Metrics (using throttled display metrics for smooth UI)
                if workoutSession.isActive {
                    // High-precision timer display (0.01s precision)
                    Text(formatPreciseTime(elapsedTime))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.green)
                        .padding(.vertical, 8)

                    MetricsView(
                        metrics: displayMetrics,
                        nativeStepDistanceMeters: workoutSession.nativePedometerDistanceMeters
                    )
                        .padding(.vertical, 4)

                    // GPS Tracking Status - Critical for monitoring GPS health
                    GPSTrackingStatusView(
                        signalQuality: workoutSession.locationManager.gpsSignalQuality,
                        horizontalAccuracy: workoutSession.locationManager.currentLocation?.horizontalAccuracy,
                        timeSinceLastGPS: timeSinceLastGPS,
                        locationCount: workoutSession.flight.locations.count,
                        isTracking: workoutSession.locationManager.isTracking,
                        isUsingIPhoneFallback: workoutSession.isUsingIPhoneGPSFallback,
                        fallbackStatus: workoutSession.fallbackDebugStatus
                    )

                    Text(workoutSession.networkDebugMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)

                    Text(workoutSession.networkPathStatus)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)

                    Text(
                        "Native steps: \(workoutSession.nativePedometerStepCount) • native step distance: \(String(format: "%.2f", workoutSession.nativePedometerDistanceMeters / 1000.0))km"
                    )
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                    Text(
                        "Pedometer freq: \(String(format: "%.2f", workoutSession.nativePedometerCallbackHz))Hz • native age: \(String(format: "%.1f", workoutSession.nativePedometerCallbackAgeSeconds))s • query age: \(String(format: "%.1f", workoutSession.nativePedometerQueryAgeSeconds))s"
                    )
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                } else {
                    // Not started - show workout type selector
                    VStack(spacing: 12) {
                        Image(systemName: "location.fill.viewfinder")
                            .font(.system(size: 40))
                            .foregroundColor(.blue)

                        Text("Ready to Track")
                            .font(.headline)

                        // Workout Type Button
                        Button(action: {
                            showWorkoutTypeSelector = true
                        }) {
                            HStack {
                                Image(systemName: getWorkoutIcon(selectedWorkoutType))
                                Text(getWorkoutName(selectedWorkoutType))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                            }
                            .font(.caption)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                        }
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                    }
                    .padding(.vertical)
                }

                // Control Buttons
                if workoutSession.isActive {
                    VStack(spacing: 8) {
                        // Pause/Resume button
                        if workoutSession.isPaused {
                            Button(action: {
                                print("⌚ 🔘 Resume button tapped by user")
                                workoutSession.resumeWorkout()
                            }) {
                                HStack {
                                    Image(systemName: "play.fill")
                                        .font(.caption)
                                    Text("Resume")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(
                                        colors: [Color.green, Color.green.opacity(0.8)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .foregroundColor(.white)
                                .cornerRadius(20)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(action: {
                                print("⌚ 🔘 Pause button tapped by user")
                                workoutSession.pauseWorkout()
                            }) {
                                HStack {
                                    Image(systemName: "pause.fill")
                                        .font(.caption)
                                    Text("Pause")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(
                                        colors: [Color.orange, Color.orange.opacity(0.8)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .foregroundColor(.white)
                                .cornerRadius(20)
                            }
                            .buttonStyle(.plain)
                        }

                        // Manual cellular/WiFi refresh button (useful in tunnels / poor GPS areas)
                        Button(action: {
                            print("⌚ 🔘 Refresh Net button tapped by user")
                            workoutSession.refreshCellularFallback()
                        }) {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.caption)
                                Text("Refresh Net")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue, Color.blue.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)

                        // Stop button
                        Button(action: {
                            showStopConfirmation = true
                        }) {
                            HStack {
                                Image(systemName: "stop.fill")
                                    .font(.caption)
                                Text("Stop")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(
                                    colors: [Color.red, Color.red.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                } else {
                    Button(action: {
                        // Immediate feedback - move work off main thread
                        print("⌚ Start button tapped")

                        // Run async to prevent button lag
                        Task {
                            await startWorkoutAsync()
                        }
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.title3)
                            Text("Start Tracking")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(
                                colors: [Color.green, Color.green.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .foregroundColor(.white)
                        .cornerRadius(20)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWorkoutTypeSelector) {
            WatchWorkoutTypeSelectorView(selectedType: $selectedWorkoutType)
        }
        .confirmationDialog("Stop Tracking", isPresented: $showStopConfirmation) {
            Button("Stop & Save", role: .destructive) {
                workoutSession.stopWorkout { success in
                    DispatchQueue.main.async {
                        if success {
                            print("✅ Workout stopped successfully")
                            dismiss()
                        } else {
                            print("⚠️ Workout stop had issues")
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save this workout?")
        }
        .onAppear {
            print("⌚ LiveSessionView appeared")

            // Request permissions on appear
            let locationStatus = workoutSession.locationManager.authorizationStatus
            if locationStatus == .notDetermined {
                print("📍 Requesting location permission on appear...")
                workoutSession.locationManager.requestAuthorization()
            }

            // Request HealthKit if needed
            if !workoutSession.healthKitManager.isAuthorized {
                workoutSession.healthKitManager.requestAuthorization { success, error in
                    if success {
                        print("✅ HealthKit authorized")
                    } else {
                        print("❌ HealthKit denied: \(error?.localizedDescription ?? "Unknown")")
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            // Update UI metrics only once per second for smooth performance
            // This prevents the UI from updating on every GPS point (which can be multiple times per second)
            if workoutSession.isActive {
                displayMetrics = workoutSession.currentMetrics
                // CRITICAL: Calculate time since last GPS update to detect when GPS breaks
                timeSinceLastGPS = Date().timeIntervalSince(workoutSession.lastLocationTime)
                if timeSinceLastGPS > 5 {
                    let source: String
                    if workoutSession.isUsingIPhoneGPSFallback {
                        source = "iPhone fallback"
                    } else if workoutSession.networkPathStatus.contains("fallback:pending") {
                        source = "iPhone fallback request"
                    } else {
                        source = "watch GPS"
                    }
                    workoutSession.networkDebugMessage = "Waiting for fresh fix from \(source): \(Int(timeSinceLastGPS))s"
                }
            }
        }
        .onReceive(precisionTimer) { _ in
            // Update elapsed time every 0.01s for high-precision timer display
            // IMPORTANT: Only update when active AND not paused
            if workoutSession.isActive && !workoutSession.isPaused {
                elapsedTime = Date().timeIntervalSince(workoutSession.flight.startDate)
            }
            // When paused, elapsedTime stays frozen at the value it had when pause was pressed
        }
    }

    private func startWorkoutAsync() async {
        // Check location permission
        let locationStatus = workoutSession.locationManager.authorizationStatus

        if locationStatus == .notDetermined {
            print("📍 Requesting location permission...")
            await MainActor.run {
                workoutSession.locationManager.requestAuthorization()
            }

            // Wait briefly for permission to be granted
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds

            // Check again after waiting
            await startWorkoutIfAuthorizedAsync()
        } else if locationStatus == .denied || locationStatus == .restricted {
            print("❌ Location permission denied")
        } else {
            await startWorkoutIfAuthorizedAsync()
        }
    }

    private func startWorkoutIfAuthorizedAsync() async {
        await MainActor.run {
            let locationStatus = workoutSession.locationManager.authorizationStatus
            let healthKitStatus = workoutSession.healthKitManager.isAuthorized

            print("🔐 Checking authorization...")
            print("📍 Location: \(locationStatus.rawValue)")
            print("🏥 HealthKit: \(healthKitStatus)")

            if locationStatus == .authorizedAlways || locationStatus == .authorizedWhenInUse {
                print("✅ Starting workout with type: \(selectedWorkoutType.rawValue)")
                // IMPORTANT: Set workout type BEFORE starting workout
                workoutSession.setWorkoutType(selectedWorkoutType)
                workoutSession.startWorkout()
            } else {
                print("❌ Cannot start - location not authorized")
            }
        }
    }

    private func startWorkoutIfAuthorized() {
        let locationStatus = workoutSession.locationManager.authorizationStatus
        let healthKitStatus = workoutSession.healthKitManager.isAuthorized

        print("🔐 Checking authorization...")
        print("📍 Location: \(locationStatus.rawValue)")
        print("🏥 HealthKit: \(healthKitStatus)")

        if locationStatus == .authorizedAlways || locationStatus == .authorizedWhenInUse {
            print("✅ Starting workout with type: \(selectedWorkoutType.rawValue)")
            // IMPORTANT: Set workout type BEFORE starting workout
            workoutSession.setWorkoutType(selectedWorkoutType)
            workoutSession.startWorkout()
        } else {
            print("❌ Cannot start - location not authorized")
        }
    }

    private func getWorkoutName(_ type: HKWorkoutActivityType) -> String {
        workoutTypes.first(where: { $0.0 == type })?.1 ?? "Unknown"
    }

    private func getWorkoutIcon(_ type: HKWorkoutActivityType) -> String {
        workoutTypes.first(where: { $0.0 == type })?.2 ?? "figure.mixed.cardio"
    }

    private func formatPreciseTime(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        let centiseconds = Int((interval.truncatingRemainder(dividingBy: 1.0)) * 100)

        if hours > 0 {
            return String(format: "%d:%02d:%02d.%02d", hours, minutes, seconds, centiseconds)
        } else {
            return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
        }
    }
}

// MARK: - Watch Workout Type Selector

struct WatchWorkoutTypeSelectorView: View {
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
        List {
            ForEach(workoutTypes, id: \.0.rawValue) { type in
                Button(action: {
                    selectedType = type.0
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: type.2)
                            .foregroundColor(.blue)
                            .frame(width: 20)
                        Text(type.1)
                            .font(.caption)
                        Spacer()
                        if selectedType == type.0 {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                                .font(.caption2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Workout Type")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - GPS Tracking Status View (Critical for monitoring GPS health)

struct GPSTrackingStatusView: View {
    let signalQuality: GPSSignalQuality
    let horizontalAccuracy: Double?
    let timeSinceLastGPS: TimeInterval
    let locationCount: Int
    let isTracking: Bool
    let isUsingIPhoneFallback: Bool
    var fallbackStatus: String = ""

    var body: some View {
        VStack(spacing: 8) {
            // GPS Status Header with Warning
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.caption2)
                    .foregroundColor(gpsStatusColor)

                Text("GPS Tracking")
                    .font(.caption2)
                    .fontWeight(.semibold)

                Spacer()

                // GPS Signal Bars
                HStack(spacing: 2) {
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(index < displaySignalQuality.barCount ? signalColor : Color.gray.opacity(0.3))
                            .frame(width: 3, height: CGFloat(4 + index * 2))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(gpsStatusBackgroundColor)
            .cornerRadius(8)

            // Detailed GPS Stats
            VStack(spacing: 4) {
                // Time Since Last GPS Update (CRITICAL)
                HStack {
                    Image(systemName: timeSinceLastGPS > 10 ? "exclamationmark.triangle.fill" : "clock")
                        .font(.caption2)
                        .foregroundColor(timeSinceLastGPS > 10 ? .red : .gray)

                    Text("Last Update:")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(formatTimeSinceGPS(timeSinceLastGPS))
                        .font(.caption2)
                        .monospacedDigit()
                        .fontWeight(timeSinceLastGPS > 10 ? .bold : .regular)
                        .foregroundColor(gpsUpdateTimeColor)
                }

                // Location Count
                HStack {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.caption2)
                        .foregroundColor(.gray)

                    Text("Locations:")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("\(locationCount)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundColor(.primary)
                }

                // GPS Accuracy
                if let accuracy = horizontalAccuracy {
                    HStack {
                        Image(systemName: "target")
                            .font(.caption2)
                            .foregroundColor(.gray)

                        Text("Accuracy:")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Spacer()

                        Text("±\(Int(accuracy))m")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundColor(accuracyColor(accuracy))
                    }
                }

                // GPS Status
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundColor(.gray)

                    Text("Status:")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(displaySignalQuality.description)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(signalColor)
                }

                HStack {
                    Image(systemName: "scope")
                        .font(.caption2)
                        .foregroundColor(.gray)

                    Text("Source:")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(isUsingIPhoneFallback ? "iPhone fallback" : "Watch GPS")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(isUsingIPhoneFallback ? .blue : .primary)
                }

                // Live fallback / dead-reckoning status (debug)
                if !fallbackStatus.isEmpty {
                    HStack {
                        Image(systemName: "gyroscope")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        Text("Fallback:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(fallbackStatus)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .foregroundColor(fallbackStatus.hasPrefix("GPS OK") ? .green : .orange)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            // GPS BROKEN WARNING
            if timeSinceLastGPS > 30 && isTracking {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("GPS NOT RESPONDING!")
                        .font(.caption2)
                        .fontWeight(.bold)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red)
                .cornerRadius(6)
            } else if timeSinceLastGPS > 10 && isTracking {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                    Text("GPS Delayed (\(Int(timeSinceLastGPS))s)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange)
                .cornerRadius(6)
            }
        }
    }

    // MARK: - Helper Functions

    private var gpsStatusColor: Color {
        if !isTracking {
            return .gray
        } else if timeSinceLastGPS > 30 {
            return .red
        } else if timeSinceLastGPS > 10 {
            return .orange
        } else {
            return .green
        }
    }

    private var gpsStatusBackgroundColor: Color {
        if timeSinceLastGPS > 30 {
            return Color.red.opacity(0.15)
        } else if timeSinceLastGPS > 10 {
            return Color.orange.opacity(0.15)
        } else {
            return Color.green.opacity(0.1)
        }
    }

    private var signalColor: Color {
        switch displaySignalQuality {
        case .unknown:
            return .gray
        case .noSignal:
            return .red
        case .poor:
            return .orange
        case .fair:
            return .yellow
        case .good:
            return Color(red: 0.5, green: 0.8, blue: 0.3)
        case .excellent:
            return .green
        }
    }

    private var displaySignalQuality: GPSSignalQuality {
        guard isTracking else { return .unknown }
        if timeSinceLastGPS > 30 {
            return .noSignal
        } else if timeSinceLastGPS > 10 {
            return .poor
        } else if timeSinceLastGPS > 5, signalQuality == .excellent {
            // Prevent stale "excellent" when no fresh fix is arriving.
            return .fair
        } else {
            return signalQuality
        }
    }

    private var gpsUpdateTimeColor: Color {
        if timeSinceLastGPS > 30 {
            return .red
        } else if timeSinceLastGPS > 10 {
            return .orange
        } else if timeSinceLastGPS > 5 {
            return .yellow
        } else {
            return .green
        }
    }

    private func accuracyColor(_ accuracy: Double) -> Color {
        if accuracy < 10 {
            return .green
        } else if accuracy < 20 {
            return Color(red: 0.5, green: 0.8, blue: 0.3)
        } else if accuracy < 50 {
            return .yellow
        } else if accuracy < 100 {
            return .orange
        } else {
            return .red
        }
    }

    private func formatTimeSinceGPS(_ time: TimeInterval) -> String {
        if time < 1 {
            return "0s"
        } else if time < 60 {
            return "\(Int(time))s"
        } else {
            let minutes = Int(time) / 60
            let seconds = Int(time) % 60
            return "\(minutes)m \(seconds)s"
        }
    }
}

struct LiveSessionView_Previews: PreviewProvider {
    static var previews: some View {
        LiveSessionView()
    }
}
