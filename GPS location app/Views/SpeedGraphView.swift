import SwiftUI
import Charts

struct SpeedGraphView: View {
    let speedHistory: [SpeedSample]

    // Get last 60 seconds of data for display
    private var recentSamples: [SpeedSample] {
        guard !speedHistory.isEmpty else { return [] }
        let sixtySecondsAgo = Date().addingTimeInterval(-60.0)
        return speedHistory.filter { $0.timestamp >= sixtySecondsAgo }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("10s Average Speed")
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
                        y: .value("Speed", sample.speed * 3.6)
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let speed = value.as(Double.self) {
                                Text("\(Int(speed))")
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
                SimpleLineChart(data: recentSamples.map { $0.speed * 3.6 })
                    .frame(height: 100)
            }

            HStack {
                Text("km/h")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if let latest = recentSamples.last {
                    Text(String(format: "%.1f km/h", latest.speed * 3.6))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// Simple line chart for iOS < 16
struct SimpleLineChart: View {
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
            .stroke(Color.blue, lineWidth: 2)
        }
    }
}

struct SpeedGraphView_Previews: PreviewProvider {
    static var previews: some View {
        let samples = (0..<30).map { i in
            SpeedSample(
                timestamp: Date().addingTimeInterval(TimeInterval(-30 + i)),
                speed: Double.random(in: 5...15)
            )
        }
        SpeedGraphView(speedHistory: samples)
            .padding()
    }
}
