import SwiftUI
import Charts

/// How Velocity Mode works, and how well — written for the person using it.
///
/// Every number on this screen is measured, not estimated. The drives are real, the errors are
/// against GPS recorded at the same moment, and where the method fails it says so.
struct VelocityMethodView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                intro
                stageOne
                stageTwo
                stageThree
                stageFour
                accuracy
                limits
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("How Velocity Mode works")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Intro

    private var intro: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("The problem")
                Text("""
                Satellite positioning fails in the places people most want a route: tunnels, \
                car parks, dense city streets, and aircraft cabins. Velocity Mode records the \
                journey without it — speed from how the vehicle shakes, direction from the \
                magnetometer and gyroscope, and position by projecting both forward from a \
                single starting fix.
                """)
                .font(.callout)
                Divider()
                Text("Only the first point of the route comes from GPS. Every point after it is dead-reckoned.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Stage 1

    private var stageOne: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "1 · Turning vibration into a signature",
                              subtitle: "50 Hz accelerometer → 11 numbers") { EmptyView() }
                Text("""
                Road and engine vibration carry speed, but not in any one property — five \
                hand-built features were tried and failed. What works is the whole spectrum.
                """)
                .font(.callout)

                Formula(#"x[n] ← vertical acceleration, N = 256 samples (4 s at 50 Hz)"#)
                Formula(#"w[n] = ½ − ½·cos( 2πn / (N−1) )        Hann window"#)
                Formula(#"X[k] = Σₙ (x[n] − x̄)·w[n]·e^(−2πikn/N)"#)
                Formula(#"f_b = ln( Σ_{k ∈ band b} |X[k]|² )     b = 1 … 9"#)

                Text("The nine bands are bounded at 0.4, 0.8, 1.6, 2.5, 4, 6, 9, 13, 18 and 24 Hz. Two more features complete the signature:")
                    .font(.callout)
                Formula(#"f₁₀ = ln σ(x)        f₁₁ = ln( (1/(N−1)) Σₙ |x[n] − x[n−1]| )"#)

                Text("""
                A four-second window was measured against one and eight. Four is best: one second \
                is too little signal, eight blurs across changes in speed.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Stage 2

    private var stageTwo: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "2 · Signature to speed",
                              subtitle: "nearest neighbours over everything GPS has labelled") { EmptyView() }
                Text("""
                Nothing is assumed about the relationship between shaking and speed. The app \
                stores (signature → measured speed) pairs whenever GPS supplies a speed, and \
                answers by finding the closest signatures it has seen before.
                """)
                .font(.callout)

                Formula(#"d²(f, g) = Σᵢ ( (fᵢ − μᵢ)/σᵢ − (gᵢ − μᵢ)/σᵢ )²"#)
                Formula(#"wⱼ = 1 / (d²ⱼ + ε)"#)
                Formula(#"v̂ = ( Σⱼ wⱼ·vⱼ ) / ( Σⱼ wⱼ )        j = 12 nearest"#)

                Text("It refuses to answer from a distant match, because that is where its worst readings came from:")
                    .font(.callout)
                Formula(#"min_j d²ⱼ > 4  ⟹  decline, hold the last answer"#)

                Text("""
                Air and ground are kept as separate memories. A quiet cruise and a smooth road \
                look alike, so one store answering for both was wrong in each direction — a \
                road-trained model read 19 km/h at a 900 km/h cruise, and once flight data \
                joined it, a city drive read 337 km/h.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Stage 3

    private var stageThree: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "3 · Direction",
                              subtitle: "gyroscope for turns, magnetometer for the datum") { EmptyView() }
                Text("""
                Turn angle comes from the gyroscope, which is accurate over seconds but drifts \
                over minutes. Absolute direction comes from the magnetometer, which does not \
                drift but is disturbed by steel. Each covers the other's weakness.
                """)
                .font(.callout)

                Formula(#"θₜ = θₜ₋₁ + Δψ_gyro + κ·( ψ_datum + β − θₜ₋₁ )"#)
                Formula(#"β = carry offset: the angle between where the phone points and where the body travels"#)

                Text("""
                β cannot be derived without GPS. Estimating it from acceleration was tried and \
                returns noise, because Core Motion's attitude filter absorbs sustained \
                acceleration as a change in the gravity direction. So it is learned from GPS \
                course during the first 180 seconds of the workout and then frozen — which is \
                what physically happens on a flight: signal on the way to the aircraft, then none.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Stage 4

    private var stageFour: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "4 · Speed and direction to a route",
                              subtitle: "projection from one frozen anchor") { EmptyView() }
                Formula(#"Δs = v̂ · Δt"#)
                Formula(#"φₜ = φₜ₋₁ + (Δs·cos θₜ) / R"#)
                Formula(#"λₜ = λₜ₋₁ + (Δs·sin θₜ) / (R·cos φₜ)"#)

                Text("""
                Distance is withheld on a car-park ramp — climbing steadily while turning \
                continuously the same way, which a road does not do. A car crawling up a \
                concrete spiral shakes as hard as one doing 40 km/h on a road, and measured \
                against GPS the estimate there runs two to seven times too fast.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Accuracy

    private var accuracy: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppCard {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Measured accuracy",
                                  subtitle: "every bar is a real journey, checked against GPS") { EmptyView() }

                    Text("Distance recorded against distance travelled")
                        .font(.footnote).fontWeight(.semibold)
                    Chart(VelocityMethodData.drives) { d in
                        BarMark(x: .value("Error", d.distanceErrorPercent),
                                y: .value("Drive", d.label))
                        .foregroundStyle(d.distanceErrorPercent.magnitude <= 10
                                         ? Color.green : (d.distanceErrorPercent.magnitude <= 30
                                                          ? Color.orange : Color.red))
                        .annotation(position: d.distanceErrorPercent >= 0 ? .trailing : .leading) {
                            Text("\(d.distanceErrorPercent > 0 ? "+" : "")\(Int(d.distanceErrorPercent))%")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .chartXAxisLabel("error, %")
                    .frame(height: 240)

                    Text("""
                    Fast, steady driving with the phone held firmly by the vehicle is where this \
                    works: 15 km recorded to within 4%. Slow stop-start traffic is the hard case — \
                    a car at 5 km/h barely shakes differently from one at 15.
                    """)
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }

            AppCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Why slow journeys read high")
                        .font(.headline)
                    Text("""
                    The absolute error is a few km/h at any speed. That is 1% of a motorway \
                    speed and 140% of a walking pace, so the same model looks excellent on an \
                    open road and poor in traffic.
                    """)
                    .font(.callout)
                    Chart(VelocityMethodData.speedBias) { b in
                        BarMark(x: .value("Speed", b.band),
                                y: .value("Bias", b.biasKmh))
                        .foregroundStyle(Color.accentColor.gradient)
                    }
                    .chartYAxisLabel("over-read, km/h")
                    .chartXAxisLabel("true speed, km/h")
                    .frame(height: 180)
                    Text("Measured by leave-one-out over 4,178 stored observations from matched drives.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            AppCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Direction, before and after the carry offset was handled")
                        .font(.headline)
                    Chart(VelocityMethodData.heading) { h in
                        BarMark(x: .value("Drive", h.label),
                                y: .value("Error", h.meanSignedDegrees.magnitude))
                        .foregroundStyle(h.afterFix ? Color.green : Color.red)
                    }
                    .chartYAxisLabel("mean direction error, °")
                    .frame(height: 180)
                    Text("""
                    Red: the route came out correctly shaped but pivoted about its start. Green: \
                    after the offset is learned and frozen. On a 15 km drive this moved the \
                    finish from 4174 m off to 366 m.
                    """)
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Limits

    private var limits: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("What it cannot do")
                Limitation("Hold the phone in your hand and the speed signal disappears.",
                           "Body contact damps the vibration until the signature stops varying with speed — measured flat from 10 to 65 km/h. Rest the phone in the vehicle.")
                Limitation("Aircraft speed cannot be measured without GPS.",
                           "A takeoff roll is the most sustained acceleration a phone will ever see, and Core Motion's attitude filter erases exactly that. Replayed on a real flight, integration recovered 60 km/h of a 679 km/h climb.")
                Limitation("A vehicle it has never learned reads wrong at first.",
                           "The model answers for conditions it has observed. A first motorcycle ride teaches it; the second is far better.")
                Limitation("It needs a starting fix.",
                           "Direction is relative until something establishes north, and position is relative until something establishes where.")
            }
        }
    }
}

// MARK: - Pieces

private struct Formula: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .serif))
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground)))
            .textSelection(.enabled)
    }
}

private struct Limitation: View {
    let title: String
    let detail: String
    init(_ title: String, _ detail: String) { self.title = title; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.orange)
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 22)
        }
    }
}

// MARK: - The measurements

/// Real results, recorded in Velocity Mode with GPS running alongside purely as ground truth.
enum VelocityMethodData {
    struct Drive: Identifiable {
        let id = UUID()
        let label: String
        let distanceErrorPercent: Double
    }
    struct SpeedBias: Identifiable {
        let id = UUID()
        let band: String
        let biasKmh: Double
    }
    struct Heading: Identifiable {
        let id = UUID()
        let label: String
        let meanSignedDegrees: Double
        let afterFix: Bool
    }

    static let drives: [Drive] = [
        .init(label: "15 km, open road", distanceErrorPercent: 3.8),
        .init(label: "Motorcycle, riding", distanceErrorPercent: 6.0),
        .init(label: "City, 19 min", distanceErrorPercent: 20.1),
        .init(label: "City, 12 min", distanceErrorPercent: 21.6),
        .init(label: "Car park start", distanceErrorPercent: 25.2),
        .init(label: "Car park, both ends", distanceErrorPercent: 57.6),
        .init(label: "Car park, short", distanceErrorPercent: 61.6)
    ]

    static let speedBias: [SpeedBias] = [
        .init(band: "2–10", biasKmh: 1.0),
        .init(band: "10–20", biasKmh: 1.4),
        .init(band: "20–35", biasKmh: 1.7),
        .init(band: "35–55", biasKmh: 0.8)
    ]

    static let heading: [Heading] = [
        .init(label: "Before", meanSignedDegrees: 24.9, afterFix: false),
        .init(label: "Before ", meanSignedDegrees: 35.8, afterFix: false),
        .init(label: "After", meanSignedDegrees: 0.8, afterFix: true),
        .init(label: "After ", meanSignedDegrees: 1.3, afterFix: true),
        .init(label: "After  ", meanSignedDegrees: 1.0, afterFix: true),
        .init(label: "After   ", meanSignedDegrees: 2.1, afterFix: true)
    ]
}
