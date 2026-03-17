import SwiftUI

struct FlightHistoryView: View {
    @State private var flights: [Flight] = []
    @State private var selectedFlight: Flight?
    @State private var showingSummary = false

    var body: some View {
        NavigationView {
            VStack {
                if flights.isEmpty {
                    EmptyFlightsView()
                } else {
                    List {
                        ForEach(flights) { flight in
                            FlightRow(flight: flight)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedFlight = flight
                                    showingSummary = true
                                }
                        }
                        .onDelete(perform: deleteFlights)
                    }

                    // Statistics
                    VStack(spacing: 8) {
                        Text("Total Statistics")
                            .font(.headline)
                            .padding(.top)

                        HStack(spacing: 20) {
                            StatisticItem(
                                title: "Flights",
                                value: "\(flights.count)"
                            )

                            StatisticItem(
                                title: "Distance",
                                value: String(format: "%.0f km", totalDistance)
                            )

                            StatisticItem(
                                title: "Time",
                                value: formatTotalDuration(totalDuration)
                            )
                        }
                        .padding()
                        .background(Color.systemGray6)
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Flights")
            #if !os(watchOS)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
            }
            #endif
            .sheet(isPresented: $showingSummary) {
                if let flight = selectedFlight {
                    SummaryView(flight: flight)
                }
            }
            .onAppear {
                loadFlights()
            }
        }
    }

    private var totalDistance: Double {
        flights.reduce(0) { $0 + ($1.metrics?.totalDistance ?? 0) } / 1000.0
    }

    private var totalDuration: TimeInterval {
        flights.reduce(0) { $0 + $1.duration }
    }

    private func loadFlights() {
        // TODO: Load flights from persistent storage
        // For now, using empty array
    }

    private func deleteFlights(at offsets: IndexSet) {
        flights.remove(atOffsets: offsets)
        // TODO: Delete from persistent storage
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

                Image(systemName: "airplane")
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
                    Text("Flight")
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
}

struct EmptyFlightsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "airplane")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("No Flights Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Start tracking your first flight to see it here")
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
        VStack(spacing: 4) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct FlightHistoryView_Previews: PreviewProvider {
    static var previews: some View {
        FlightHistoryView()
    }
}
