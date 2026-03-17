import SwiftUI

struct MetricsView: View {
    let metrics: FlightMetrics

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                MetricCard(
                    title: "Distance",
                    value: String(format: "%.1f km", metrics.distanceInKilometers),
                    icon: "arrow.left.and.right"
                )

                MetricCard(
                    title: "Avg Speed",
                    value: String(format: "%.1f km/h", metrics.averageSpeedKmh),
                    icon: "gauge.medium"
                )
            }

            HStack(spacing: 20) {
                MetricCard(
                    title: "Current (10s)",
                    value: String(format: "%.1f km/h", metrics.tenSecondAverageSpeedKmh),
                    icon: "speedometer"
                )

                MetricCard(
                    title: "Max Speed",
                    value: String(format: "%.1f km/h", metrics.maxSpeedKmh),
                    icon: "hare.fill"
                )
            }

            HStack(spacing: 20) {
                MetricCard(
                    title: "Time",
                    value: metrics.formattedDuration,
                    icon: "clock"
                )

                MetricCard(
                    title: "Altitude",
                    value: String(format: "%.0f m", metrics.currentAltitude),
                    icon: "arrow.up"
                )
            }
        }
        .padding()
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(value)
                .font(.title2)
                .fontWeight(.bold)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct MetricsView_Previews: PreviewProvider {
    static var previews: some View {
        MetricsView(metrics: FlightMetrics())
    }
}
