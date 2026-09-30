import SwiftUI
import HealthKit

/// The watch's saved workouts, newest first (build 82).
///
/// This tab never read anything: loading was a placeholder, so it always said "No Workouts Yet"
/// however many workouts the watch had kept, and a swipe to delete only removed a row from the
/// screen. It now lists what FlightDataStore holds - the summaries the watch saves as a workout
/// runs - and opens the full route and charts from disk on a tap.
struct FlightHistoryView: View {
    @ObservedObject private var store = FlightDataStore.shared
    @State private var openedFlight: Flight?

    private var flights: [Flight] {
        store.savedFlights.sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        NavigationStack {
            Group {
                if flights.isEmpty {
                    ScrollView { EmptyFlightsView() }
                } else {
                    List {
                        Section {
                            ForEach(flights) { flight in
                                Button {
                                    // The list holds summaries without their points; the summary
                                    // screen needs the route, so read the full workout.
                                    openedFlight = store.loadFlightDetails(id: flight.id) ?? flight
                                } label: {
                                    FlightRow(flight: flight)
                                }
                            }
                            .onDelete(perform: deleteFlights)
                        }
                        Section("Total") {
                            HStack(spacing: 8) {
                                StatisticItem(title: flights.count == 1 ? "Workout" : "Workouts",
                                              value: "\(flights.count)")
                                StatisticItem(title: "km", value: String(format: "%.0f", totalDistance))
                                StatisticItem(title: "Time", value: formatTotalDuration(totalDuration))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle("Flights")
            .sheet(item: $openedFlight) { flight in
                SummaryView(flight: flight, fromHistory: true)
            }
        }
    }

    private var totalDistance: Double {
        flights.reduce(0) { $0 + ($1.metrics?.totalDistance ?? 0) } / 1000.0
    }

    private var totalDuration: TimeInterval {
        flights.reduce(0) { $0 + $1.duration }
    }

    private func deleteFlights(at offsets: IndexSet) {
        let shown = flights
        for index in offsets where shown.indices.contains(index) {
            store.deleteFlight(shown[index])
        }
    }

    private func formatTotalDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        return String(format: "%dh %dm", hours, minutes)
    }
}

struct FlightRow: View {
    let flight: Flight

    var body: some View {
        HStack(spacing: 10) {
            // Icon circle
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.3), Color.blue.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)

                Image(systemName: kind.symbol)
                    .font(.system(size: 16))
                    .foregroundColor(.purple)
            }

            VStack(alignment: .leading, spacing: 4) {
                // Title
                if let origin = flight.origin, let destination = flight.destination {
                    Text("\(origin) → \(destination)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                } else {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .semibold))
                }

                // Date and duration
                HStack(spacing: 4) {
                    Text(flight.startDate, style: .date)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Text(formatDuration(flight.duration))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                // Distance badge
                if let metrics = flight.metrics {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.blue)

                        Text(String(format: "%.1f km", metrics.distanceInKilometers))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.15))
                    )
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        return String(format: "%dh %dm", hours, minutes)
    }

    /// The same names and symbols as the workout picker.
    private var kind: (title: String, symbol: String) {
        switch flight.workoutType.flatMap({ HKWorkoutActivityType(rawValue: $0) }) {
        case .cycling?: return ("Cycling", "bicycle")
        case .running?: return ("Running", "figure.run")
        case .walking?: return ("Walking", "figure.walk")
        case .hiking?: return ("Hiking", "mountain.2.fill")
        case .other?: return ("Flight", "airplane")
        case .traditionalStrengthTraining?: return ("General", "figure.mixed.cardio")
        default: return ("Workout", "figure.run")
        }
    }
}

struct EmptyFlightsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "airplane")
                .font(.system(size: 34))
                .foregroundColor(.gray)

            Text("No Workouts Yet")
                .font(.headline)

            Text("Start tracking your first workout to see it here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct StatisticItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct FlightHistoryView_Previews: PreviewProvider {
    static var previews: some View {
        FlightHistoryView()
    }
}
