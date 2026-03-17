import SwiftUI
import Charts

struct SummaryView: View {
    let flight: Flight

    @Environment(\.dismiss) private var dismiss
    @StateObject private var healthKitManager = HealthKitManager()
    @State private var effort: Int = 10
    @State private var effortSaved = false
    @State private var showEffortPrompt = false
    @State private var isSavingEffort = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Text("Flight Summary")
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

                // Activity Graphs
                if let metrics = flight.metrics {
                    if !metrics.speedHistory.isEmpty || !metrics.altitudeHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Activity Graphs")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal)

                            // Speed Graph
                            if !metrics.speedHistory.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Speed Over Time")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)

                                    if #available(watchOS 9.0, *) {
                                        WatchSpeedChartView(speedHistory: metrics.speedHistory, maxSpeed: metrics.maxSpeed)
                                            .frame(height: 120)
                                            .padding(.horizontal, 8)
                                    }
                                }
                            }

                            // Altitude Graph
                            if !metrics.altitudeHistory.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Altitude Profile")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)

                                    if #available(watchOS 9.0, *) {
                                        WatchAltitudeChartView(
                                            altitudeHistory: metrics.altitudeHistory,
                                            maxAltitude: metrics.maxAltitude,
                                            minAltitude: metrics.minAltitude
                                        )
                                        .frame(height: 120)
                                        .padding(.horizontal, 8)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
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

                    Button(action: { saveEffort() }) {
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
                        // TODO: Export GPX
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export GPX")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }

                    Button(action: {
                        if !effortSaved {
                            saveEffort(syncToHealthKit: true)
                        }
                        dismiss()
                    }) {
                        Text("Done")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.systemGray5)
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showEffortPrompt) {
            VStack(spacing: 12) {
                Text("How hard was it?")
                    .font(.headline)

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
                    .font(.footnote)

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
                }
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

    private func saveEffort(syncToHealthKit: Bool = false) {
        var updatedFlight = flight
        updatedFlight.effort = effort
        FlightDataStore.shared.saveFlight(updatedFlight)
        effortSaved = true
        print("⌚ 🧮 Effort saved locally: \(effort)/10")

        guard syncToHealthKit else { return }
        guard let metrics = updatedFlight.metrics, !updatedFlight.locations.isEmpty else { return }

        isSavingEffort = true
        print("⌚ 🏥 Resyncing effort to HealthKit...")
        if healthKitManager.isAuthorized {
            healthKitManager.resyncFlightToHealthKit(
                flight: updatedFlight,
                locations: updatedFlight.locations,
                metrics: metrics
            ) { _, _ in
                DispatchQueue.main.async {
                    self.isSavingEffort = false
                }
            }
        } else {
            healthKitManager.requestAuthorization { success, _ in
                if success {
                    self.healthKitManager.resyncFlightToHealthKit(
                        flight: updatedFlight,
                        locations: updatedFlight.locations,
                        metrics: metrics
                    ) { _, _ in
                        DispatchQueue.main.async {
                            self.isSavingEffort = false
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isSavingEffort = false
                    }
                }
            }
        }
    }
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

// MARK: - Watch Chart Views

@available(watchOS 9.0, *)
struct WatchSpeedChartView: View {
    let speedHistory: [SpeedSample]
    let maxSpeed: Double

    var body: some View {
        Chart {
            ForEach(Array(speedHistory.enumerated()), id: \.offset) { index, sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Speed", sample.speed * 3.6) // Convert to km/h
                )
                .foregroundStyle(Color.blue.gradient)
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Speed", sample.speed * 3.6)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let speed = value.as(Double.self) {
                        Text("\(Int(speed))")
                            .font(.caption2)
                    }
                }
            }
        }
    }
}

@available(watchOS 9.0, *)
struct WatchAltitudeChartView: View {
    let altitudeHistory: [AltitudeSample]
    let maxAltitude: Double
    let minAltitude: Double

    var body: some View {
        Chart {
            ForEach(Array(altitudeHistory.enumerated()), id: \.offset) { index, sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Altitude", sample.altitude)
                )
                .foregroundStyle(Color.purple.gradient)
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Altitude", sample.altitude)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.3), Color.purple.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let alt = value.as(Double.self) {
                        Text("\(Int(alt))m")
                            .font(.caption2)
                    }
                }
            }
        }
    }
}
