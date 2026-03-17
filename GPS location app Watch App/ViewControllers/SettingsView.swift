import SwiftUI

struct SettingsView: View {
    @AppStorage("distanceUnit") private var distanceUnit = "km"
    @AppStorage("speedUnit") private var speedUnit = "km/h"
    @AppStorage("altitudeUnit") private var altitudeUnit = "meters"
    @AppStorage("mapStyle") private var mapStyle = "standard"
    @AppStorage("kalmanSensitivity") private var kalmanSensitivity = "medium"
    @AppStorage("healthKitExportType") private var healthKitExportType = "auto"

    @State private var locationPermissionStatus = "Not Determined"
    @State private var healthKitPermissionStatus = "Not Determined"

    var body: some View {
        NavigationView {
            Form {
                // Permissions Section
                Section(header: Text("Permissions")) {
                    HStack {
                        Label("Location Services", systemImage: "location.fill")
                        Spacer()
                        Text(locationPermissionStatus)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("HealthKit", systemImage: "heart.fill")
                        Spacer()
                        Text(healthKitPermissionStatus)
                            .foregroundColor(.secondary)
                    }

                    // Note: Opening settings is not directly available on watchOS
                    Text("Manage permissions in iPhone app")
                        .font(.caption)
                        .foregroundColor(.secondary)
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

                // Map Settings Section
                Section(header: Text("Map Settings")) {
                    Picker("Map Style", selection: $mapStyle) {
                        Text("Standard").tag("standard")
                        Text("Satellite").tag("satellite")
                        Text("Hybrid").tag("hybrid")
                    }
                }

                // Advanced Settings Section
                Section(header: Text("Advanced"),
                       footer: Text("Higher sensitivity provides smoother tracking but may introduce slight lag")) {
                    Picker("Kalman Filter Sensitivity", selection: $kalmanSensitivity) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                }

                // Workout Configuration Section
                Section(header: Text("Workout Configuration")) {
                    Toggle("Auto-save to HealthKit", isOn: .constant(true))
                    Toggle("Track Heart Rate", isOn: .constant(false))
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
                Section(header: Text("Flight Tracking Tips")) {
                    VStack(alignment: .leading, spacing: 12) {
                        TipRow(
                            icon: "airplane.departure",
                            text: "Request a window seat for better GPS reception"
                        )

                        TipRow(
                            icon: "antenna.radiowaves.left.and.right",
                            text: "Keep GPS enabled even in Airplane Mode"
                        )

                        TipRow(
                            icon: "battery.100",
                            text: "Ensure your device is fully charged before flight"
                        )

                        TipRow(
                            icon: "wifi",
                            text: "Airplane WiFi can improve GPS accuracy"
                        )
                    }
                    .padding(.vertical, 8)
                }

                // About Section
                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com")!) {
                        HStack {
                            Text("GitHub")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
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
