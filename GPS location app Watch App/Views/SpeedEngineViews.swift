import SwiftUI

// The watch's two speed engines on screen (build 79): which one is setting the speed now, what
// each of them reads this second, and the choice between them. See LearnedSpeedEstimator.

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

/// Both engines side by side, live, with the iPhone and GPS for reference.
struct SpeedEnginesPage: View {
    let readout: WorkoutSession.SpeedEngineReadout
    @AppStorage("speedUnit") private var speedUnit = "km/h"
    @State private var showChoice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Speed engines")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    Button { showChoice = true } label: {
                        Text(readout.choice.title)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Speed engine: \(readout.choice.title). Change")
                }

                EngineRow(name: "Neural", symbol: "brain", tint: .purple,
                          value: fmt.value(readout.network), unit: speedUnit,
                          detail: networkDetail, isDriving: readout.driving == "Neural")
                EngineRow(name: "Algorithm", symbol: "square.stack.3d.up.fill", tint: .orange,
                          value: fmt.value(readout.store), unit: speedUnit,
                          detail: storeDetail, isDriving: readout.driving == "Algorithm")
                if readout.choice == .auto {
                    ExamplesProgress(count: readout.storeExamples)
                }

                Divider().padding(.vertical, 2)
                ReferenceRow(label: "iPhone", symbol: "iphone", value: readout.iPhone.map { fmt.value($0) },
                             unit: speedUnit, isDriving: readout.driving == "iPhone")
                ReferenceRow(label: "GPS", symbol: "location.fill", value: readout.gps.map { fmt.value($0) },
                             unit: speedUnit, isDriving: readout.driving == "GPS")
                if !readout.velocityMode && readout.driving == "GPS" {
                    Text("Both engines read along with GPS. Turn on Velocity Mode to let them set the speed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
        }
        .sheet(isPresented: $showChoice) { SpeedEngineChoiceView() }
    }

    private var fmt: SpeedFormatter { SpeedFormatter(unit: speedUnit) }

    private var networkDetail: String {
        guard let f = readout.familiarity else { return "Needs 5 s of motion" }
        return f <= 1 ? "Recognises this motion" : "Unfamiliar motion, not answering"
    }

    private var storeDetail: String {
        if readout.store != nil { return "\(readout.storeExamples.formatted()) of your examples" }
        if readout.storeExamples < 60 { return "Learning: \(readout.storeExamples) examples" }
        return "No close example yet"
    }
}

private struct EngineRow: View {
    let name: String
    let symbol: String
    let tint: Color
    let value: String
    let unit: String
    let detail: String
    let isDriving: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    if isDriving {
                        Text("IN USE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(tint, in: Capsule())
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(isDriving ? tint.opacity(0.22) : Color.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

private struct ReferenceRow: View {
    let label: String
    let symbol: String
    let value: String?
    let unit: String
    let isDriving: Bool

    var body: some View {
        HStack {
            Label(label, systemImage: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isDriving ? .primary : .secondary)
            Spacer()
            Text(value.map { "\($0) \(unit)" } ?? "not available")
                .font(.system(size: 12, weight: isDriving ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .tertiary : .primary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// How far the watch's own store is from taking over from the network in Auto.
struct ExamplesProgress: View {
    let count: Int

    var body: some View {
        let goal = LearnedSpeedEstimator.NETWORK_UNTIL_OBSERVATIONS
        VStack(alignment: .leading, spacing: 3) {
            // Drawn rather than a ProgressView: its track is the tint dimmed, which at zero reads as
            // a full bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(Color.orange)
                        .frame(width: geo.size.width * CGFloat(min(count, goal)) / CGFloat(goal))
                }
            }
            .frame(height: 5)
            .accessibilityLabel("\(count) of \(goal) examples")
            Text(count >= goal
                 ? "Auto uses the algorithm: \(count.formatted()) examples learned"
                 : "Auto uses Neural until the algorithm has \(goal.formatted()) examples (\(count.formatted()) now)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

/// Choose which engine sets the watch's speed in Velocity Mode.
struct SpeedEngineChoiceView: View {
    @AppStorage(LearnedSpeedEstimator.engineDefaultsKey) private var choice = LearnedSpeedEstimator.Engine.auto.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(LearnedSpeedEstimator.Engine.allCases, id: \.rawValue) { engine in
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

    static func explanation(_ engine: LearnedSpeedEstimator.Engine) -> String {
        switch engine {
        case .auto:
            return "iPhone first when it's connected. Otherwise Neural until the watch has learned \(LearnedSpeedEstimator.NETWORK_UNTIL_OBSERVATIONS.formatted()) examples, then the Algorithm."
        case .network:
            return "The built-in neural network, trained on recorded trips. Works from the first ride."
        case .store:
            return "The watch's own examples, learned from its GPS. Gets better the more you ride."
        }
    }
}

/// The engines' state before a workout starts: the choice and how much the algorithm has learned.
struct SpeedEngineStatusCard: View {
    @AppStorage(LearnedSpeedEstimator.engineDefaultsKey) private var choice = LearnedSpeedEstimator.Engine.auto.rawValue
    @State private var examples: Int?
    @State private var showChoice = false

    var body: some View {
        Button { showChoice = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Speed engine", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text((LearnedSpeedEstimator.Engine(rawValue: choice) ?? .auto).title)
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
