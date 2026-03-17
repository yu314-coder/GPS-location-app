import SwiftUI

struct SignalQualityView: View {
    let signalQuality: GPSSignalQuality
    let horizontalAccuracy: Double?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Signal bars
                HStack(spacing: 3) {
                    ForEach(0..<4) { index in
                        SignalBar(
                            isActive: index < signalQuality.barCount,
                            height: CGFloat(10 + index * 5)
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("GPS Signal")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(signalQuality.description)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(colorForQuality(signalQuality))
                }

                Spacer()

                if let accuracy = horizontalAccuracy {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Accuracy")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("±\(Int(accuracy))m")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    private func colorForQuality(_ quality: GPSSignalQuality) -> Color {
        switch quality {
        case .unknown:
            return .gray
        case .noSignal:
            return .red
        case .poor:
            return .orange
        case .fair:
            return .yellow
        case .good:
            return Color(red: 0.5, green: 0.8, blue: 0.3)
        case .excellent:
            return .green
        }
    }
}

struct SignalBar: View {
    let isActive: Bool
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(isActive ? Color.green : Color.gray.opacity(0.3))
            .frame(width: 6, height: height)
    }
}

struct SignalQualityView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            SignalQualityView(signalQuality: .excellent, horizontalAccuracy: 15)
            SignalQualityView(signalQuality: .good, horizontalAccuracy: 35)
            SignalQualityView(signalQuality: .fair, horizontalAccuracy: 75)
            SignalQualityView(signalQuality: .poor, horizontalAccuracy: 120)
            SignalQualityView(signalQuality: .noSignal, horizontalAccuracy: nil)
        }
        .padding()
    }
}
