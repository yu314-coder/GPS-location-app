import SwiftUI

// The watch's two speed engines on screen: which one is setting the speed now and what each of
// them reads this second. The engine is the iPhone's (see WatchSpeedEngine); choosing one engine
// over the other is a developer option.

/// What set the displayed speed, as a small labelled badge.
struct SpeedSourceBadge: View {
    let driving: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .accessibilityLabel("Speed from \(title)")
    }

    private var title: String { driving == "—" ? "Waiting" : driving }
    private var symbol: String { Self.symbol(for: driving) }
    private var tint: Color { Self.tint(for: driving) }

    static func symbol(for source: String) -> String {
        switch source {
        case "GPS": return "location.fill"
        case "iPhone": return "iphone"
        case "Neural": return "brain"
        case "Algorithm": return "square.stack.3d.up.fill"
        case "Steps": return "figure.walk"
        case "Held": return "pause.circle.fill"
        default: return "hourglass"
        }
    }

    static func tint(for source: String) -> Color {
        switch source {
        case "GPS": return .green
        case "iPhone": return .blue
        case "Neural": return .purple
        case "Algorithm": return .orange
        case "Steps": return .teal
        default: return .gray
        }
    }
}

/// Speed in the user's unit, with the unit label.
struct SpeedFormatter {
    let unit: String   // "km/h", "mph" or "knots", as in Settings

    func value(_ metresPerSecond: Double?) -> String {
        guard let v = metresPerSecond, v.isFinite else { return "—" }
        return String(format: "%.0f", v * factor)
    }
    var factor: Double {
        switch unit {
        case "mph": return 2.236_936
        case "knots": return 1.943_844
        default: return 3.6
        }
    }
}

/// Both engines in one compact card for the workout list: what set the speed, and what each
/// engine, the iPhone and GPS read this second.
struct SpeedEnginesCard: View {
    let readout: WorkoutSession.SpeedEngineReadout
    @AppStorage("speedUnit") private var speedUnit = "km/h"

    var body: some View {
        let fmt = SpeedFormatter(unit: speedUnit)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("SPEED FROM")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                SpeedSourceBadge(driving: readout.driving)
            }
            EngineLine(name: "Neural", symbol: "brain", tint: .purple,
                       value: fmt.value(readout.network), unit: speedUnit,
                       note: readout.familiarity.map { $0 <= 1 ? "" : "unfamiliar" } ?? "",
                       isDriving: readout.driving == "Neural")
            EngineLine(name: "Algorithm", symbol: "square.stack.3d.up.fill", tint: .orange,
                       value: fmt.value(readout.store), unit: speedUnit,
                       note: "\(readout.storeExamples.formatted()) ex.",
                       isDriving: readout.driving == "Algorithm")
            EngineLine(name: "iPhone", symbol: "iphone", tint: .blue,
                       value: fmt.value(readout.iPhone), unit: speedUnit, note: "",
                       isDriving: readout.driving == "iPhone")
            EngineLine(name: "GPS", symbol: "location.fill", tint: .green,
                       value: fmt.value(readout.gps), unit: speedUnit, note: "",
                       isDriving: readout.driving == "GPS")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

private struct EngineLine: View {
    let name: String
    let symbol: String
    let tint: Color
    let value: String
    let unit: String
    let note: String
    let isDriving: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundColor(tint)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12, weight: isDriving ? .bold : .regular))
            if !note.isEmpty {
                Text(note).font(.system(size: 9)).foregroundColor(.secondary)
            }
            Spacer(minLength: 2)
            Text(value == "—" ? "—" : "\(value) \(unit)")
                .font(.system(size: 13, weight: isDriving ? .bold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(isDriving ? tint : .primary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Choose which engine sets the watch's speed in Velocity Mode.
struct SpeedEngineChoiceView: View {
    @AppStorage(WatchSpeedEngine.defaultsKey) private var choice = WatchSpeedEngine.auto.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(WatchSpeedEngine.allCases, id: \.rawValue) { engine in
                Button {
                    choice = engine.rawValue
                    dismiss()
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: choice == engine.rawValue ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(choice == engine.rawValue ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.title).font(.system(size: 15, weight: .semibold))
                            Text(Self.explanation(engine))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Speed engine")
    }

    static func explanation(_ engine: WatchSpeedEngine) -> String {
        switch engine {
        case .auto:
            return "The iPhone's rule: its speed first when it's connected, otherwise Neural until the watch has learned \(LearnedSpeedEstimator.NETWORK_UNTIL_OBSERVATIONS.formatted()) examples, then the Algorithm."
        case .network:
            return "Testing: the built-in neural network only."
        case .store:
            return "Testing: the watch's own learned examples only."
        }
    }
}

/// The engines' state before a workout starts: the choice and how much the algorithm has learned.
struct SpeedEngineStatusCard: View {
    @AppStorage(WatchSpeedEngine.defaultsKey) private var choice = WatchSpeedEngine.auto.rawValue
    @AppStorage(WatchSpeedEngine.developerKey) private var developerUnlocked = false
    @State private var examples: Int?
    @State private var showChoice = false

    private var inUse: WatchSpeedEngine {
        developerUnlocked ? (WatchSpeedEngine(rawValue: choice) ?? .auto) : .auto
    }

    var body: some View {
        Button { if developerUnlocked { showChoice = true } } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Speed engine", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(inUse.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.purple)
                }
                HStack(spacing: 10) {
                    Label(SpeedNetwork.bundled != nil ? "Neural ready" : "Neural missing",
                          systemImage: SpeedNetwork.bundled != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(SpeedNetwork.bundled != nil ? .green : .red)
                    Label(examples.map { "\($0.formatted()) examples" } ?? "…", systemImage: "square.stack.3d.up.fill")
                        .foregroundStyle(.orange)
                }
                .font(.system(size: 11))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showChoice) { SpeedEngineChoiceView() }
        .task {
            let count = await Task.detached(priority: .utility) { LearnedSpeedEstimator.savedGroundExampleCount() }.value
            examples = count
        }
    }
}
