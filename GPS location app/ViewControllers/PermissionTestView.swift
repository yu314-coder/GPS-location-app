import SwiftUI
import CoreLocation
import HealthKit

/// REBUILT AS A GROUPED LIST.
///
/// This was a segmented control over five hand-laid pages, so finding anything meant first
/// guessing which of "Permissions / GPS / HealthKit / Performance / Debug" it lived under, and
/// each page drew its rows its own way. A diagnostics screen is read, not navigated: the point
/// is to see the state of everything at once and notice the one thing that is wrong. Sections in
/// a single scroll do that; tabs hide four fifths of it behind a guess.
///
/// Same actions, same functions underneath — only the arrangement changed, and it now shares the
/// icon and status vocabulary with Settings and Developer.
struct PermissionTestView: View {
    @StateObject private var locationManager = LocationManager()
    @ObservedObject private var healthKitManager = HealthKitManager.shared

    @State private var locationStatus = "Not checked"
    @State private var healthKitStatus = "Not checked"
    @State private var testResults: [String] = []
    @State private var didRunHealthKitWriteTest = false
    @State private var healthKitWriteTestStatus: String?

    @State private var gpsUpdateCount = 0
    @State private var lastGPSUpdate: Date?
    @State private var averageAccuracy: Double = 0
    @State private var isMonitoringGPS = false

    @State private var memoryUsage: String = "..."
    @State private var cpuUsage: String = "..."

    @State private var debugStepCountText = ""
    @State private var isSavingDebugWorkout = false
    @State private var isDeletingDebugWorkout = false
    @State private var debugWorkoutStatus: String?
    @FocusState private var isDebugStepCountFieldFocused: Bool

    var body: some View {
        List {
            Section {
                SettingsRow(symbol: "location.fill", tint: .blue, title: "Location") {
                    StatusPill(text: locationStatus, tint: statusColor(locationStatus))
                }
                SettingsRow(symbol: "heart.fill", tint: .red, title: "Apple Health") {
                    StatusPill(text: healthKitStatus, tint: statusColor(healthKitStatus))
                }
                Button { checkPermissions() } label: {
                    SettingsRow(symbol: "arrow.clockwise", tint: .gray, title: "Re-check now")
                }
                .buttonStyle(.plain)
                Button { requestLocationPermission() } label: {
                    SettingsRow(symbol: "location.circle.fill", tint: .blue,
                                title: "Request location access")
                }
                .buttonStyle(.plain)
                Button { requestHealthKitPermission() } label: {
                    SettingsRow(symbol: "heart.circle.fill", tint: .red,
                                title: "Request Health access")
                }
                .buttonStyle(.plain)
            } header: {
                Text("Permissions")
            } footer: {
                Text("Location must be Always for recording to continue once the screen locks. Health access is per-type and cannot be re-prompted once denied — that needs iOS Settings.")
            }

            Section {
                SettingsRow(symbol: "dot.radiowaves.left.and.right", tint: .green, title: "Fixes received") {
                    Text("\(gpsUpdateCount)").font(.system(.body, design: .monospaced))
                }
                SettingsRow(symbol: "scope", tint: .teal, title: "Mean accuracy") {
                    Text(averageAccuracy > 0 ? String(format: "%.0f m", averageAccuracy) : "—")
                        .font(.system(.body, design: .monospaced))
                }
                if let last = lastGPSUpdate {
                    SettingsRow(symbol: "clock", tint: .gray, title: "Last fix") {
                        Text(last, style: .relative).font(.footnote).foregroundColor(.secondary)
                    }
                }
                Button {
                    isMonitoringGPS ? stopGPSMonitoring() : startGPSMonitoring()
                } label: {
                    SettingsRow(symbol: isMonitoringGPS ? "stop.fill" : "play.fill",
                                tint: isMonitoringGPS ? .red : .green,
                                title: isMonitoringGPS ? "Stop monitoring" : "Start monitoring")
                }
                .buttonStyle(.plain)
            } header: {
                Text("GPS")
            } footer: {
                Text("Monitoring counts fixes as they arrive, without recording a workout. Useful for judging signal somewhere before relying on it.")
            }

            Section {
                SettingsRow(symbol: "memorychip", tint: .indigo, title: "Memory") {
                    Text(memoryUsage).font(.system(.body, design: .monospaced))
                }
                SettingsRow(symbol: "cpu", tint: .orange, title: "CPU") {
                    Text(cpuUsage).font(.system(.body, design: .monospaced))
                }
                Button { testFilesContainer() } label: {
                    SettingsRow(symbol: "folder.fill", tint: .brown, title: "Test file container")
                }
                .buttonStyle(.plain)
            } header: {
                Text("Performance")
            }

            Section {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: "figure.walk.motion", tint: .mint)
                    TextField("Step count", text: $debugStepCountText)
                        .keyboardType(.numberPad)
                        .focused($isDebugStepCountFieldFocused)
                }
                Button { generateStepOnlyDebugWorkout() } label: {
                    SettingsRow(symbol: "plus.circle.fill", tint: .mint,
                                title: isSavingDebugWorkout ? "Saving…" : "Create step-only workout")
                }
                .buttonStyle(.plain)
                .disabled(isSavingDebugWorkout)
                Button(role: .destructive) { deleteStepOnlyDebugWorkouts() } label: {
                    SettingsRow(symbol: "trash.fill", tint: .red,
                                title: isDeletingDebugWorkout ? "Deleting…" : "Delete step-only workouts")
                }
                .buttonStyle(.plain)
                .disabled(isDeletingDebugWorkout)
                if let status = debugWorkoutStatus {
                    Text(status).font(.footnote).foregroundColor(.secondary)
                }
            } header: {
                Text("HealthKit debug")
            } footer: {
                Text("Writes a workout carrying only a step count, to check how Health and other apps treat one with no route.")
            }

            Section {
                if testResults.isEmpty {
                    Text("Nothing logged yet.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(testResults.reversed(), id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("Log")
                    Spacer()
                    if !testResults.isEmpty {
                        Button("Clear") { testResults.removeAll() }
                            .font(.caption)
                            .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            checkPermissions()
            startPerformanceMonitoring()
        }
        .onDisappear { stopGPSMonitoring() }
    }

    // MARK: - Helper Functions

    private func checkPermissions() {
        addLog("🔍 Checking permissions...")

        let status = locationManager.authorizationStatus
        let statusText: String

        switch status {
        case .notDetermined:
            statusText = "Not Determined (0)"
        case .restricted:
            statusText = "Restricted (1)"
        case .denied:
            statusText = "Denied (2)"
        case .authorizedWhenInUse:
            statusText = "When In Use (3)"
        case .authorizedAlways:
            statusText = "Always (4)"
        @unknown default:
            statusText = "Unknown"
        }

        locationStatus = statusText
        healthKitManager.checkAuthorizationStatus()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let baseStatus = self.healthKitManager.isAuthorized ? "Authorized ✓" : "Not Authorized"
            if let testStatus = self.healthKitWriteTestStatus {
                self.healthKitStatus = "\(baseStatus) (\(testStatus))"
            } else {
                self.healthKitStatus = baseStatus
            }
            self.addLog("❤️ HealthKit: \(self.healthKitManager.isAuthorized ? "Authorized" : "Not Authorized")")
        }

        addLog("📍 Location: \(statusText)")
    }

    private func requestLocationPermission() {
        addLog("📍 REQUESTING Location Permission...")
        addLog("   Calling requestAuthorization()...")

        let currentStatus = locationManager.authorizationStatus
        addLog("   Current status: \(currentStatus.rawValue)")

        // Force request
        locationManager.requestAuthorization()

        addLog("   ✓ Request sent - watch for iOS dialog!")

        // Check again after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            checkPermissions()
            addLog("   Re-checked permissions")
        }
    }

    private func requestHealthKitPermission() {
        addLog("❤️ REQUESTING HealthKit Permission...")

        // Check if HealthKit is available
        if !HKHealthStore.isHealthDataAvailable() {
            addLog("   ❌ ERROR: HealthKit not available on this device!")
            healthKitStatus = "Not Available"
            return
        }

        addLog("   ✓ HealthKit is available")
        addLog("   Calling requestAuthorization()...")

        healthKitManager.requestAuthorization { success, error in
            if let error = error {
                addLog("   ❌ ERROR: \(error.localizedDescription)")
                healthKitStatus = "Error"
            } else if success {
                addLog("   ✅ SUCCESS: HealthKit authorized!")
                healthKitStatus = "Authorized ✓"
            } else {
                addLog("   ⚠️ User denied HealthKit access")
                healthKitStatus = "Denied"
            }

            checkPermissions()
        }

        addLog("   ✓ Request sent - watch for iOS dialog!")
    }

    private func requestBothPermissions() {
        addLog("🔄 Requesting BOTH permissions...")
        requestLocationPermission()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            requestHealthKitPermission()
        }
    }

    private func runHealthKitWriteTestOnce() {
        guard !didRunHealthKitWriteTest else { return }
        didRunHealthKitWriteTest = true

        addLog("🧪 HealthKit write test: saving & deleting a tiny workout...")

        if !HKHealthStore.isHealthDataAvailable() {
            healthKitWriteTestStatus = "unavailable"
            addLog("❌ HealthKit not available on this device")
            checkPermissions()
            return
        }

        if healthKitManager.isAuthorized {
            healthKitManager.verifyHealthKitWriteAccess { success, message in
                if success {
                    self.healthKitWriteTestStatus = "write ok"
                    self.addLog("✅ HealthKit write test OK (saved + deleted)")
                } else {
                    self.healthKitWriteTestStatus = "write failed"
                    self.addLog("❌ HealthKit write test failed: \(message ?? "Unknown")")
                }
                self.checkPermissions()
            }
            return
        }

        healthKitWriteTestStatus = "authorizing"
        addLog("❤️ HealthKit not authorized yet - requesting permission for test...")
        healthKitManager.requestAuthorization { success, error in
            if success {
                self.addLog("✅ HealthKit authorized - running write test")
                self.healthKitManager.verifyHealthKitWriteAccess { success, message in
                    if success {
                        self.healthKitWriteTestStatus = "write ok"
                        self.addLog("✅ HealthKit write test OK (saved + deleted)")
                    } else {
                        self.healthKitWriteTestStatus = "write failed"
                        self.addLog("❌ HealthKit write test failed: \(message ?? "Unknown")")
                    }
                    self.checkPermissions()
                }
            } else {
                self.healthKitWriteTestStatus = "write failed"
                self.addLog("❌ HealthKit permission denied: \(error?.localizedDescription ?? "Unknown")")
                self.checkPermissions()
            }
        }
    }

    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        testResults.insert("[\(timestamp)] \(message)", at: 0)
        print(message)
    }

    private var parsedDebugStepCount: Double? {
        let trimmed = debugStepCountText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "_", with: "")

        guard !trimmed.isEmpty,
              let value = Double(trimmed),
              value.isFinite,
              value > 0,
              value.rounded(.towardZero) == value else {
            return nil
        }

        return value
    }

    private func generateStepOnlyDebugWorkout() {
        isDebugStepCountFieldFocused = false

        guard let stepCount = parsedDebugStepCount else {
            debugWorkoutStatus = "Enter a valid whole-number step count."
            addLog("❌ Step-only debug workout requires a valid whole-number step count")
            return
        }

        guard HKHealthStore.isHealthDataAvailable() else {
            debugWorkoutStatus = "HealthKit is not available on this device."
            addLog("❌ HealthKit is not available on this device")
            return
        }

        let pressedAt = Date()
        let formattedSteps = formatDebugStepCount(stepCount)
        let saveAction = {
            isSavingDebugWorkout = true
            debugWorkoutStatus = "Saving \(formattedSteps) steps..."
            addLog("🧪 Saving step-only debug workout: \(formattedSteps) steps, no distance")

            healthKitManager.saveStepOnlyDebugWorkout(stepsCount: stepCount, at: pressedAt) { success, error, workout in
                DispatchQueue.main.async {
                    isSavingDebugWorkout = false
                    let timeText = DateFormatter.localizedString(from: pressedAt, dateStyle: .medium, timeStyle: .medium)

                    if success {
                        debugWorkoutStatus = "Saved \(formattedSteps) steps at \(timeText)."
                        addLog("✅ Step-only debug workout saved: \(formattedSteps) steps @ \(timeText)")
                        if let workout {
                            addLog("   Workout UUID: \(workout.uuid.uuidString)")
                        }
                    } else {
                        let errorMessage = error?.localizedDescription ?? "Unknown error"
                        debugWorkoutStatus = "Save failed: \(errorMessage)"
                        addLog("❌ Step-only debug workout failed: \(errorMessage)")
                    }
                }
            }
        }

        if healthKitManager.isAuthorized {
            saveAction()
            return
        }

        debugWorkoutStatus = "Requesting HealthKit access..."
        addLog("❤️ Requesting HealthKit authorization for step-only debug workout")
        healthKitManager.requestAuthorization { success, error in
            if success {
                saveAction()
            } else {
                let errorMessage = error?.localizedDescription ?? "Authorization denied"
                debugWorkoutStatus = "Authorization failed: \(errorMessage)"
                addLog("❌ HealthKit authorization failed for debug workout: \(errorMessage)")
            }
        }
    }

    private func formatDebugStepCount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    private func deleteStepOnlyDebugWorkouts() {
        isDebugStepCountFieldFocused = false

        guard HKHealthStore.isHealthDataAvailable() else {
            debugWorkoutStatus = "HealthKit is not available on this device."
            addLog("❌ HealthKit is not available on this device")
            return
        }

        let deleteAction = {
            isDeletingDebugWorkout = true
            debugWorkoutStatus = "Deleting debug workouts and step samples..."
            addLog("🗑️ Deleting step-only debug workouts and tagged step samples")

            healthKitManager.deleteStepOnlyDebugEntries { deletedWorkouts, deletedStepSamples, error in
                DispatchQueue.main.async {
                    isDeletingDebugWorkout = false

                    if let error {
                        debugWorkoutStatus = "Delete failed: \(error.localizedDescription)"
                        addLog("❌ Failed to delete debug HealthKit data: \(error.localizedDescription)")
                        return
                    }

                    debugWorkoutStatus = "Deleted \(deletedWorkouts) workout(s) and \(deletedStepSamples) step sample(s)."
                    addLog("✅ Deleted \(deletedWorkouts) debug workout(s) and \(deletedStepSamples) step sample(s)")
                }
            }
        }

        if healthKitManager.isAuthorized {
            deleteAction()
            return
        }

        debugWorkoutStatus = "Requesting HealthKit access..."
        addLog("❤️ Requesting HealthKit authorization for debug cleanup")
        healthKitManager.requestAuthorization { success, error in
            if success {
                deleteAction()
            } else {
                let errorMessage = error?.localizedDescription ?? "Authorization denied"
                debugWorkoutStatus = "Authorization failed: \(errorMessage)"
                addLog("❌ HealthKit authorization failed for debug cleanup: \(errorMessage)")
            }
        }
    }

    private func testFilesContainer() {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            addLog("❌ Documents folder not available")
            return
        }

        let markerURL = documentsURL.appendingPathComponent("FILES_VISIBLE.txt")
        if !fileManager.fileExists(atPath: markerURL.path) {
            let contents = "Files visibility marker for GPS location app."
            do {
                try contents.data(using: .utf8)?.write(to: markerURL, options: .atomic)
                addLog("✅ Created Files marker in Documents")
            } catch {
                addLog("❌ Failed to create Files marker: \(error.localizedDescription)")
            }
        }

        let items = (try? fileManager.contentsOfDirectory(atPath: documentsURL.path)) ?? []
        addLog("📁 Documents: \(documentsURL.lastPathComponent)")
        addLog("📄 Items: \(items.joined(separator: ", "))")
    }

    private func statusColor(_ status: String) -> Color {
        if status.contains("✓") || status.contains("Always") || status.contains("When In Use") {
            return .green
        } else if status.contains("Denied") || status.contains("Error") {
            return .red
        } else if status.contains("Not") {
            return .orange
        }
        return .secondary
    }

    private func startGPSMonitoring() {
        addLog("📍 Starting GPS monitoring...")
        gpsUpdateCount = 0
        locationManager.onLocationUpdate = { location in
            gpsUpdateCount += 1
            lastGPSUpdate = Date()
            averageAccuracy = location.horizontalAccuracy
            addLog("GPS update #\(gpsUpdateCount): ±\(String(format: "%.1f", location.horizontalAccuracy))m")
        }
        locationManager.startTracking()
    }

    private func stopGPSMonitoring() {
        addLog("📍 Stopping GPS monitoring...")
        locationManager.stopTracking()
        locationManager.onLocationUpdate = nil
    }

    private func startPerformanceMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            updatePerformanceMetrics()
        }
    }

    private func updatePerformanceMetrics() {
        // Basic memory usage
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if kerr == KERN_SUCCESS {
            let usedMemory = Double(info.resident_size) / 1024.0 / 1024.0
            memoryUsage = String(format: "%.1f MB", usedMemory)
        } else {
            memoryUsage = "N/A"
        }

        cpuUsage = "N/A"
    }
}

// MARK: - Supporting Views

struct CategoryChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue : Color(.secondarySystemGroupedBackground))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(20)
        }
    }
}

struct TestStatusCard: View {
    let icon: String
    let title: String
    let status: String
    let color: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.1))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(status)
                    .font(.caption)
                    .foregroundColor(color)
            }

            Spacer()

            Image(systemName: color == .green ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(color)
                .font(.title3)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

struct DebugInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    PermissionTestView()
}
