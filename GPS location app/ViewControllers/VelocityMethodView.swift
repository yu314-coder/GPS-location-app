import SwiftUI
import Charts

/// How Velocity Mode works, and how well — written for the person using it.
///
/// Every number here is measured against GPS recorded at the same moment as the estimate. Nothing
/// is modelled, simulated or extrapolated, and where the method fails it says so with a magnitude.
struct VelocityMethodView: View {
    /// AT ACCESSIBILITY TEXT SIZES A CHART IS WORSE THAN NO CHART.
    ///
    /// These are horizontal bars with a journey name inside each band. When the label grows and
    /// the plot does not, the name lands on top of its own bar — measured at accessibility-medium,
    /// where "Suburban, 12 min" had the bar drawn straight through it. The tables carry every
    /// number the charts do, so above xxxLarge the charts step aside rather than overlap.
    @Environment(\.dynamicTypeSize) private var typeSize
    private var chartsFit: Bool { typeSize <= .xxxLarge }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    intro.id("intro")
                    stageOne
                    stageTwo
                    stageThree
                    stageFour
                    roadResults.id("road")
                    slowSpeed
                    headingResults.id("heading")
                    basement.id("basement")
                    flight.id("flight")
                    pocket.id("pocket")
                    limits.id("limits")
                }
                .readableColumn(720)
                .padding(16)
            }
            .onAppear {
                #if DEBUG
                // Screenshot hook: jump straight to a section so it can be captured.
                if let target = ProcessInfo.processInfo.environment["SCROLL_TO"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                #endif
            }
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
                Satellite positioning fails in the places people most want a route: tunnels, car \
                parks, dense city streets, aircraft cabins. Velocity Mode records the journey \
                without it — speed from how the vehicle shakes, direction from the magnetometer \
                and gyroscope, and position projected forward from a single starting fix.
                """)
                .font(.callout)
                Divider()
                Text("Only the first point of the route comes from GPS. Every point after it is dead-reckoned.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Method

    private var stageOne: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "1 · Vibration into a signature",
                              subtitle: "50 Hz accelerometer → 11 numbers") { EmptyView() }
                Text("""
                Road and engine vibration carry speed, but not in any single property — five \
                hand-built features were tried and failed. What works is the whole spectrum. Four \
                seconds of vertical acceleration are windowed and transformed:
                """)
                .font(.callout)
                Equation("eq_window")
                Equation("eq_fft")
                Text("Energy is summed into nine log-spaced bands at 0.4, 0.8, 1.6, 2.5, 4, 6, 9, 13, 18 and 24 Hz:")
                    .font(.callout)
                Equation("eq_band")
                Text("Two time-domain terms complete the signature:").font(.callout)
                Equation("eq_tail")
                Text("""
                Four seconds was measured against one and eight. One is too little signal; eight \
                blurs across changes in speed, raising low-speed bias from +1.0 to +6.0 km/h.
                """)
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var stageTwo: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "2 · Signature into speed",
                              subtitle: "nearest neighbours over GPS-labelled examples") { EmptyView() }
                Text("""
                Nothing is assumed about how shaking relates to speed. The app stores signature \
                and measured-speed pairs whenever GPS supplies a speed, then answers by locality.
                """)
                .font(.callout)
                Equation("eq_dist")
                Equation("eq_knn")
                Text("It is allowed to refuse, which is where its worst readings used to come from:")
                    .font(.callout)
                Equation("eq_reject")
                Text("""
                Error scales directly with match distance: 5.3 km/h mean error when the nearest \
                stored signature is within d² = 1.03, rising to 16.9 km/h in the range 2.12–4.36. \
                Refusing a distant match removes the worst answers.
                """)
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var stageThree: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "3 · Direction",
                              subtitle: "gyroscope for turns, magnetometer for the datum") { EmptyView() }
                Text("""
                Turn angle comes from the gyroscope, accurate over seconds but drifting over \
                minutes. Absolute direction comes from the magnetometer, which does not drift but \
                is disturbed by steel. Each covers the other's weakness.
                """)
                .font(.callout)
                Equation("eq_heading")
                Text("""
                β is the carry offset: the angle between where the phone points and where the body \
                travels. It cannot be derived without an outside reference — estimating it from \
                acceleration returns noise (concentration R = 0.15 against known answers). It is \
                learned from GPS course over the first 180 seconds and then frozen, which is what \
                physically happens on a flight: signal on the way to the aircraft, none after.
                """)
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var stageFour: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "4 · Speed and direction into a route",
                              subtitle: "projection from one frozen anchor") { EmptyView() }
                Equation("eq_project")
                Text("""
                Distance is withheld on a car-park ramp — climbing steadily while turning \
                continuously the same way, which a road does not do.
                """)
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Road results

    private var roadResults: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Measured on the road",
                              subtitle: "recorded distance against GPS, same moment") { EmptyView() }
                if chartsFit {
                Chart {
                    ForEach(VelocityMethodData.journeys) { j in
                        BarMark(x: .value("Distance", j.trueM), y: .value("Journey", j.name))
                            .position(by: .value("Source", "GPS truth"))
                            .foregroundStyle(by: .value("Source", "GPS truth"))
                        BarMark(x: .value("Distance", j.recordedM), y: .value("Journey", j.name))
                            .position(by: .value("Source", "recorded"))
                            .foregroundStyle(by: .value("Source", "recorded"))
                            .annotation(position: .trailing, spacing: 3) {
                                Text(String(format: "%+.0f%%", j.errorPercent))
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(j.errorPercent > 30 ? Color.red
                                                     : (j.errorPercent > 10 ? Color.orange : Color.green))
                            }
                    }
                }
                .chartForegroundStyleScale([
                    "recorded": Color.accentColor,
                    "GPS truth": Color(.systemGray3)
                ])
                .chartXAxisLabel("metres travelled")
                .chartXScale(domain: 0...17500)
                // NO VERTICAL GRIDLINES. The journey names are drawn inside the plot area, and
                // the dashed lines at 5,000 and 10,000 ran straight through the middle of
                // "Suburban, 12 min" and "Motorcycle, 20 min". The axis values below carry the
                // scale on their own.
                .chartXAxis { AxisMarks { AxisValueLabel() } }
                .chartYAxis { AxisMarks(position: .leading) { AxisValueLabel() } }
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 330)
                }

                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(VelocityMethodData.journeys.enumerated()), id: \.element.id) { i, j in
                        if i > 0 { Divider() }
                        JourneyRow(name: j.name,
                                   recorded: "\(j.recordedM)\u{00A0}m",
                                   truth: "\(j.trueM)\u{00A0}m",
                                   error: String(format: "%+.0f%%", j.errorPercent),
                                   detail: String(format: "%.0f km/h average", j.avgKmh))
                    }
                }
            }
        }
    }

    private var slowSpeed: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Why slow journeys read long")
                Text("""
                The absolute error is one to two km/h at any speed. That is 2% of a motorway pace \
                and over 40% of a crawl, so the same estimator looks excellent on an open road and \
                poor in traffic.
                """)
                .font(.callout)
                if chartsFit {
                Chart(VelocityMethodData.speedBias) { b in
                    BarMark(x: .value("Speed", b.band), y: .value("Bias", b.biasKmh))
                        .foregroundStyle(Color.accentColor.gradient)
                        .annotation(position: .top) {
                            Text(String(format: "+%.1f", b.biasKmh))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYAxisLabel("over-read, km/h")
                .chartXAxisLabel("true speed, km/h")
                .chartYScale(domain: 0...2.2)
                .frame(height: 180)
                } else {
                    BiasTable()
                }
                Text("""
                Leave-one-out over 4,178 stored observations from matched journeys. Adding other \
                carry positions and vehicles to the same store roughly doubles these figures.
                """)
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var headingResults: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Direction, before and after the carry offset")
                if chartsFit {
                Chart(VelocityMethodData.heading) { h in
                    BarMark(x: .value("Journey", h.label), y: .value("Error", h.degrees))
                        .foregroundStyle(h.afterFix ? Color.green : Color.red)
                        .annotation(position: .top) {
                            Text(String(format: "%.1f°", h.degrees))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYAxisLabel("mean direction error, °")
                .chartYScale(domain: 0...42)
                .frame(height: 180)
                } else {
                    HeadingTable()
                }
                Text("""
                Red: the route came out correctly shaped but pivoted about its start. On one 15 km \
                journey the recorded net displacement matched the true one to within 8 m of length \
                while pointing 26° wrong, finishing 4,174 m from the real endpoint. With the offset \
                applied that becomes 366 m — 2.4% of the distance travelled.
                """)
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Car parks

    private var basement: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Underground car parks",
                              subtitle: "where the method is worst, and why") { EmptyView() }
                Text("""
                A car crawling up a concrete spiral shakes as hard as one doing 40 km/h on a road. \
                Split by the barometer and gyroscope, the same journeys separate cleanly:
                """)
                .font(.callout)
                VStack(spacing: 0) {
                    ForEach(Array(VelocityMethodData.rampSplit.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider() }
                        JourneyRow(name: r.name, recorded: "\(r.recordedM)\u{00A0}m",
                                   truth: "\(r.trueM)\u{00A0}m",
                                   error: String(format: "%+.0f%%", r.errorPercent),
                                   detail: r.phase == "ramp" ? "on the ramp" : "on the road",
                                   emphasise: r.phase == "ramp")
                    }
                }
                Text("""
                Ramps read 169% to 297% long; the road between them reads 17% to 23%. Distance is \
                now withheld where the barometer shows a sustained climb above 0.08 m/s and the \
                gyroscope shows more than 150° of same-direction turning over 30 seconds — a \
                helical ramp does both, a hill or a junction does only one.
                """)
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Flight

    private var flight: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "In an aircraft",
                              subtitle: "the case this mode was built for, and it does not work") { EmptyView() }
                Text("""
                A 22.8-minute flight was recorded with GPS valid throughout, up to 706 km/h. \
                Replaying it with GPS removed at four points gives the distance the app would have \
                recorded had signal been lost there:
                """)
                .font(.callout)
                if chartsFit {
                Chart(VelocityMethodData.flight) { f in
                    BarMark(x: .value("Error", f.errorPercent), y: .value("Point", f.point))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .annotation(position: .leading) {
                            Text("\(Int(f.errorPercent))%")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxisLabel("distance error, %")
                .chartXAxis { AxisMarks { AxisValueLabel() } }
                .chartYAxis { AxisMarks(position: .leading) { AxisValueLabel() } }
                .frame(height: 165)
                } else {
                    FlightTable()
                }
                Text("""
                Signal is normally lost on the ground, which freezes taxi speed for the whole \
                flight. The along-track correction recovers roughly 60 km/h of a 679 km/h climb: \
                after 400 seconds of held speed it had contributed −2 km/h.

                The cause is that an accelerometer cannot separate gravity from sustained \
                acceleration, and the phone's sensor fusion resolves that ambiguity by treating a \
                takeoff roll as a change in which way is down. Heading is unaffected — measured at \
                3.9° median across the flight — so direction works and speed does not.
                """)
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Where it fails completely

    /// The worst measured result, kept in the app rather than only in the paper.
    ///
    /// Every other failure here is a matter of degree — too high, too low, right about the wrong
    /// regime. This one is different: on a motorcycle with the phone in a pocket the input signal
    /// contains no speed at all, so the estimate is flat. Showing it matters more than the
    /// flattering cases do, because someone deciding whether to trust a route needs to know the
    /// mode has a regime where it is confidently wrong.
    private var pocket: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Motorcycle, phone in a pocket",
                              subtitle: "where it fails completely") { EmptyView() }
                Text("""
                19 minutes, 1146 readings. The estimate reports roughly 50 km/h whatever the \
                motorcycle is doing — including standing still at a light:
                """)
                .font(.callout)
                if chartsFit {
                    Chart(VelocityMethodData.pocket) { b in
                        BarMark(x: .value("Band", b.band), y: .value("km/h", b.realKmh))
                            .position(by: .value("Source", "real"))
                            .foregroundStyle(AppTheme.distance)
                        BarMark(x: .value("Band", b.band), y: .value("km/h", b.estimatedKmh))
                            .position(by: .value("Source", "estimated"))
                            .foregroundStyle(Color.red.opacity(0.85))
                    }
                    .chartForegroundStyleScale([
                        "real": AppTheme.distance, "estimated": Color.red.opacity(0.85)
                    ])
                    .chartXAxisLabel("real speed band, km/h")
                    .chartYAxisLabel("km/h")
                    .frame(height: 190)
                } else {
                    PocketTable()
                }
                Text("""
                The reported speed and the real speed are unrelated: R = +0.13. The vibration \
                signature and the real speed are related at R = −0.02, which is to say not at all.

                The signature reads 7.467 while the motorcycle is stopped and 7.386 at over \
                45 km/h — indistinguishable, and marginally higher at rest. A car rests the phone \
                on a rigid surface and delivers road noise that scales with speed. A motorcycle \
                delivers engine vibration, which follows engine speed rather than road speed and \
                is undiminished at a standstill in gear, through clothing that damps what little \
                road input survives. There is no speed in the input, so nothing can recover one: \
                47 stationary readings accumulated 468 m that did not happen.

                What matters most is the confidence. The regime-distance signal sat at 3.51 all \
                ride — outside the 1.81–2.87 range for the same vehicle carried differently — and \
                the extrapolation warning was false on all 1146 readings. It reported 53.8 km/h at \
                a red light and never signalled that it was guessing.
                """)
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Limits

    private var limits: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("What it cannot do")
                Limitation("Hold the phone in your hand and the speed signal disappears.",
                           "Body contact damps the vibration until the signature stops varying with speed — measured at 7.10, 7.08, 7.07, 7.13 and 7.25 across 10 to 65 km/h. Reported speed becomes a constant. Rest the phone in the vehicle.")
                Limitation("A stationary engine reads as movement.",
                           "A motorcycle at a red light reads 5.2 km/h in a mount, and 53.8 km/h in a pocket. No tested signal separates an idling engine from a moving one.")
                Limitation("In a pocket on a motorcycle it does not work at all.",
                           "Not merely inaccurate: the estimate is flat, unrelated to real speed at R = +0.13, and the model does not warn that it is guessing. See above.")
                Limitation("Aircraft speed cannot be measured without GPS.",
                           "See above: −82% to −87% when signal is lost on the ground.")
                Limitation("A vehicle it has never learned reads wrong at first.",
                           "The model answers only for conditions it has observed. A first motorcycle ride teaches it; the second is far better.")
                Limitation("These numbers are one phone, one person, three vehicles.",
                           "23 instrumented journeys in one city. They characterise this configuration and may not transfer.")
            }
        }
    }
}

// MARK: - Pieces

/// A real LaTeX equation, typeset by pdflatex at build time and bundled as a transparent mask so
/// it takes the foreground colour and works in both themes.
private struct Equation: View {
    let name: String
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    init(_ name: String) { self.name = name }

    var body: some View {
        Group {
            if let ui = UIImage(named: name)?.withRenderingMode(.alwaysTemplate) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    // EVERY EQUATION WAS RENDERED AT THE SAME DPI AND POINT SIZE, so its pixel
                    // height is a true measure of how tall it is typographically — a fraction is
                    // genuinely taller than a single line. Scaling on that keeps the type size
                    // consistent between them, which a width-based rule does not: it shrank a
                    // wide equation until its symbols were half the size of the one above.
                    // scaledToFit inside a width-limited frame then handles the wide ones.
                    .frame(maxWidth: .infinity,
                           maxHeight: ui.size.height / 3.3 * scale,
                           alignment: .center)
                    .foregroundStyle(.primary)
            } else {
                Text(name).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(.tertiarySystemGroupedBackground)))
    }
}

/// One measured journey.
///
/// Two lines rather than one. A single row could not hold "Motorcycle, 20 min" beside four
/// numeric columns without truncating it, and minimumScaleFactor made each row a different size
/// as it shrank to fit — so rows that should have been comparable were not even the same height.
private struct JourneyRow: View {
    let name: String
    let recorded: String
    let truth: String
    let error: String
    let detail: String
    var header: Bool = false
    var emphasise: Bool = false

    var body: some View {
        if header { EmptyView() } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.caption).fontWeight(.medium)
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(recorded).font(.system(.caption, design: .monospaced))
                    Text("GPS\u{00A0}\(truth)").font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(error)
                    .font(.system(.caption, design: .monospaced)).fontWeight(.semibold)
                    .foregroundStyle(emphasise ? .red : .primary)
                    .fixedSize()
            }
            // No lineLimit and no fixed widths: at accessibility sizes a clipped number is worse
            // than a taller row, and every one of these was truncating.
            .padding(.vertical, 7)
        }
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
            Text(detail).font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
        }
    }
}

// MARK: - The measurements

/// Recorded in Velocity Mode with GPS running alongside purely as ground truth. Truth is the
/// integral of GPS speed rather than the sum of fix-to-fix displacements, which accumulates
/// position scatter — on one 15 km journey the two differ by 35%.
enum VelocityMethodData {
    struct Journey: Identifiable {
        let id = UUID()
        let name: String
        let recordedM: Int
        let trueM: Int
        let avgKmh: Double
        var errorPercent: Double { 100.0 * Double(recordedM - trueM) / Double(trueM) }
    }
    struct SpeedBias: Identifiable { let id = UUID(); let band: String; let biasKmh: Double }
    struct Heading: Identifiable { let id = UUID(); let label: String; let degrees: Double; let afterFix: Bool }
    struct RampSplit: Identifiable {
        let id = UUID(); let name: String; let phase: String
        let recordedM: Int; let trueM: Int
        var errorPercent: Double { 100.0 * Double(recordedM - trueM) / Double(trueM) }
    }
    struct FlightPoint: Identifiable { let id = UUID(); let point: String; let errorPercent: Double }
    /// Motorcycle, phone in a trouser pocket: mean estimated speed within each band of real
    /// speed. Kept as a pair rather than an error, because the point is that one moves and the
    /// other does not.
    struct PocketBand: Identifiable {
        let id = UUID(); let band: String
        let realKmh: Double; let estimatedKmh: Double
    }

    static let journeys: [Journey] = [
        .init(name: "Open road, 25 min",  recordedM: 14994, trueM: 14445, avgKmh: 43.2),
        .init(name: "Suburban, 12 min",   recordedM: 3793,  trueM: 3678,  avgKmh: 28.5),
        .init(name: "Motorcycle, 20 min", recordedM: 6181,  trueM: 5118,  avgKmh: 35.0),
        .init(name: "City, 15 min",       recordedM: 3363,  trueM: 2801,  avgKmh: 21.0),
        .init(name: "City, 12 min",       recordedM: 5741,  trueM: 4720,  avgKmh: 28.7),
        .init(name: "Car park, 11 min",   recordedM: 2762,  trueM: 2207,  avgKmh: 19.7),
        .init(name: "Car park, 8 min",    recordedM: 2548,  trueM: 1616,  avgKmh: 20.2),
        .init(name: "Car park, 4 min",    recordedM: 1755,  trueM: 1086,  avgKmh: 18.7)
    ]

    static let speedBias: [SpeedBias] = [
        .init(band: "2–10", biasKmh: 1.0), .init(band: "10–20", biasKmh: 1.4),
        .init(band: "20–35", biasKmh: 1.7), .init(band: "35–55", biasKmh: 0.8)
    ]

    static let heading: [Heading] = [
        .init(label: "15 km", degrees: 24.9, afterFix: false),
        .init(label: "1.6 km", degrees: 35.8, afterFix: false),
        .init(label: "Basement", degrees: 0.8, afterFix: true),
        .init(label: "Basement", degrees: 1.3, afterFix: true),
        .init(label: "City", degrees: 1.0, afterFix: true),
        .init(label: "Car park", degrees: 2.1, afterFix: true)
    ]

    /// The same two car-park journeys, split by the ramp detector.
    static let rampSplit: [RampSplit] = [
        .init(name: "Car park, 4 min", phase: "ramp", recordedM: 267, trueM: 67),
        .init(name: "Car park, 4 min", phase: "road", recordedM: 1488, trueM: 1018),
        .init(name: "Car park, 8 min", phase: "ramp", recordedM: 618, trueM: 229),
        .init(name: "Car park, 8 min", phase: "road", recordedM: 1930, trueM: 1387)
    ]

    /// 19.1 minutes, 1146 ticks at 1 Hz, Velocity Mode on for 1143 of them.
    static let pocket: [PocketBand] = [
        .init(band: "0–2",   realKmh: 1.0,  estimatedKmh: 36.2),
        .init(band: "2–10",  realKmh: 5.6,  estimatedKmh: 54.4),
        .init(band: "10–25", realKmh: 17.0, estimatedKmh: 57.8),
        .init(band: "25–45", realKmh: 34.0, estimatedKmh: 55.5),
        .init(band: "45–70", realKmh: 54.0, estimatedKmh: 49.8)
    ]

    static let flight: [FlightPoint] = [
        .init(point: "At the gate", errorPercent: -82),
        .init(point: "Before takeoff", errorPercent: -87),
        .init(point: "60 s into climb", errorPercent: -31),
        .init(point: "At cruise", errorPercent: -34)
    ]
}

// MARK: - Text fallbacks, used when the type is too large for a chart

private struct PocketTable: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(VelocityMethodData.pocket) { b in
                HStack {
                    Text("\(b.band) km/h").font(.caption)
                    Spacer()
                    Text("real \(b.realKmh, specifier: "%.0f")").font(.caption).foregroundStyle(.secondary)
                    Text("est \(b.estimatedKmh, specifier: "%.0f")").font(.caption).foregroundStyle(.red)
                        .frame(width: 62, alignment: .trailing)
                }
                .padding(.vertical, 5)
                Divider()
            }
        }
    }
}

private struct BiasTable: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(VelocityMethodData.speedBias.enumerated()), id: \.element.id) { i, b in
                if i > 0 { Divider() }
                HStack {
                    Text("\(b.band) km/h").font(.caption)
                    Spacer(minLength: 8)
                    Text(String(format: "+%.1f km/h", b.biasKmh))
                        .font(.system(.caption, design: .monospaced))
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct HeadingTable: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(VelocityMethodData.heading.enumerated()), id: \.element.id) { i, h in
                if i > 0 { Divider() }
                HStack {
                    Text(h.label).font(.caption)
                    Text(h.afterFix ? "offset learned" : "offset unlearned")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(String(format: "%.1f°", h.degrees))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(h.afterFix ? .green : .red)
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct FlightTable: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(VelocityMethodData.flight.enumerated()), id: \.element.id) { i, f in
                if i > 0 { Divider() }
                HStack {
                    Text(f.point).font(.caption)
                    Spacer(minLength: 8)
                    Text(String(format: "%.0f%%", f.errorPercent))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
                }
                .padding(.vertical, 6)
            }
        }
    }
}
