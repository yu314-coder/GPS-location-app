import SwiftUI
import HealthKit

struct SummaryView: View {
    let flight: Flight

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var healthKitManager = HealthKitManager.shared
    @State private var showingShareSheet = false
    @State private var gpxFileURL: URL?
    @State private var effort: Int = 10
    @State private var effortSaved = false
    @State private var showEffortPrompt = false
    @State private var isSavingEffort = false

    private var activityName: String {
        guard let rawValue = flight.workoutType,
              let type = HKWorkoutActivityType(rawValue: rawValue) else {
            return "Workout"
        }

        switch type {
        case .cycling:
            return "Cycling"
        case .running:
            return "Running"
        case .walking:
            return "Walking"
        case .hiking:
            return "Hiking"
        case .other:
            return "Other"
        case .traditionalStrengthTraining:
            return "General"
        default:
            return "Workout"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Text("\(activityName) Summary")
                        .font(.title)
                        .fontWeight(.bold)

                    if let origin = flight.origin, let destination = flight.destination {
                        Text("\(origin) → \(destination)")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }

                    Text(flight.startDate, style: .date)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()

                // Static Map
                if !flight.locations.isEmpty {
                    StaticMapView(locations: flight.locations)
                        .frame(height: 250)
                        .cornerRadius(12)
                        .padding(.horizontal)
                }

                // Final Metrics
                if let metrics = flight.metrics {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Final Metrics")
                            .font(.headline)
                            .padding(.horizontal)

                        VStack(spacing: 12) {
                            SummaryRow(
                                icon: "arrow.left.and.right",
                                title: "Total Distance",
                                value: String(format: "%.1f km", metrics.distanceInKilometers)
                            )

                            SummaryRow(
                                icon: "clock",
                                title: "Total Time",
                                value: metrics.formattedDuration
                            )

                            SummaryRow(
                                icon: "speedometer",
                                title: "Average Speed",
                                value: String(format: "%.0f km/h", metrics.averageSpeedKmh)
                            )

                            SummaryRow(
                                icon: "speedometer",
                                title: "Max Speed",
                                value: String(format: "%.0f km/h", metrics.maxSpeedKmh)
                            )

                            SummaryRow(
                                icon: "mountain.2",
                                title: "Max Altitude",
                                value: String(format: "%.0f m", metrics.maxAltitude)
                            )

                            SummaryRow(
                                icon: "flame",
                                title: "Calories Burned",
                                value: String(format: "%.0f kcal", metrics.caloriesBurned)
                            )

                            if metrics.restingEnergyBurned > 0 {
                                SummaryRow(
                                    icon: "bed.double.fill",
                                    title: "Resting Energy",
                                    value: String(format: "%.0f kcal", metrics.restingEnergyBurned)
                                )
                            }
                        }
                        .padding(.horizontal)

                        // Heart Rate Section (if available)
                        if metrics.averageHeartRate != nil || metrics.maxHeartRate != nil {
                            Divider()
                                .padding(.vertical, 8)

                            Text("Heart Rate")
                                .font(.headline)
                                .padding(.horizontal)

                            VStack(spacing: 12) {
                                if let avgHR = metrics.averageHeartRate {
                                    SummaryRow(
                                        icon: "heart.fill",
                                        title: "Average Heart Rate",
                                        value: String(format: "%.0f bpm", avgHR)
                                    )
                                }

                                if let maxHR = metrics.maxHeartRate {
                                    SummaryRow(
                                        icon: "heart.fill",
                                        title: "Max Heart Rate",
                                        value: String(format: "%.0f bpm", maxHR)
                                    )
                                }
                            }
                            .padding(.horizontal)
                        }

                        // Splits Section
                        if !metrics.splits.isEmpty {
                            Divider()
                                .padding(.vertical, 8)

                            Text("Splits")
                                .font(.headline)
                                .padding(.horizontal)

                            VStack(spacing: 8) {
                                ForEach(metrics.splits) { split in
                                    HStack {
                                        Text("Km \(split.number)")
                                            .foregroundColor(.secondary)

                                        Spacer()

                                        Text(split.formattedPace)
                                            .fontWeight(.medium)

                                        if let hr = split.averageHeartRate {
                                            Text("♥ \(String(format: "%.0f", hr))")
                                                .font(.caption)
                                                .foregroundColor(.red)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding(.horizontal)
                        }

                        Divider()
                            .padding(.vertical, 8)

                        // Route Quality
                        Text("Route Quality")
                            .font(.headline)
                            .padding(.horizontal)

                        VStack(spacing: 12) {
                            SummaryRow(
                                icon: "point.3.connected.trianglepath.dotted",
                                title: "Total Points",
                                value: "\(metrics.totalPoints)"
                            )

                            SummaryRow(
                                icon: "checkmark.circle",
                                title: "Valid Points",
                                value: "\(metrics.validPoints)"
                            )

                            SummaryRow(
                                icon: "antenna.radiowaves.left.and.right",
                                title: "Signal Coverage",
                                value: String(format: "%.1f%%", metrics.signalCoverage)
                            )

                            SummaryRow(
                                icon: "scope",
                                title: "Average Accuracy",
                                value: String(format: "±%.1fm", metrics.averageAccuracy)
                            )
                        }
                        .padding(.horizontal)
                    }
                }

                // Effort (RPE)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Effort (RPE)")
                        .font(.headline)
                        .padding(.horizontal)

                    VStack(spacing: 12) {
                        HStack {
                            Text("Easy")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Slider(
                                value: Binding(
                                    get: { Double(effort) },
                                    set: { effort = Int($0.rounded()) }
                                ),
                                in: 1...10,
                                step: 1
                            )
                            Text("Max")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Effort")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(effort)/10")
                                .fontWeight(.medium)
                        }
                    }
                    .padding(.horizontal)

                    Button(action: { saveEffort(syncToHealthKit: true) }) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text(effortSaved ? "Effort Saved" : "Save Effort")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(effortSaved ? Color.green.opacity(0.2) : Color.blue.opacity(0.15))
                        .foregroundColor(effortSaved ? .green : .blue)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)
                }

                // Action Buttons
                VStack(spacing: 12) {
                    Button(action: {
                        // TODO: Open in Fitness app
                    }) {
                        HStack {
                            Image(systemName: "heart.text.square")
                            Text("View in Fitness")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }

                    Button(action: {
                        exportGPX()
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export GPX")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(flight.locations.isEmpty ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(flight.locations.isEmpty)

                    Button(action: {
                        if !effortSaved {
                            saveEffort(syncToHealthKit: true)
                        }
                        dismiss()
                    }) {
                        Text("Done")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray5))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let url = gpxFileURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $showEffortPrompt) {
            VStack(spacing: 16) {
                Text("How hard was it?")
                    .font(.headline)

                VStack(spacing: 12) {
                    HStack {
                        Text("Easy")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(effort) },
                                set: { effort = Int($0.rounded()) }
                            ),
                            in: 1...10,
                            step: 1
                        )
                        Text("Max")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Effort: \(effort)/10")
                        .fontWeight(.medium)
                }
                .padding(.horizontal)

                Button(action: {
                    saveEffort(syncToHealthKit: true)
                    showEffortPrompt = false
                }) {
                    HStack {
                        if isSavingEffort {
                            ProgressView()
                        }
                        Text("Save Effort")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
            }
            .padding()
        }
        .onAppear {
            if let savedEffort = flight.effort {
                effort = savedEffort
                effortSaved = true
            } else {
                effort = 10
                effortSaved = false
                showEffortPrompt = true
            }
        }
        .onChange(of: effort) {
            effortSaved = false
        }
    }

    private func exportGPX() {
        print("📤 Exporting GPX...")

        guard !flight.locations.isEmpty else {
            print("❌ No locations to export")
            return
        }

        if let url = GPXExporter.exportToGPX(flight: flight) {
            gpxFileURL = url
            showingShareSheet = true
        } else {
            print("❌ Failed to export GPX")
        }
    }

    private func saveEffort(syncToHealthKit: Bool = false) {
        var updatedFlight = flight
        updatedFlight.effort = effort
        FlightDataStore.shared.saveFlight(updatedFlight)
        effortSaved = true

        guard syncToHealthKit else { return }
        guard healthKitManager.isAuthorized else { return }
        guard !updatedFlight.locations.isEmpty, let metrics = updatedFlight.metrics else { return }

        isSavingEffort = true
        healthKitManager.resyncFlightToHealthKit(
            flight: updatedFlight,
            locations: updatedFlight.locations,
            metrics: metrics
        ) { success, _, _ in
            DispatchQueue.main.async {
                self.isSavingEffort = false
                if success {
                    print("✅ Effort synced to HealthKit")
                } else {
                    print("⚠️ Failed to sync effort to HealthKit")
                }
            }
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SummaryRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)

            Text(title)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .fontWeight(.medium)
        }
        .padding(.vertical, 4)
    }
}
