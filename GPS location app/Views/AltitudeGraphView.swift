import SwiftUI
import Charts

struct AltitudeGraphView: View {
    let altitudeHistory: [AltitudeSample]

    // Get last 60 seconds of data for display
    private var recentSamples: [AltitudeSample] {
        guard !altitudeHistory.isEmpty else { return [] }
        let sixtySecondsAgo = Date().addingTimeInterval(-60.0)
        return altitudeHistory.filter { $0.timestamp >= sixtySecondsAgo }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Altitude")
                .font(.caption)
                .foregroundColor(.secondary)

            if recentSamples.isEmpty {
                Text("No data yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
            } else if #available(iOS 16.0, *) {
                Chart(recentSamples, id: \.timestamp) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Altitude", sample.altitude)
                    )
                    .foregroundStyle(.green)
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let altitude = value.as(Double.self) {
                                Text("\(Int(altitude))")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                    }
                }
                .frame(height: 100)
            } else {
                // Fallback for iOS < 16: Simple line chart
                SimpleAltitudeChart(data: recentSamples.map { $0.altitude })
                    .frame(height: 100)
            }

            HStack {
                Text("meters")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if let latest = recentSamples.last {
                    Text(String(format: "%.0f m", latest.altitude))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// Simple altitude chart for iOS < 16
struct SimpleAltitudeChart: View {
    let data: [Double]

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard !data.isEmpty else { return }

                let maxValue = data.max() ?? 1.0
                let minValue = data.min() ?? 0.0
                let range = maxValue - minValue

                guard range > 0 else { return }

                let xStep = geometry.size.width / CGFloat(data.count - 1)

                for (index, value) in data.enumerated() {
                    let x = CGFloat(index) * xStep
                    let normalized = (value - minValue) / range
                    let y = geometry.size.height * (1 - CGFloat(normalized))

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.green, lineWidth: 2)
        }
    }
}

struct AltitudeGraphView_Previews: PreviewProvider {
    static var previews: some View {
        let samples = (0..<30).map { i in
            AltitudeSample(
                timestamp: Date().addingTimeInterval(TimeInterval(-30 + i)),
                altitude: Double.random(in: 100...200)
            )
        }
        AltitudeGraphView(altitudeHistory: samples)
            .padding()
    }
}
