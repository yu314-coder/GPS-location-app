import SwiftUI
import CoreLocation

struct SettingsView: View {
    @AppStorage("distanceUnit") private var distanceUnit = "km"
    @AppStorage("speedUnit") private var speedUnit = "km/h"
    @AppStorage("altitudeUnit") private var altitudeUnit = "meters"
    @AppStorage("mapStyle") private var mapStyle = "standard"
    @AppStorage("kalmanSensitivity") private var kalmanSensitivity = "medium"
    @AppStorage("autoSaveToHealthKit") private var autoSaveToHealthKit = true
    @AppStorage("trackHeartRate") private var trackHeartRate = true
    @AppStorage("useRawGPS") private var useRawGPS = false
    @AppStorage("healthKitExportType") private var healthKitExportType = "auto"

    @StateObject private var locationManager = LocationManager()
    @ObservedObject private var healthKitManager = HealthKitManager.shared
    @State private var locationPermissionStatus = "Not Determined"
    @State private var healthKitPermissionStatus = "Not Determined"

    // Timer to refresh permission status when view is active
    let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Permissions Section with Cards
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Permissions")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)

                        VStack(spacing: 12) {
                            PermissionCard(
                                icon: "location.fill",
                                title: "Location Services",
                                status: locationPermissionStatus,
                                color: permissionColor(locationPermissionStatus),
                                iconColor: .blue
                            )

                            PermissionCard(
                                icon: "heart.fill",
                                title: "HealthKit",
                                status: healthKitPermissionStatus,
                                color: permissionColor(healthKitPermissionStatus),
                                iconColor: .red
                            )
                        }
                        .padding(.horizontal)

                        #if !os(watchOS)
                        Button(action: {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }) {
                            HStack {
                                Image(systemName: "gear")
                                Text("Open iOS Settings")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                            }
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal)
                        #endif
                    }

                    // Display Units Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Display Units")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)

                        VStack(spacing: 0) {
                            SettingRow(icon: "map", title: "Distance", color: .green) {
                                Picker("Distance", selection: $distanceUnit) {
                                    Text("Kilometers").tag("km")
                                    Text("Miles").tag("mi")
                                }
                                .pickerStyle(.menu)
                            }

                            Divider().padding(.leading, 56)

                            SettingRow(icon: "speedometer", title: "Speed", color: .orange) {
                                Picker("Speed", selection: $speedUnit) {
                                    Text("km/h").tag("km/h")
                                    Text("mph").tag("mph")
                                    Text("knots").tag("knots")
                                }
                                .pickerStyle(.menu)
                            }

                            Divider().padding(.leading, 56)

                            SettingRow(icon: "mountain.2", title: "Altitude", color: .purple) {
                                Picker("Altitude", selection: $altitudeUnit) {
                                    Text("Meters").tag("meters")
                                    Text("Feet").tag("feet")
                                }
                                .pickerStyle(.menu)
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }

                    // Map & Tracking Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Map & Tracking")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)

                        VStack(spacing: 0) {
                            SettingRow(icon: "map.fill", title: "Map Style", color: .blue) {
                                Picker("Map Style", selection: $mapStyle) {
                                    Text("Standard").tag("standard")
                                    Text("Satellite").tag("satellite")
                                    Text("Hybrid").tag("hybrid")
                                }
                                .pickerStyle(.menu)
                            }

                            Divider().padding(.leading, 56)

                            SettingRow(icon: "waveform.path.ecg", title: "Kalman Filter", color: .cyan) {
                                Picker("Sensitivity", selection: $kalmanSensitivity) {
                                    Text("Low").tag("low")
                                    Text("Medium").tag("medium")
                                    Text("High").tag("high")
                                }
                                .pickerStyle(.menu)
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }

                    // Workout Configuration
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Workout Settings")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)

                        VStack(spacing: 0) {
                            SettingRow(icon: "heart.circle.fill", title: "Auto-save to HealthKit", color: .red) {
                                Toggle("", isOn: $autoSaveToHealthKit)
                                    .labelsHidden()
                            }

                            Divider().padding(.leading, 56)

                            SettingRow(icon: "figure.run", title: "Fitness Export Type", color: .blue) {
                                Picker("Fitness Export Type", selection: $healthKitExportType) {
                                    Text("Auto").tag("auto")
                                    Text("Cycling").tag("cycling")
                                    Text("Running").tag("running")
                                    Text("Walking").tag("walking")
                                    Text("Hiking").tag("hiking")
                                }
                                .pickerStyle(.menu)
                            }

                            Divider().padding(.leading, 56)

                            SettingRow(icon: "waveform.path.ecg.rectangle", title: "Track Heart Rate", color: .pink) {
                                Toggle("", isOn: $trackHeartRate)
                                    .labelsHidden()
                                    .disabled(!healthKitManager.isAuthorized)
                            }

                            Divider().padding(.leading, 56)

                            SettingRow(icon: "exclamationmark.triangle.fill", title: "Use Raw GPS", color: .orange) {
                                Toggle("", isOn: $useRawGPS)
                                    .labelsHidden()
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)

                        if useRawGPS {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.orange)
                                Text("GPS filtering disabled - may include inaccurate data")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 20)
                        }
                    }

                    // Tips Card
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "lightbulb.fill")
                                .foregroundColor(.yellow)
                                .font(.title2)
                            Text("Flight Tracking Tips")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            TipRow(icon: "airplane.departure", text: "Request a window seat for better GPS reception")
                            TipRow(icon: "antenna.radiowaves.left.and.right", text: "Keep GPS enabled even in Airplane Mode")
                            TipRow(icon: "battery.100", text: "Ensure your device is fully charged before flight")
                            TipRow(icon: "wifi", text: "Airplane WiFi can improve GPS accuracy")
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    // About Section
                    VStack(spacing: 12) {
                        HStack {
                            Text("Version")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("1.0.0")
                                .fontWeight(.medium)
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)

                        Link(destination: URL(string: "https://github.com")!) {
                            HStack {
                                Image(systemName: "link")
                                Text("GitHub Repository")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                            }
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.horizontal)

                    // Bottom padding
                    Color.clear.frame(height: 20)
                }
                .padding(.top)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Settings")
            .onAppear {
                updatePermissionStatus()
            }
            .onReceive(refreshTimer) { _ in
                // Refresh permission status every second when Settings tab is visible
                updatePermissionStatus()
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
