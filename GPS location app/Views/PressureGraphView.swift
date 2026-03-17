import SwiftUI
import Charts

struct PressureGraphView: View {
    let pressureHistory: [PressureSample]

    // Get last 60 seconds of data for display
    private var recentSamples: [PressureSample] {
        guard !pressureHistory.isEmpty else { return [] }
        let sixtySecondsAgo = Date().addingTimeInterval(-60.0)
        return pressureHistory.filter { $0.timestamp >= sixtySecondsAgo }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Atmospheric Pressure")
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
                        y: .value("Pressure", sample.pressure * 10) // Convert kPa to hPa for display
                    )
                    .foregroundStyle(.cyan)
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let pressure = value.as(Double.self) {
                                Text("\(Int(pressure))")
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
                SimplePressureChart(data: recentSamples.map { $0.pressure * 10 })
                    .frame(height: 100)
            }

            HStack {
                Text("hectopascals (hPa)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if let latest = recentSamples.last {
                    Text(String(format: "%.1f hPa", latest.pressure * 10))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.cyan)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// Simple pressure chart for iOS < 16
struct SimplePressureChart: View {
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
            .stroke(Color.cyan, lineWidth: 2)
        }
    }
}

struct PressureGraphView_Previews: PreviewProvider {
    static var previews: some View {
        let samples = (0..<30).map { i in
            PressureSample(
                timestamp: Date().addingTimeInterval(TimeInterval(-30 + i)),
                pressure: Double.random(in: 100...102) // kPa (1000-1020 hPa)
            )
        }
        PressureGraphView(pressureHistory: samples)
            .padding()
    }
}
