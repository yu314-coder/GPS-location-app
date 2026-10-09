import SwiftUI
import WatchKit

struct SettingsView: View {
    @AppStorage("distanceUnit") private var distanceUnit = "km"
    @AppStorage("speedUnit") private var speedUnit = "km/h"
    @AppStorage("altitudeUnit") private var altitudeUnit = "meters"
    @AppStorage("mapStyle") private var mapStyle = "standard"
    @AppStorage("kalmanSensitivity") private var kalmanSensitivity = "medium"
    @AppStorage("healthKitExportType") private var healthKitExportType = "auto"
    @AppStorage(WatchSpeedEngine.defaultsKey) private var speedEngine = WatchSpeedEngine.auto.rawValue
    // Hidden options, as on the iPhone: five taps on the version turn them on.
    @AppStorage(WatchSpeedEngine.developerKey) private var developerUnlocked = false
    @State private var versionTapCount = 0
    @State private var lastVersionTap = Date.distantPast
    @State private var versionTapHint: String?
    private let tapsToUnlock = 5

    @StateObject private var permissions = PermissionStatusModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            Form {
                // Permissions, as the system reports them now.
                Section(header: Text("Permissions"),
                        footer: Text("To change one, open Settings on the watch, then Privacy & Security.")) {
                    PermissionRow(title: "Location", symbol: "location.fill", state: permissions.location)
                    PermissionRow(title: "Health", symbol: "heart.fill", state: permissions.health)
                    PermissionRow(title: "Motion & Fitness", symbol: "figure.walk.motion", state: permissions.motion)
                    if permissions.anyNotAsked {
                        Button {
                            permissions.requestMissing()
                        } label: {
                            Label("Ask for access", systemImage: "hand.raised.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.orange)
                    }
                }

                // Display Units Section
                Section(header: Text("Display Units")) {
                    Picker("Distance", selection: $distanceUnit) {
                        Text("Kilometers").tag("km")
                        Text("Miles").tag("mi")
                    }

                    Picker("Speed", selection: $speedUnit) {
                        Text("km/h").tag("km/h")
                        Text("mph").tag("mph")
                        Text("knots").tag("knots")
                    }

                    Picker("Altitude", selection: $altitudeUnit) {
                        Text("Meters").tag("meters")
                        Text("Feet").tag("feet")
                    }
                }

                // Speed engines (build 82): which run and are recorded in Velocity Mode.
                Section(header: Text("Speed engines"),
                        footer: Text(SpeedEngineChoiceView.explanation(WatchSpeedEngine(rawValue: speedEngine) ?? .auto))) {
                    Picker("Run and record", selection: $speedEngine) {
                        ForEach(WatchSpeedEngine.allCases, id: \.rawValue) { engine in
                            Text(engine.title).tag(engine.rawValue)
                        }
                    }
                }

                // Map Settings Section
                Section(header: Text("Map Settings")) {
                    Picker("Map Style", selection: $mapStyle) {
                        Text("Standard").tag("standard")
                        Text("Satellite").tag("satellite")
                        Text("Hybrid").tag("hybrid")
                    }
                }

                // Fitness Export Type
                Section(header: Text("Fitness Export Type")) {
                    Picker("Export As", selection: $healthKitExportType) {
                        Text("Auto").tag("auto")
                        Text("Cycling").tag("cycling")
                        Text("Running").tag("running")
                        Text("Walking").tag("walking")
                        Text("Hiking").tag("hiking")
                    }
                }

                // Tips Section
                Section(header: Text("Workout Tracking Tips")) {
                    VStack(alignment: .leading, spacing: 12) {
                        TipRow(
                            icon: "location.fill",
                            text: "Start outdoors or near a clear sky for better GPS reception"
                        )

                        TipRow(
                            icon: "antenna.radiowaves.left.and.right",
                            text: "Keep GPS enabled even in Airplane Mode"
                        )

                        TipRow(
                            icon: "battery.100",
                            text: "Ensure your device is fully charged before long workouts"
                        )

                        TipRow(
                            icon: "wifi",
                            text: "Wi-Fi and cellular can improve GPS accuracy"
                        )
                    }
                    .padding(.vertical, 8)
                }

                WatchLogsSection()

                // About Section
                Section(header: Text("About"), footer: Group {
                    if let versionTapHint { Text(versionTapHint).foregroundColor(.accentColor) }
                }) {
                    Button(action: registerVersionTap) {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text(Self.versionText)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    Link(destination: URL(string: "https://github.com/yu314-coder")!) {
                        HStack {
                            Text("GitHub")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                        }
                    }
                }

                if developerUnlocked {
                    developerSection
                }
            }
            .navigationTitle("Settings")
            .onAppear { permissions.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { permissions.refresh() }
            }
        }
    }
}

extension SettingsView {
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Testing options, hidden until the version is tapped five times.
    @ViewBuilder var developerSection: some View {
        Section(header: Text("Developer: tracking"),
                footer: Text("Higher sensitivity provides smoother tracking but may introduce slight lag")) {
            Picker("Kalman Filter Sensitivity", selection: $kalmanSensitivity) {
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
            Toggle("Auto-save to HealthKit", isOn: .constant(true))
            Toggle("Track Heart Rate", isOn: .constant(false))
        }
        Section {
            Button("Turn off developer options") {
                developerUnlocked = false
                versionTapHint = nil
            }
            .foregroundColor(.red)
        }
    }

    func registerVersionTap() {
        let now = Date()
        if now.timeIntervalSince(lastVersionTap) > 2.0 { versionTapCount = 0 }
        lastVersionTap = now
        guard !developerUnlocked else {
            versionTapHint = "Developer options are already on."
            return
        }
        versionTapCount += 1
        let remaining = tapsToUnlock - versionTapCount
        if remaining <= 0 {
            developerUnlocked = true
            versionTapCount = 0
            versionTapHint = "Developer options are on."
            WKInterfaceDevice.current().play(.success)
        } else if remaining <= 3 {
            versionTapHint = remaining == 1 ? "1 more tap." : "\(remaining) more taps."
            WKInterfaceDevice.current().play(.click)
        }
    }
}

struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
