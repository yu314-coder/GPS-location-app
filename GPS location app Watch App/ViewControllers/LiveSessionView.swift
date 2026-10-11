import SwiftUI
import CoreLocation
import HealthKit

struct LiveSessionView: View {
    @StateObject private var workoutSession = WorkoutSession()
    @Environment(\.dismiss) private var dismiss

    @State private var showStopConfirmation = false
    @State private var showWorkoutTypeSelector = false
    @State private var selectedWorkoutType: HKWorkoutActivityType = .walking
    @AppStorage("velocityModeEnabled") private var velocityModeBeforeStart = false
    // Refresh Net shows only with the developer options on (five taps on the version in Settings).
    @AppStorage(WatchSpeedEngine.developerKey) private var developerUnlocked = false
    @State private var pausedTotal: TimeInterval = 0
    @State private var pausedSince: Date?

    // Performance optimization: Throttled UI updates
    @State private var displayMetrics = FlightMetrics()
    @State private var timeSinceLastGPS: TimeInterval = 0

    // Timer for smooth UI updates (updates every 1 second instead of every GPS point)
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // High-precision timer for workout time display (0.01s updates)

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
        Group {
            if workoutSession.isActive {
                activeList
            } else {
                readyView
            }
        }
        // Opaque: the sheet is otherwise translucent, and the home screen's green button glowed
        // through behind the list.
        .background(Color.black.ignoresSafeArea())
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

            // DEBUG: drive the synthetic-flight replay through this view's own session so the
            // reconstructed route shows on the watch simulator (no Core Motion there).
            if ProcessInfo.processInfo.arguments.contains("-replayFlight") {
                workoutSession.debugReplaySyntheticFlight()
            }

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
                // CRITICAL: also drive the GPS-gap fallbacks from THIS timer. On watchOS
                // the always-on/throttled state can starve the session's own keep-alive
                // RunLoop timer while this view timer keeps firing — that starvation is
                // why the accel/velocity dead reckoning never engaged (stuck on "GPS OK"
                // while the counter climbed). The tick is debounced so it runs at most
                // once per second no matter how many timers call it.
                workoutSession.runGpsGapFallbacksTick(source: "view")
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
        // The clock stops while paused and carries on from there, rather than jumping by the length of the
        // pause when the workout resumes (the clock itself is WatchWorkoutClock).
        .onAppear { if workoutSession.isPaused, pausedSince == nil { pausedSince = Date() } }
        .onChange(of: workoutSession.isPaused) { _, paused in
            let now = Date()
            if paused {
                if pausedSince == nil { pausedSince = now }
            } else if let since = pausedSince {
                pausedTotal += now.timeIntervalSince(since); pausedSince = nil
            }
        }
    }

    /// The workout as one list (restored in build 82 at the owner's request: everything is one
    /// scroll away, which the paged design of builds 79-81 was not). Only the speed-engine card is
    /// new.
    private var activeList: some View {
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
                    WatchWorkoutClock(start: workoutSession.flight.startDate, pausedTotal: pausedTotal,
                                      pausedSince: pausedSince, format: formatPreciseTime)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.green)
                        .padding(.vertical, 8)

                    MetricsView(
                        metrics: displayMetrics,
                        nativeStepDistanceMeters: workoutSession.nativePedometerDistanceMeters
                    )
                        .padding(.vertical, 4)

                    // Both speed engines, the iPhone and GPS this second, and which set the speed.
                    SpeedEnginesCard(readout: workoutSession.engineReadout)

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

                        if developerUnlocked {
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
                        }

                        // Force Velocity toggle: when ON, the watch ignores GPS and tracks
                        // distance/route purely from its own accelerometer + velocity dead
                        // reckoning (useful in known-bad-GPS areas, or to force the estimate).
                        // Toggling OFF hands back to normal GPS on the next real fix.
                        Button(action: {
                            workoutSession.forceMotionFallback.toggle()
                            print("⌚ 🔘 Force Velocity toggled -> \(workoutSession.forceMotionFallback ? "ON" : "OFF")")
                        }) {
                            HStack {
                                Image(systemName: workoutSession.forceMotionFallback ? "speedometer" : "location.fill")
                                    .font(.caption)
                                Text(workoutSession.forceMotionFallback ? "Velocity: ON" : "Force Velocity")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(
                                    colors: workoutSession.forceMotionFallback
                                        ? [Color.purple, Color.purple.opacity(0.8)]
                                        : [Color.gray.opacity(0.6), Color.gray.opacity(0.4)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)

                        // FLIGHT SPEED (build 113). Auto: the watch switches to its flight speed by
                        // itself once a takeoff roll or the cabin's climb confirms a flight. On: you
                        // say this is a flight, so the cabin leaving the ground is enough, and the
                        // watch's own flight speed leads even with an iPhone that hasn't found it.
                        Button(action: {
                            workoutSession.flightSpeedForced.toggle()
                            print("⌚ 🔘 Flight speed -> \(workoutSession.flightSpeedForced ? "ON" : "Auto")")
                        }) {
                            VStack(spacing: 2) {
                                HStack {
                                    Image(systemName: "airplane")
                                        .font(.caption)
                                    Text(workoutSession.flightSpeedForced ? "Flight: ON" : "Flight: Auto")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }
                                Text(workoutSession.flightStatus)
                                    .font(.system(size: 10))
                                    .opacity(0.85)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                LinearGradient(
                                    colors: workoutSession.flightSpeedForced
                                        ? [Color.cyan, Color.cyan.opacity(0.75)]
                                        : [Color.gray.opacity(0.6), Color.gray.opacity(0.4)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(workoutSession.flightSpeedForced ? "Flight speed on" : "Flight speed automatic")

                        // EMERGENCY FLIGHT (build 123): if the watch stops flying on its own mid-flight, keep the
                        // flight model running whatever the cabin says. Turn off after landing.
                        Button(action: {
                            workoutSession.flightEmergency.toggle()
                        }) {
                            VStack(spacing: 2) {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                    Text(workoutSession.flightEmergency ? "Flight forced ON" : "Force flight")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }
                                Text(workoutSession.flightEmergency ? "Turn off after landing" : "If it stops flying mid-flight")
                                    .font(.system(size: 10))
                                    .opacity(0.85)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(workoutSession.flightEmergency ? Color.orange : Color.gray.opacity(0.4))
                            .foregroundColor(.white)
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(workoutSession.flightEmergency ? "Flight forced on" : "Force flight")

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
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: - Before a workout

    private var readyView: some View {
        ScrollView {
            VStack(spacing: 10) {
                Button {
                    print("⌚ Start button tapped")
                    Task { await startWorkoutAsync() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 18, weight: .bold))
                        Text("Start").font(.system(size: 18, weight: .bold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green, in: Capsule())
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start \(getWorkoutName(selectedWorkoutType)) workout")

                Button { showWorkoutTypeSelector = true } label: {
                    HStack {
                        Image(systemName: getWorkoutIcon(selectedWorkoutType))
                            .foregroundStyle(.green)
                            .frame(width: 22)
                        Text(getWorkoutName(selectedWorkoutType))
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Toggle(isOn: $velocityModeBeforeStart) {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("Velocity Mode", systemImage: "speedometer")
                            .font(.system(size: 14, weight: .semibold))
                        Text(velocityModeBeforeStart ? "Speed and route from motion, no GPS" : "GPS tracking")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.purple)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))

                SpeedEngineStatusCard()
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Workout")
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

/// THE WORKOUT CLOCK ON ITS OWN (build 119, every frame since build 120). A timer firing 100 times a second used
/// to rebuild the whole workout list with it, in the background too (the iPhone's CPU reports on BR215 were
/// mostly SwiftUI). A TimelineView redraws only this text, once per display frame while it is on screen; with
/// the wrist down watchOS slows it on its own.
private struct WatchWorkoutClock: View {
    let start: Date
    let pausedTotal: TimeInterval
    let pausedSince: Date?
    let format: (TimeInterval) -> String

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.01, paused: false)) { context in
            let now = pausedSince ?? context.date
            Text(format(max(0, now.timeIntervalSince(start) - pausedTotal)))
        }
    }
}
