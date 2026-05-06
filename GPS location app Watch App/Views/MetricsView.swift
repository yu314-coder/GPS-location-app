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

            let displayedAcceleration = metrics.currentMotionAcceleration ?? metrics.currentAcceleration.map(abs)
            if displayedAcceleration != nil || metrics.currentGPSQualityScore != nil {
                HStack(spacing: 8) {
                    if let acceleration = displayedAcceleration {
                        MetricCard(
                            title: "a",
                            value: String(format: "%.2f", acceleration),
                            unit: "m/s²",
                            icon: "waveform.path.ecg",
                            color: .pink
                        )
                    }

                    if let gpsQuality = metrics.currentGPSQualityScore {
                        MetricCard(
                            title: "GPS Q",
                            value: String(format: "%.0f", gpsQuality),
                            unit: "/100",
                            icon: "location.magnifyingglass",
                            color: gpsQuality >= 80 ? .green : gpsQuality >= 50 ? .orange : .red
                        )
                    }
                }
            }

            if let verticalSpeed = metrics.currentVerticalSpeed {
                MetricCard(
                    title: "Climb",
                    value: String(format: "%.0f", verticalSpeed * 60.0),
                    unit: "m/min",
                    icon: "arrow.up.and.down",
                    color: .teal
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

private struct LiveMotionAccelerationGraph: View {
    let title: String
    let samples: [MotionAccelerationSample]
    let color: Color

    private var visibleSamples: [MotionAccelerationSample] {
        Array(samples.suffix(80))
    }

    private var latestAcceleration: Double? {
        visibleSamples.last?.acceleration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(color)
                Spacer()
                if let latestAcceleration {
                    Text(String(format: "%.2f", latestAcceleration))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            GeometryReader { proxy in
                let values = visibleSamples.map(\.acceleration)
                let maxValue = max(values.max() ?? 1, 1)
                let width = max(proxy.size.width, 1)
                let height = max(proxy.size.height, 1)

                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(0.12))

                    Path { path in
                        guard visibleSamples.count > 1 else { return }
                        for index in visibleSamples.indices {
                            let xPosition = width * CGFloat(index) / CGFloat(visibleSamples.count - 1)
                            let normalized = min(max(visibleSamples[index].acceleration / maxValue, 0), 1)
                            let yPosition = height - (height * CGFloat(normalized))

                            if index == visibleSamples.startIndex {
                                path.move(to: CGPoint(x: xPosition, y: yPosition))
                            } else {
                                path.addLine(to: CGPoint(x: xPosition, y: yPosition))
                            }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    .padding(8)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.25))
        )
    }
}

private struct LatexLabelText: View {
    let text: String
    var uppercase = false

    private var axisParts: (prefix: String, base: String, subscriptText: String)? {
        for label in ["a_x", "a_y", "a_z", "r_x", "r_y", "r_z"] {
            guard text.hasSuffix(label) else { continue }
            let prefix = String(text.dropLast(label.count))
            return (prefix, String(label.prefix(1)), String(label.suffix(1)))
        }
        return nil
    }

    var body: some View {
        if let axisParts {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if !axisParts.prefix.isEmpty {
                    Text(axisParts.prefix)
                }
                Text(axisParts.base)
                Text(axisParts.subscriptText)
                    .font(.system(size: 7, weight: .semibold))
                    .baselineOffset(-3)
            }
        } else {
            Text(uppercase ? text.uppercased() : text)
        }
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

                LatexLabelText(text: title, uppercase: true)
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
