import SwiftUI
import CoreLocation
import HealthKit

/// REBUILT AS A NATIVE GROUPED FORM.
///
/// This was hand-drawn: stacks of VStacks, each row wrapped in its own rounded rectangle with
/// hand-set padding. It looked approximately like a settings screen without being one, so it
/// missed everything the real control gives you for free — correct row heights and separators,
/// section footers that explain a setting instead of floating captions, Dynamic Type, and the
/// press states people expect. A Form is both less code and more familiar.
struct SettingsView: View {
    /// Developer screen unlock, persisted so it does not have to be rediscovered.
    @AppStorage("developerUnlocked") private var developerUnlocked = false
    @State private var versionTapCount = 0
    @State private var versionTapHint: String?
    @State private var lastVersionTap = Date.distantPast
    private let tapsToUnlock = 5

    @AppStorage("distanceUnit") private var distanceUnit = "km"
    @AppStorage("speedUnit") private var speedUnit = "km/h"
    @AppStorage("altitudeUnit") private var altitudeUnit = "meters"
    @AppStorage("mapStyle") private var mapStyle = "standard"
    @AppStorage("kalmanSensitivity") private var kalmanSensitivity = "medium"
    @AppStorage("autoSaveToHealthKit") private var autoSaveToHealthKit = true
    @AppStorage("trackHeartRate") private var trackHeartRate = true
    @AppStorage("useRawGPS") private var useRawGPS = false
    @AppStorage("healthKitExportType") private var healthKitExportType = "auto"
    @AppStorage("mapMatchingAPIKey") private var mapMatchingAPIKey = ""

    @StateObject private var locationManager = LocationManager()
    @ObservedObject private var healthKitManager = HealthKitManager.shared

    @State private var locationPermissionStatus = "Not Determined"
    @State private var healthKitPermissionStatus = "Not Determined"

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        navigationWrapper {
            Form {
                permissionsSection
                unitsSection
                mapSection
                workoutSection
                roadAlignmentSection
                aboutSection
            }
            .onAppear(perform: updatePermissionStatus)
        }
    }

    // MARK: - Sections

    private var permissionsSection: some View {
        Section {
            permissionRow(icon: "location.fill", tint: .blue,
                          title: "Location Services", status: locationPermissionStatus)
            permissionRow(icon: "heart.fill", tint: .red,
                          title: "HealthKit", status: healthKitPermissionStatus)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open iOS Settings", systemImage: "gear")
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Location must be set to Always for a workout to keep recording once the screen locks.")
        }
    }

    private var unitsSection: some View {
        Section("Units") {
            Picker("Distance", selection: $distanceUnit) {
                Text("Kilometres").tag("km")
                Text("Miles").tag("mi")
            }
            Picker("Speed", selection: $speedUnit) {
                Text("km/h").tag("km/h")
                Text("mph").tag("mph")
                Text("knots").tag("knots")
            }
            Picker("Altitude", selection: $altitudeUnit) {
                Text("Metres").tag("meters")
                Text("Feet").tag("feet")
            }
        }
    }

    private var mapSection: some View {
        Section {
            Picker("Map style", selection: $mapStyle) {
                Text("Standard").tag("standard")
                Text("Satellite").tag("satellite")
                Text("Hybrid").tag("hybrid")
            }
            Picker("Filtering", selection: $kalmanSensitivity) {
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
        } header: {
            Text("Map & tracking")
        } footer: {
            Text("Filtering smooths the recorded track. Higher settings reject more noise but can round off genuine sharp turns.")
        }
    }

    private var workoutSection: some View {
        Section {
            Toggle("Save to Apple Health", isOn: $autoSaveToHealthKit)
            Picker("Save as", selection: $healthKitExportType) {
                Text("Match activity").tag("auto")
                Text("Cycling").tag("cycling")
                Text("Running").tag("running")
                Text("Walking").tag("walking")
                Text("Hiking").tag("hiking")
            }
            Toggle("Record heart rate", isOn: $trackHeartRate)
            Toggle("Unfiltered GPS", isOn: $useRawGPS)
        } header: {
            Text("Workouts")
        } footer: {
            Text(useRawGPS
                 ? "Unfiltered: every fix is recorded exactly as reported, including inaccurate ones."
                 : "Fixes that contradict their own accuracy are discarded before they reach the track.")
        }
    }

    private var roadAlignmentSection: some View {
        Section {
            SecureField("Stadia Maps API key", text: $mapMatchingAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let url = URL(string: "https://client.stadiamaps.com") {
                Link(destination: url) {
                    Label("Get a free key", systemImage: "arrow.up.right.square")
                }
            }
        } header: {
            Text("Road alignment")
        } footer: {
            Text("Snaps a recorded track to real road geometry on the Map tab. Without a key the app falls back to Apple Maps snapping, which is rougher.")
        }
    }

    private var aboutSection: some View {
        Section {
            // THE REAL VERSION, NOT A LITERAL.
            //
            // This read "1.0.0" while the app was on build 134. Every diagnosis in this project
            // starts with knowing which build produced a recording — one log was misread for a
            // whole exchange because the build was unknown — so a version string that cannot go
            // stale is worth more than it looks.
            //
            // Five taps opens the developer screen, the way Android does it: out of the way for
            // normal use, reachable without a Mac when a recording needs rescuing.
            Button(action: registerVersionTap) {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.appVersionDisplay)
                        .foregroundColor(.secondary)
                    if developerUnlocked {
                        Image(systemName: "hammer.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if developerUnlocked {
                NavigationLink {
                    DeveloperView()
                } label: {
                    Label("Developer", systemImage: "hammer")
                }
            }

            if let url = URL(string: "https://github.com") {
                Link(destination: url) {
                    Label("GitHub repository", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        } header: {
            Text("About")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let hint = versionTapHint {
                    Text(hint)
                        .foregroundColor(.accentColor)
                }
                Text("Road alignment uses map data © OpenStreetMap contributors under the ODbL, retrieved via the Overpass API. Maps © Apple.")
                if let url = URL(string: "https://www.openstreetmap.org/copyright") {
                    Link("OpenStreetMap copyright", destination: url)
                }
            }
        }
    }

    private func permissionRow(icon: String, tint: Color, title: String, status: String) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundColor(tint)
            }
            Spacer()
            Text(status)
                .font(.footnote)
                .foregroundColor(permissionColor(status))
        }
    }

    private func registerVersionTap() {
        let now = Date()
        if now.timeIntervalSince(lastVersionTap) > 2.0 { versionTapCount = 0 }
        lastVersionTap = now

        guard !developerUnlocked else {
            versionTapHint = "Developer options are already on."
            clearHintSoon()
            return
        }

        versionTapCount += 1
        let remaining = tapsToUnlock - versionTapCount
        if remaining <= 0 {
            developerUnlocked = true
            versionTapCount = 0
            versionTapHint = "Developer options are on."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else if remaining <= 3 {
            versionTapHint = remaining == 1
                ? "1 more tap and you are a developer."
                : "\(remaining) more taps and you are a developer."
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        clearHintSoon()
    }

    private func clearHintSoon() {
        let shownFor = versionTapHint
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if versionTapHint == shownFor { withAnimation { versionTapHint = nil } }
        }
    }

    @ViewBuilder
    private func navigationWrapper<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if horizontalSizeClass == .regular {
            content()
                .navigationTitle("Settings")
        } else {
            NavigationStack {
                content()
                    .navigationTitle("Settings")
            }
        }
    }

    // MARK: - Permission Helpers

    private func updatePermissionStatus() {
        // Update Location Permission Status
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationPermissionStatus = "Not Determined"
        case .restricted:
            locationPermissionStatus = "Restricted"
        case .denied:
            locationPermissionStatus = "Denied"
        case .authorizedAlways:
            locationPermissionStatus = "Always"
        case .authorizedWhenInUse:
            locationPermissionStatus = "When In Use"
        @unknown default:
            locationPermissionStatus = "Unknown"
        }

        // Update HealthKit Permission Status
        // Check current authorization status without requesting permission
        healthKitManager.checkAuthorizationStatus()
        healthKitPermissionStatus = healthKitManager.isAuthorized ? "Authorized" : "Not Authorized"
    }


    private func permissionColor(_ status: String) -> Color {
        switch status {
        case "Authorized", "Always":
            return .green
        case "When In Use":
            return .orange
        case "Denied", "Restricted", "Not Authorized":
            return .red
        default:
            return .secondary
        }
    }
}

// MARK: - Permission Card Component

struct PermissionCard: View {
    let icon: String
    let title: String
    let status: String
    let color: Color
    let iconColor: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(iconColor)
                .frame(width: 40, height: 40)
                .background(iconColor.opacity(0.1))
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

            Image(systemName: color == .green ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(color)
                .font(.title3)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - Setting Row Component

struct SettingRow<Content: View>: View {
    let icon: String
    let title: String
    let color: Color
    let content: Content

    init(icon: String, title: String, color: Color, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.color = color
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)

            Text(title)
                .font(.subheadline)

            Spacer()

            content
        }
        .padding()
    }
}

// MARK: - Tip Row Component

struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)
                .font(.body)

            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
