import SwiftUI
import CoreLocation
import HealthKit

enum TestCategory: String, CaseIterable {
    case permissions = "Permissions"
    case gps = "GPS"
    case healthKit = "HealthKit"
    case performance = "Performance"
    case debug = "Debug"
}

struct PermissionTestView: View {
    @StateObject private var locationManager = LocationManager()
    @ObservedObject private var healthKitManager = HealthKitManager.shared

    @State private var selectedCategory: TestCategory = .permissions
    @State private var locationStatus = "Not checked"
    @State private var healthKitStatus = "Not checked"
    @State private var testResults: [String] = []
    @State private var didRunHealthKitWriteTest = false
    @State private var healthKitWriteTestStatus: String?

    // GPS Testing
    @State private var gpsUpdateCount = 0
    @State private var lastGPSUpdate: Date?
    @State private var averageAccuracy: Double = 0
    @State private var isMonitoringGPS = false

    // Performance metrics
    @State private var memoryUsage: String = "..."
    @State private var cpuUsage: String = "..."

    // Debug workout generation
    @State private var debugStepCountText = ""
    @State private var isSavingDebugWorkout = false
    @State private var isDeletingDebugWorkout = false
    @State private var debugWorkoutStatus: String?
    @FocusState private var isDebugStepCountFieldFocused: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                mainContent
                    .navigationTitle("Testing & Debug")
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                NavigationStack {
                    mainContent
                        .navigationTitle("Testing & Debug")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .onAppear {
            checkPermissions()
            startPerformanceMonitoring()
            runHealthKitWriteTestOnce()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
                // Gradient background
                LinearGradient(
                    colors: [
                        Color.orange.opacity(0.05),
                        Color.yellow.opacity(0.02),
                        Color(.systemGroupedBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Category Picker
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(TestCategory.allCases, id: \.self) { category in
                                CategoryChip(
                                    title: category.rawValue,
                                    icon: categoryIcon(category),
                                    isSelected: selectedCategory == category,
                                    action: { selectedCategory = category }
                                )
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                    }
                    .background(Color(.systemBackground).opacity(0.95))

                    // Content
                    ScrollView {
                        VStack(spacing: 20) {
                            switch selectedCategory {
                            case .permissions:
                                permissionsSection
                            case .gps:
                                gpsTestingSection
                            case .healthKit:
                                healthKitTestingSection
                            case .performance:
                                performanceSection
                            case .debug:
                                debugSection
                            }
                        }
                        .padding()
                    }
                }
            }
        }


    // MARK: - Category Icon Helper

    private func categoryIcon(_ category: TestCategory) -> String {
        switch category {
        case .permissions: return "checkmark.shield.fill"
        case .gps: return "location.fill"
        case .healthKit: return "heart.fill"
        case .performance: return "speedometer"
        case .debug: return "ladybug.fill"
        }
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        VStack(spacing: 16) {
            // Status Cards
            VStack(spacing: 12) {
                TestStatusCard(
                    icon: "location.fill",
                    title: "Location Services",
                    status: locationStatus,
                    color: statusColor(locationStatus)
                )

                TestStatusCard(
                    icon: "heart.fill",
                    title: "HealthKit",
                    status: healthKitStatus,
                    color: statusColor(healthKitStatus)
                )
            }

            // Test Actions
            VStack(alignment: .leading, spacing: 8) {
                Text("Test Actions")
                    .font(.headline)
                    .padding(.top)

                Button(action: checkPermissions) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("Check Current Permissions")
                        Spacer()
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: requestLocationPermission) {
                    HStack {
                        Image(systemName: "location.fill")
                        Text("REQUEST Location Permission")
                        Spacer()
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: requestHealthKitPermission) {
                    HStack {
                        Image(systemName: "heart.fill")
                        Text("REQUEST HealthKit Permission")
                        Spacer()
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(.red)
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: requestBothPermissions) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Request BOTH")
                        Spacer()
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .foregroundColor(.green)
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Test Log
            VStack(alignment: .leading, spacing: 8) {
                Text("Test Log")
                    .font(.headline)
                    .padding(.top)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(testResults.indices, id: \.self) { index in
                        Text(testResults[index])
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(10)
            }

            // Instructions
            VStack(alignment: .leading, spacing: 8) {
                Text("Instructions")
                    .font(.headline)
                    .padding(.top)

                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Tap 'REQUEST Location Permission'")
                    Text("   → iOS dialog should appear")
                    Text("2. Grant permission")
                    Text("3. Go to Settings → Privacy → Location")
                    Text("   → App should now appear with options")
                    Text("")
                    Text("4. Tap 'REQUEST HealthKit Permission'")
                    Text("   → iOS dialog should appear")
                    Text("5. Grant permission")
                    Text("6. Go to Settings → Privacy → Health")
                    Text("   → App should now appear")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(10)
            }
        }
    }

    // MARK: - GPS Testing Section

    private var gpsTestingSection: some View {
        VStack(spacing: 16) {
            TestStatusCard(
                icon: "location.circle.fill",
                title: "GPS Status",
                status: isMonitoringGPS ? "Monitoring" : "Idle",
                color: isMonitoringGPS ? .green : .orange
            )

            VStack(spacing: 12) {
                HStack {
                    Text("Updates Received:")
                    Spacer()
                    Text("\(gpsUpdateCount)")
                        .fontWeight(.bold)
                }

                HStack {
                    Text("Average Accuracy:")
                    Spacer()
                    Text(String(format: "%.1fm", averageAccuracy))
                        .fontWeight(.bold)
                }

                if let lastUpdate = lastGPSUpdate {
                    HStack {
                        Text("Last Update:")
                        Spacer()
                        Text(lastUpdate, style: .time)
                            .fontWeight(.bold)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(10)

            Button(action: {
                isMonitoringGPS.toggle()
                if isMonitoringGPS {
                    startGPSMonitoring()
                } else {
                    stopGPSMonitoring()
                }
            }) {
                HStack {
                    Image(systemName: isMonitoringGPS ? "stop.fill" : "play.fill")
                    Text(isMonitoringGPS ? "Stop GPS Monitoring" : "Start GPS Monitoring")
                    Spacer()
                }
                .padding()
                .background(isMonitoringGPS ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                .foregroundColor(isMonitoringGPS ? .red : .green)
                .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - HealthKit Testing Section

    private var healthKitTestingSection: some View {
        VStack(spacing: 16) {
            TestStatusCard(
                icon: "heart.text.square.fill",
                title: "HealthKit Authorization",
                status: healthKitStatus,
                color: statusColor(healthKitStatus)
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("HealthKit Capabilities")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: HKHealthStore.isHealthDataAvailable() ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(HKHealthStore.isHealthDataAvailable() ? .green : .red)
                        Text("Health Data Available")
                    }

                    HStack {
                        Image(systemName: healthKitManager.isAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(healthKitManager.isAuthorized ? .green : .red)
                        Text("Workout Authorization")
                    }
                }
                .font(.subheadline)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(10)
            }
        }
    }

    // MARK: - Performance Section

    private var performanceSection: some View {
        VStack(spacing: 16) {
            Text("Performance Metrics")
                .font(.headline)

            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "memorychip")
                    Text("Memory Usage:")
                    Spacer()
                    Text(memoryUsage)
                        .fontWeight(.bold)
                }

                HStack {
                    Image(systemName: "cpu")
                    Text("CPU Usage:")
                    Spacer()
                    Text(cpuUsage)
                        .fontWeight(.bold)
                }

                HStack {
                    Image(systemName: "location.fill")
                    Text("GPS Updates:")
                    Spacer()
                    Text("\(gpsUpdateCount)")
                        .fontWeight(.bold)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(10)

            Text("Performance metrics updated every 5 seconds")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Debug Section

    private var debugSection: some View {
        VStack(spacing: 16) {
            Text("Debug Information")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                DebugInfoRow(label: "Location Manager", value: "\(type(of: locationManager))")
                DebugInfoRow(label: "HealthKit Manager", value: "\(type(of: healthKitManager))")
                DebugInfoRow(label: "Workout Session", value: "\(type(of: WorkoutSession.shared))")
                DebugInfoRow(label: "GPS Signal", value: "\(locationManager.gpsSignalQuality)")
                DebugInfoRow(label: "Tracking Active", value: "\(locationManager.isTracking)")
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(10)

            VStack(alignment: .leading, spacing: 12) {
                Text("Step-Only Debug Workout")
                    .font(.headline)

                Text("Creates a HealthKit workout with only the step count you enter. No distance samples or GPS route are written, and the workout starts at the moment you press Generate.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("Enter steps", text: $debugStepCountText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($isDebugStepCountFieldFocused)

                Text("No app-side step cap is applied. Enter any whole-number step count you want to test.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button(action: generateStepOnlyDebugWorkout) {
                    HStack {
                        if isSavingDebugWorkout {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Image(systemName: "figure.walk")
                        }
                        Text(isSavingDebugWorkout ? "Generating..." : "Generate Step-Only Debug Workout")
                        Spacer()
                    }
                    .padding()
                    .background(
                        (isSavingDebugWorkout || isDeletingDebugWorkout || parsedDebugStepCount == nil)
                            ? Color.gray.opacity(0.12)
                            : Color.green.opacity(0.12)
                    )
                    .foregroundColor(
                        (isSavingDebugWorkout || isDeletingDebugWorkout || parsedDebugStepCount == nil)
                            ? .secondary
                            : .green
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSavingDebugWorkout || isDeletingDebugWorkout || parsedDebugStepCount == nil)

                Button(action: deleteStepOnlyDebugWorkouts) {
                    HStack {
                        if isDeletingDebugWorkout {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Image(systemName: "trash")
                        }
                        Text(isDeletingDebugWorkout ? "Deleting..." : "Delete Step-Only Debug Data")
                        Spacer()
                    }
                    .padding()
                    .background(
                        (isSavingDebugWorkout || isDeletingDebugWorkout)
                            ? Color.gray.opacity(0.12)
                            : Color.red.opacity(0.12)
                    )
                    .foregroundColor(
                        (isSavingDebugWorkout || isDeletingDebugWorkout)
                            ? .secondary
                            : .red
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isSavingDebugWorkout || isDeletingDebugWorkout)

                if let debugWorkoutStatus {
                    Text(debugWorkoutStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(10)

            Button(action: {
                if let folderURL = WorkoutCacheStore.shared.ensureVisibleFolder() {
                    addLog("📁 Cache folder ready: \(folderURL.lastPathComponent)")
                } else {
                    addLog("❌ Failed to create cache folder")
                }
            }) {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("Create Files Cache Folder")
                    Spacer()
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                testFilesContainer()
            }) {
                HStack {
                    Image(systemName: "folder")
                    Text("Check Files App Folder")
                    Spacer()
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                testResults.removeAll()
                addLog("🧹 Debug log cleared")
            }) {
                HStack {
                    Image(systemName: "trash")
                    Text("Clear Debug Log")
                    Spacer()
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .foregroundColor(.red)
                .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
        }
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
