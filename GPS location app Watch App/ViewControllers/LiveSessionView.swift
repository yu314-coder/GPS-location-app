import SwiftUI
import MapKit
import CoreLocation
import HealthKit

/// The workout on the wrist (redesigned in build 79). Before a workout: one screen to pick the
/// activity, Velocity Mode and the speed engine, and start. During one, swipe up and down through
/// pages: the numbers that matter, both speed engines live, the map, the controls, and the full
/// details kept for testing.
struct LiveSessionView: View {
    @StateObject private var workoutSession = WorkoutSession()
    @Environment(\.dismiss) private var dismiss

    @State private var showStopConfirmation = false
    @State private var showWorkoutTypeSelector = false
    @State private var showEngineChoice = false
    @State private var selectedWorkoutType: HKWorkoutActivityType = .walking
    @State private var livePage = 0
    @AppStorage("velocityModeEnabled") private var velocityModeBeforeStart = false
    @AppStorage("speedUnit") private var speedUnit = "km/h"
    @AppStorage("distanceUnit") private var distanceUnit = "km"

    // Updated once a second: the screen never needs more, and the wrist's battery does.
    @State private var displayMetrics = FlightMetrics()
    @State private var elapsedTime: TimeInterval = 0
    @State private var timeSinceLastGPS: TimeInterval = 0
    @State private var pausedTotal: TimeInterval = 0
    @State private var pausedSince: Date?

    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

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
                livePages
            } else {
                readyView
            }
        }
        // Opaque: the sheet is otherwise translucent, and the home screen's green button glowed
        // through behind every page.
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showWorkoutTypeSelector) {
            WatchWorkoutTypeSelectorView(selectedType: $selectedWorkoutType)
        }
        .sheet(isPresented: $showEngineChoice) { SpeedEngineChoiceView() }
        .confirmationDialog("End workout?", isPresented: $showStopConfirmation) {
            Button("End & Save", role: .destructive) {
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
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("The route and the logs are saved.")
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
        .onReceive(timer) { now in
            guard workoutSession.isActive else { return }
            // CRITICAL: also drive the GPS-gap fallbacks from THIS timer. On watchOS the
            // always-on/throttled state can starve the session's own keep-alive RunLoop timer
            // while this view timer keeps firing — that starvation is why the accel/velocity
            // dead reckoning never engaged (stuck on "GPS OK" while the counter climbed). The
            // tick is debounced so it runs at most once per second no matter how many timers
            // call it.
            workoutSession.runGpsGapFallbacksTick(source: "view")
            displayMetrics = workoutSession.currentMetrics
            // The clock stops while paused and carries on from there, rather than jumping by the
            // length of the pause when the workout resumes.
            if workoutSession.isPaused {
                if pausedSince == nil { pausedSince = now }
            } else {
                if let since = pausedSince { pausedTotal += now.timeIntervalSince(since); pausedSince = nil }
                elapsedTime = max(0, now.timeIntervalSince(workoutSession.flight.startDate) - pausedTotal)
            }
            // CRITICAL: Calculate time since last GPS update to detect when GPS breaks
            timeSinceLastGPS = now.timeIntervalSince(workoutSession.lastLocationTime)
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

    // MARK: - During a workout

    private var livePages: some View {
        TabView(selection: $livePage) {
            nowPage.tag(0)
            SpeedEnginesPage(readout: workoutSession.engineReadout).tag(1)
            mapPage.tag(2)
            controlsPage.tag(3)
            detailsPage.tag(4)
        }
        .tabViewStyle(.verticalPage)
        .containerBackground(Color.black, for: .tabView)
    }

    private var speedFormatter: SpeedFormatter { SpeedFormatter(unit: speedUnit) }

    private var nowPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(workoutSession.isPaused ? Color.orange : Color.red)
                    .frame(width: 7, height: 7)
                Image(systemName: getWorkoutIcon(selectedWorkoutType))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatElapsed(elapsedTime))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(workoutSession.isPaused ? .orange : .yellow)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(workoutSession.isPaused ? "Paused, \(formatElapsed(elapsedTime))" : "Elapsed \(formatElapsed(elapsedTime))")

            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(speedFormatter.value(displayMetrics.currentSpeed))
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(speedUnit)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            SpeedSourceBadge(driving: workoutSession.engineReadout.driving)

            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                LiveFigure(value: distanceText, unit: distanceUnit == "mi" ? "mi" : "km",
                           label: "Distance", tint: .green)
                Spacer()
                if let hr = displayMetrics.currentHeartRate {
                    LiveFigure(value: String(format: "%.0f", hr), unit: "bpm", label: "Heart", tint: .red)
                } else {
                    LiveFigure(value: speedFormatter.value(displayMetrics.averageSpeed), unit: speedUnit,
                               label: "Average", tint: .cyan)
                }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
    }

    private var distanceText: String {
        let km = displayMetrics.distanceInKilometers
        return String(format: "%.2f", distanceUnit == "mi" ? km * 0.621_371 : km)
    }

    private var mapPage: some View {
        LiveRouteMap(locations: workoutSession.flight.locations,
                     gpsLocation: workoutSession.locationManager.currentLocation)
            .ignoresSafeArea()
    }

    private var controlsPage: some View {
        ScrollView {
            VStack(spacing: 8) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ControlTile(title: workoutSession.isPaused ? "Resume" : "Pause",
                                symbol: workoutSession.isPaused ? "play.fill" : "pause.fill",
                                tint: workoutSession.isPaused ? .green : .yellow) {
                        if workoutSession.isPaused {
                            print("⌚ 🔘 Resume button tapped by user")
                            workoutSession.resumeWorkout()
                        } else {
                            print("⌚ 🔘 Pause button tapped by user")
                            workoutSession.pauseWorkout()
                        }
                    }
                    // Velocity Mode: when ON the watch ignores GPS and tracks distance and route from
                    // its motion alone. Turning it OFF hands back to GPS on the next real fix.
                    ControlTile(title: workoutSession.forceMotionFallback ? "Velocity on" : "Velocity off",
                                symbol: "speedometer",
                                tint: workoutSession.forceMotionFallback ? .purple : .gray) {
                        workoutSession.forceMotionFallback.toggle()
                        print("⌚ 🔘 Force Velocity toggled -> \(workoutSession.forceMotionFallback ? "ON" : "OFF")")
                    }
                    ControlTile(title: workoutSession.engineReadout.choice.title, symbol: "brain",
                                tint: .purple, caption: "Speed engine") { showEngineChoice = true }
                    // Manual cellular/WiFi refresh (useful in tunnels / poor GPS areas).
                    ControlTile(title: "Refresh net", symbol: "antenna.radiowaves.left.and.right",
                                tint: .blue) {
                        print("⌚ 🔘 Refresh Net button tapped by user")
                        workoutSession.refreshCellularFallback()
                    }
                }
                Button(role: .destructive) { showStopConfirmation = true } label: {
                    Label("End", systemImage: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.25), in: Capsule())
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
        }
    }

    private var detailsPage: some View {
        ScrollView {
            VStack(spacing: 8) {
                MetricsView(
                    metrics: displayMetrics,
                    nativeStepDistanceMeters: workoutSession.nativePedometerDistanceMeters
                )

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

                Group {
                    Text(workoutSession.networkDebugMessage)
                    Text(workoutSession.networkPathStatus)
                    Text("Native steps: \(workoutSession.nativePedometerStepCount) • native step distance: \(String(format: "%.2f", workoutSession.nativePedometerDistanceMeters / 1000.0))km")
                    Text("Pedometer freq: \(String(format: "%.2f", workoutSession.nativePedometerCallbackHz))Hz • native age: \(String(format: "%.1f", workoutSession.nativePedometerCallbackAgeSeconds))s • query age: \(String(format: "%.1f", workoutSession.nativePedometerQueryAgeSeconds))s")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 2)
        }
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
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

// MARK: - Live page pieces

/// One figure under the big speed: value, unit and a small label.
private struct LiveFigure: View {
    let value: String
    let unit: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A square control on the controls page.
private struct ControlTile: View {
    let title: String
    let symbol: String
    let tint: Color
    var caption: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let caption {
                    Text(caption)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(RoundedRectangle(cornerRadius: 14).fill(tint.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }
}

/// The route so far and where it ends, following the newest point. It takes no touches: on a
/// page that is swiped through, a map that pans swallows the swipe and traps the user on it.
private struct LiveRouteMap: View {
    let locations: [FlightLocation]
    let gpsLocation: CLLocation?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        let route = locations.suffix(600).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let here = route.last ?? gpsLocation?.coordinate
        Map(position: $position, interactionModes: []) {
            if route.count > 1 {
                MapPolyline(coordinates: route).stroke(.green, lineWidth: 4)
            }
            if let here {
                Annotation("", coordinate: here) {
                    Circle().fill(.blue).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .onChange(of: here?.latitude) { _, _ in
            guard let here else { return }
            withAnimation { position = .camera(MapCamera(centerCoordinate: here, distance: 900)) }
        }
        .onAppear {
            if let here { position = .camera(MapCamera(centerCoordinate: here, distance: 900)) }
        }
        .accessibilityLabel("Map of the route so far")
    }
}
