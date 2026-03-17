import SwiftUI

struct MetricsView: View {
    let metrics: FlightMetrics
    let nativeStepDistanceMeters: Double

    var body: some View {
        VStack(spacing: 8) {
            // Distance (Green - like Apple Workout)
            MetricCard(
                title: "Distance",
                value: String(format: "%.2f", metrics.distanceInKilometers),
                unit: "km",
                icon: "figure.walk",
                color: .green
            )

            HStack(spacing: 8) {
                // Heart Rate (Red/Pink - like Apple Workout)
                if let heartRate = metrics.currentHeartRate {
                    MetricCard(
                        title: "Heart Rate",
                        value: String(format: "%.0f", heartRate),
                        unit: "bpm",
                        icon: "heart.fill",
                        color: .red
                    )
                }

                // Calories (Orange - like Apple Workout)
                MetricCard(
                    title: "Calories",
                    value: String(format: "%.0f", metrics.caloriesBurned),
                    unit: "kcal",
                    icon: "flame.fill",
                    color: .orange
                )
            }

            HStack(spacing: 8) {
                // Speed (Cyan/Blue)
                MetricCard(
                    title: "Speed",
                    value: String(format: "%.1f", metrics.currentSpeed * 3.6),
                    unit: "km/h",
                    icon: "speedometer",
                    color: .cyan
                )

                // Altitude (White/Gray)
                MetricCard(
                    title: "Altitude",
                    value: String(format: "%.0f", metrics.currentAltitude),
                    unit: "m",
                    icon: "mountain.2.fill",
                    color: .white
                )
            }

            // Pressure (if available)
            if let pressure = metrics.currentPressure {
                MetricCard(
                    title: "Pressure",
                    value: String(format: "%.1f", pressure * 10), // Convert kPa to hPa
                    unit: "hPa",
                    icon: "gauge",
                    color: .yellow
                )
            }

            // Steps (if available from pedometer)
            if let steps = metrics.stepsCount, steps > 0 {
                MetricCard(
                    title: "Steps",
                    value: String(format: "%.0f", steps),
                    unit: "",
                    icon: "figure.walk",
                    color: .purple
                )
            }

            if nativeStepDistanceMeters > 0 {
                MetricCard(
                    title: "Step Dist",
                    value: String(format: "%.2f", nativeStepDistanceMeters / 1000.0),
                    unit: "km",
                    icon: "ruler",
                    color: .mint
                )
            }

            // Pace (if available)
            if metrics.currentPacePerKm > 0 && metrics.currentPacePerKm < 3600 {
                MetricCard(
                    title: "Pace",
                    value: metrics.formattedCurrentPace.replacingOccurrences(of: " /km", with: ""),
                    unit: "/km",
                    icon: "figure.run",
                    color: .blue
                )
            }
        }
        .padding(.horizontal, 4)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            // Icon and title
            HStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.2))
                        .frame(width: 18, height: 18)

                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundColor(color)
                }

                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            // Large value with unit
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.4),
                            Color.black.opacity(0.2)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

struct MetricsView_Previews: PreviewProvider {
    static var previews: some View {
        MetricsView(metrics: FlightMetrics(), nativeStepDistanceMeters: 0)
    }
}
