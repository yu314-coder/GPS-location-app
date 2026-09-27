import SwiftUI
import Charts

/// How Velocity Mode works, and how well — written for the person using it.
///
/// Every number here is the newest version re-run on recorded sensor data and compared with GPS
/// recorded at the same moment, used only as the answer key: the numbers in the paper
/// (paper/velocity_mode.tex), which this page must match. Where the method fails it says so with a
/// magnitude.
struct VelocityMethodView: View {
    /// AT ACCESSIBILITY TEXT SIZES A CHART IS WORSE THAN NO CHART.
    ///
    /// When a label grows and the plot does not, the label lands on top of its own bar — measured
    /// at accessibility-medium, where a journey name had its bar drawn straight through it. The
    /// tables carry every number the charts do, so above xxxLarge the charts step aside rather
    /// than overlap.
    @Environment(\.dynamicTypeSize) private var typeSize
    private var chartsFit: Bool { typeSize <= .xxxLarge }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    intro.id("intro")
                    overview.id("overview")
                    stageOne
                    stageTwo
                    stageThree
                    stageFour
                    distanceResults.id("road")
                    speedResults.id("speed")
                    directionResults.id("heading")
                    basement.id("basement")
                    flight.id("flight")
                    limits.id("limits")
                }
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
                without it — speed from how the vehicle shakes, direction from the gyroscope, \
                accelerometer and magnetometer, and position projected forward from a single \
                starting fix.
                """)
                .font(.callout)
                Divider()
                Text("Only the first point of the route comes from GPS. Every point after it, and every direction, is dead-reckoned.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - At a glance

    private var overview: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "At a glance",
                              subtitle: "every recording, split by what was moving") { EmptyView() }
                Text("""
                Every recording was replayed through the newest version from its raw sensor data, \
                with GPS recorded alongside and used only as the answer key.
                """)
                .font(.callout)
                VStack(spacing: 0) {
                    ForEach(Array(VelocityMethodData.overview.enumerated()), id: \.element.id) { i, o in
                        if i > 0 { Divider() }
                        OverviewRow(o: o)
                    }
                }
            }
        }
    }

    // MARK: - Method

    private var stageOne: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "1 · Vibration into a fingerprint",
                              subtitle: "50 Hz accelerometer → 11 numbers") { EmptyView() }
                Text("""
                Road and engine vibration carry speed, but not in any single property. What works \
                is the whole spectrum. Every second, the last five seconds of up-and-down \
                acceleration (256 readings) are windowed and transformed:
                """)
                .font(.callout)
                Equation("eq_window")
                Equation("eq_fft")
                Text("Energy is summed into nine log-spaced bands at 0.4, 0.8, 1.6, 2.5, 4, 6, 9, 13, 18 and 24 Hz:")
                    .font(.callout)
                Equation("eq_band")
                Text("Two measures of the overall strength complete the fingerprint:").font(.callout)
                Equation("eq_tail")
                Text("""
                Eleven numbers a second. A vehicle shakes differently at different speeds, and \
                the fingerprint captures that without assuming how.
                """)
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var stageTwo: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "2 · Fingerprint into speed",
                              subtitle: "the phone's own trips, or a built-in network") { EmptyView() }
                Text("""
                Whenever GPS supplies a speed, the phone stores the fingerprint with it, keeping up \
                to 4,000. In Velocity Mode those examples join the store only when the workout \
                ends, so the route being drawn never uses them. Without GPS it averages the 12 \
                stored fingerprints closest to the current one, nearer ones counting more:
                """)
                .font(.callout)
                Equation("eq_dist")
                Equation("eq_knn")
                Text("If even the closest is far away, it gives no answer rather than a guess:")
                    .font(.callout)
                Equation("eq_reject")
                Text("""
                Averaging pulls every answer toward the middle, so a correction learned from the \
                stored examples stretches the answers back out. A new phone has no examples, so \
                until it holds 3,000 it uses a small network trained on recorded trips and shipped \
                with the app: on recordings it had never seen, 9.1 km/h average error on a \
                motorcycle and 6.7 in a car, against 9.0 and 7.0 for a full store.

                A stopped vehicle is recognised from the absence of shaking, not from the speed \
                model, which would read an idling engine as a crawl. A hand on the phone shakes \
                it, so while the phone is being handled the speed may fall but not rise.
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
                Turn angle comes from the gyroscope, accurate over seconds. Absolute direction comes \
                from the phone's orientation, read along whichever edge of the phone lies closest to \
                level: with the phone head-down in a trouser pocket the built-in heading scattered \
                by about 49° a minute, this one by about 1°. In a car the heading drifts slowly \
                with the gyroscope's bias, so the drift is measured while the vehicle is stopped \
                and the phone still, and taken off; and while the field looks like Earth's, the \
                magnetometer is read directly to correct where the heading started.
                """)
                .font(.callout)
                Equation("eq_heading")
                Text("""
                β is the carry offset: the angle between where the phone points and where the \
                vehicle travels. It is learned with no GPS, from the vehicle's own turns: the push \
                toward the inside of a curve is speed times turn rate, and where it points, relative \
                to the phone, says which way is forward. Right and left turns are averaged apart so \
                braking into corners cancels, and a turn counts only if it explains at least a \
                tenth of the push. Walking uses the back-and-forth of the steps instead. No GPS \
                reaches the direction: not the first heading, not the angle.
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
                When the learned angle moves by 3° or more, the saved route is redrawn with it, at \
                most every 10 seconds. Distance is withheld on a car-park ramp: climbing steadily \
                while turning continuously the same way, which a road does not do.
                """)
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Distance

    private var distanceResults: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Distance against GPS",
                              subtitle: "the newest version, re-run on every recording") { EmptyView() }
                Text("""
                Every recording was replayed through the current method from its raw sensor data, \
                with GPS recorded alongside and used only as the answer key. The distance counted, \
                as a share of what GPS measured:
                """)
                .font(.callout)
                if chartsFit {
                // The GPS line goes under the bars and each label inside its own bar: every bar ends
                // within a few percent of 100, so labels beside the bars sat on the line.
                Chart {
                    RuleMark(x: .value("GPS", 100))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    ForEach(VelocityMethodData.distance) { c in
                        BarMark(x: .value("Counted", 100 + c.errorPercent), y: .value("Travel", c.name))
                            .foregroundStyle(by: .value("Travel", c.name))
                            .annotation(position: .overlay, alignment: .trailing) {
                                Text(String(format: "%+.1f%%", c.errorPercent))
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                    .padding(.trailing, 4)
                            }
                    }
                }
                .chartForegroundStyleScale(VelocityMethodData.travelColors)
                .chartLegend(.hidden)
                .chartXScale(domain: 0...125)
                .chartXAxisLabel("distance counted, % of GPS (dashed)")
                .chartXAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { AxisValueLabel() } }
                .chartYAxis { AxisMarks(position: .leading) { AxisValueLabel() } }
                .frame(height: 170)
                }

                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(VelocityMethodData.distance.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider() }
                        JourneyRow(name: c.name,
                                   recorded: Self.km(c.appKm),
                                   truth: Self.km(c.gpsKm),
                                   error: String(format: "%+.1f%%", c.errorPercent),
                                   detail: c.detail,
                                   emphasise: abs(c.errorPercent) >= 10)
                    }
                }
                Text("""
                Journey by journey the spread is wider: 82% of motorcycle journeys and 62% of car \
                journeys came within 20% of GPS. On foot, 7% long in the first minutes after a ride \
                and 7% short at other times.
                """)
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private static func km(_ v: Double) -> String {
        String(format: v < 10 ? "%.2f\u{00A0}km" : "%.1f\u{00A0}km", v)
    }

    // MARK: - Speed

    private var speedResults: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Speed, band by band",
                              subtitle: "each half-minute of riding against GPS") { EmptyView() }
                Text("""
                In a car the middle reading is within about 2 km/h of GPS from 10 to 60 km/h, and \
                reads low above that. On a motorcycle, with the phone in a trouser pocket, the range \
                is squeezed: slow riding reads fast and fast riding reads slow. When a fingerprint \
                could belong to several speeds, the average lands in the middle.
                """)
                .font(.callout)
                if chartsFit {
                Chart {
                    ForEach([0.0, 80.0], id: \.self) { v in
                        LineMark(x: .value("GPS", v), y: .value("App", v),
                                 series: .value("Line", "Same as GPS"))
                            .foregroundStyle(by: .value("Line", "Same as GPS"))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    ForEach(VelocityMethodData.speedBands.filter(\.plotted)) { b in
                        LineMark(x: .value("GPS", b.motorcycleGPS), y: .value("App", b.motorcycleApp),
                                 series: .value("Line", "Motorcycle"))
                            .foregroundStyle(by: .value("Line", "Motorcycle"))
                            .symbol(.circle)
                        LineMark(x: .value("GPS", b.carGPS), y: .value("App", b.carApp),
                                 series: .value("Line", "Car"))
                            .foregroundStyle(by: .value("Line", "Car"))
                            .symbol(.square)
                    }
                }
                .chartForegroundStyleScale([
                    "Motorcycle": AppTheme.distance,
                    "Car": AppTheme.pace,
                    "Same as GPS": Color.primary.opacity(0.35)
                ])
                .chartXScale(domain: 0...80)
                .chartYScale(domain: 0...80)
                .chartXAxisLabel("GPS, km/h")
                .chartYAxisLabel("the app, km/h")
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 260)
                }
                Divider()
                SpeedBandTable()
                Text("""
                The table gives the app's middle reading over GPS's, in each band of GPS speed; \
                above 80 km/h there are too few half-minutes to plot (3 on a motorcycle). Average \
                error 9.0 km/h on a motorcycle (818 half-minutes) and 7.0 in a car (747). On foot, \
                about 5.0 km/h where GPS measured 4.6.
                """)
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Direction

    private var directionResults: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Direction against GPS",
                              subtitle: "graded every second, no GPS used") { EmptyView() }
                Text("""
                Each second the app's direction of travel is compared with the way GPS moved over \
                the surrounding half-minute (ten seconds for the plane). The share of seconds \
                within 30°:
                """)
                .font(.callout)
                if chartsFit {
                Chart(VelocityMethodData.direction) { d in
                    BarMark(x: .value("Travel", d.name), y: .value("Within 30°", d.within30))
                        .foregroundStyle(by: .value("Travel", d.name))
                        .annotation(position: .top) {
                            Text("\(d.within30)%").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartForegroundStyleScale(VelocityMethodData.travelColors)
                .chartLegend(.hidden)
                .chartYScale(domain: 0...110)
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
                .frame(height: 180)
                } else {
                    DirectionTable()
                }
                Text("""
                Median error 17° on a motorcycle, 16° in a car, and 10° on foot and in the air. \
                Whole routes, laid over the GPS track from the shared start: the median route was \
                turned 11° on a motorcycle (41 routes) and 16° in a car (28), and 85% and 79% came \
                within 30°.

                In cars, measuring the drift at stops took the seconds within 30° from 65% to 71%, \
                averaging right and left turns apart to 78%, and the clean-field magnetometer to 81%.
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
                              subtitle: "where GPS is wrong too") { EmptyView() }
                Text("""
                A car crawling up a concrete spiral shakes as hard as one doing 40 km/h on a road, \
                and shaking is all the speed model has. So distance is withheld where the barometer \
                shows a sustained climb above 0.08 m/s and the gyroscope shows more than 150° of \
                same-direction turning over 30 seconds. A helical ramp does both; a hill or a \
                junction does only one.
                """)
                .font(.callout)
                Text("""
                The test has fired once on an ordinary road, losing about 115 m. And GPS is no \
                answer key underground: on five car journeys it kept claiming 10 m accuracy for \
                positions it did not have, frozen while parked and wandering on the ramps. Those \
                stretches, found from the barometer, are left out of every number on this page.
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
                              subtitle: "the takeoff measured, then the flight engines") { EmptyView() }
                Text("""
                A 22.8-minute flight was recorded with GPS valid throughout, up to 706 km/h. \
                Replayed with no GPS at all, the distance each way of reading speed in the air \
                would have recorded:
                """)
                .font(.callout)
                if chartsFit {
                Chart(VelocityMethodData.flight) { f in
                    BarMark(x: .value("Error", f.errorPercent), y: .value("Point", f.point))
                        .foregroundStyle((abs(f.errorPercent) > 10 ? Color.red : Color.green).opacity(0.85))
                        .annotation(position: f.errorPercent < 0 ? .leading : .trailing) {
                            Text(String(format: "%+.0f%%", f.errorPercent))
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
                A smooth cabin reads as standing still, so the phone measures the takeoff itself for \
                two minutes from the still moment before the roll: 265 km/h forty seconds in, where \
                GPS measured 266. Holding the 317 km/h it reached misses the climb to 680.

                After the two minutes one of two flight engines takes over: a small neural network, \
                or a store of 4,000 examples answered like the ground store. Both were trained on 302 \
                airline flights from NASA's public DASHlink flight recorder data. Both read only what the \
                phone senses: minutes since the roll began and how the phone is tilted. Neither uses GPS. \
                On NASA flights they had never seen, the network came within 10% of the distance on 68% \
                of flights; holding the takeoff speed did on 7%. What they give is a typical airliner's \
                speed at that point of a flight, so wind or a different aircraft will move it. \
                Direction in the air: 11° median error.
                """)
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Where it goes wrong

    private var limits: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Where it goes wrong")
                Limitation("On a motorcycle, fast riding reads slow and slow riding reads fast.",
                           "Above 60 km/h the speed is under two-thirds of the true value; 10–20 km/h reads about 19. Over a journey the two partly cancel, but a mostly fast journey comes out short.")
                Limitation("The heading can start wrong and stay wrong.",
                           "When the magnetic field cannot be trusted for the whole drive, an error in where the heading started stays for the drive: 27 of 67 graded recordings were turned by more than 15° this way. Only a clean magnetometer reading can see it.")
                Limitation("The first minute of a ride.",
                           "Until the angle the phone sits at is learned from the turns, direction comes from the heading alone. The saved route is redrawn afterwards, but a very short ride may never learn the angle well.")
                Limitation("A short drive in slow traffic.",
                           "The angle is learned only while the speed reads above 14 km/h, so a short, slow drive rests on a few turns. On one ten-minute drive at a median 9 km/h, the speeds read on the day kept every graded second within 30°; replayed with a speed model rebuilt from the other journeys, a different handful of turns set the angle and only 9% were.")
                Limitation("A phone that moves.",
                           "A hand on the phone can lower the speed but not raise it, and a phone held in the hand keeps the last speed measured before it was picked up, so one picked up while slowing keeps that speed until it is still. A phone that shifts in a pocket turns the rest of the ride by about as much as it moved.")
                Limitation("Keep the phone away from magnets.",
                           "Beside a car's MagSafe charger the phone read up to 2,600 µT, fifty times Earth's field, yet reported its compass as well calibrated. The app ignores such a field, but then cannot correct the heading.")
                Limitation("A ride that is never recognised.",
                           "On one short ride Apple's motion classifier never said \u{201C}driving\u{201D} and the step counter took the engine for footsteps: 59% short.")
                Limitation("In an aircraft, the speed after the takeoff is a typical airliner's.",
                           "Learned from NASA flight data, not measured on this flight: a strong wind or a much faster or slower aircraft reads off. On NASA flights the middle 80% counted 91–118% of the distance.")
                Limitation("These numbers are one phone and one person.",
                           "75 motorcycle and car journeys (20 hours, 341 km that GPS could check), 45 straight stretches and seven walks on foot, and one flight, mostly in one city. Other people, phones and vehicles may behave differently, the built-in network most of all.")
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

/// One measured result: a name with its detail, the app's figure over GPS's, and the error.
///
/// Two lines rather than one. A single row could not hold a name and its detail beside four
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
                // The figures keep their width and the name wraps instead: "1.87 km" split over
                // two lines once the detail beside it grew long.
                VStack(alignment: .trailing, spacing: 1) {
                    Text(recorded).font(.system(.caption, design: .monospaced))
                    Text("GPS\u{00A0}\(truth)").font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
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

/// One kind of travel: what was recorded, then its three headline figures. The figures sit side by
/// side, their labels wrapping, and stack only at accessibility sizes. ViewThatFits chose per row,
/// so one row with a longer label stacked while the others did not.
private struct OverviewRow: View {
    let o: VelocityMethodData.Overview
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(VelocityMethodData.color(o.name)).frame(width: 10, height: 10)
                Text(o.name).font(.subheadline).fontWeight(.semibold)
            }
            Text(o.recorded).font(.caption).foregroundStyle(.secondary)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) { figures }
            } else {
                HStack(alignment: .top, spacing: 12) { figures }
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder private var figures: some View {
        Figure(value: o.distance, label: "distance vs GPS")
        Figure(value: o.speed, label: o.speedLabel)
        Figure(value: o.direction, label: "direction within 30°")
    }

    private struct Figure: View {
        let value: String
        let label: String
        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(.callout, design: .rounded)).fontWeight(.semibold)
                    .monospacedDigit().fixedSize()
                Text(label).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

/// The newest version re-run on every recording's raw sensor data, with GPS recorded at the same
/// moment used only as the answer key. These are the paper's numbers: the block between the
/// GENERATED markers is written by paper/app_numbers.py from paper/tables/*.tex, so the page and
/// the paper cannot drift apart. Re-run it whenever the tables change; do not edit the block by hand.
enum VelocityMethodData {
    /// One kind of travel at a glance.
    struct Overview: Identifiable {
        let id = UUID(); let name: String; let recorded: String
        let distance: String
        let speed: String; let speedLabel: String
        let direction: String
    }
    struct Distance: Identifiable {
        let id = UUID(); let name: String; let detail: String
        let appKm: Double; let gpsKm: Double
        /// As the paper reports it, from the unrounded totals.
        let errorPercent: Double
    }
    /// The middle GPS and app speeds in one band of GPS speed, km/h.
    struct SpeedBand: Identifiable {
        let id = UUID(); let band: String
        let motorcycleGPS: Double, motorcycleApp: Double
        let carGPS: Double, carApp: Double
        var plotted = true
    }
    struct Direction: Identifiable {
        let id = UUID(); let name: String; let graded: String
        let medianDegrees: Int; let within30: Int
    }
    struct FlightPoint: Identifiable { let id = UUID(); let point: String; let errorPercent: Double }

    /// One colour per kind of travel, the same as in the paper's figures.
    static func color(_ travel: String) -> Color {
        switch travel {
        case "Motorcycle": return AppTheme.distance
        case "Car": return AppTheme.pace
        case "Walking": return Color.teal
        case "Plane": return AppTheme.duration
        default: return Color.secondary
        }
    }
    static let travelColors: KeyValuePairs<String, Color> = [
        "Motorcycle": AppTheme.distance, "Car": AppTheme.pace,
        "Walking": Color.teal, "Plane": AppTheme.duration
    ]

    // BEGIN GENERATED (paper/app_numbers.py)
    static let overview: [Overview] = [
        .init(name: "Motorcycle", recorded: "39 recordings, 11.1 hours, 177 km checked by GPS; phone in a trouser pocket",
              distance: "−11.9%", speed: "9.0 km/h", speedLabel: "average speed error",
              direction: "74%"),
        .init(name: "Car", recorded: "36 recordings, 8.8 hours, 164 km checked by GPS; phone in a pocket, flat or in a mount",
              distance: "−1.0%", speed: "7.0 km/h", speedLabel: "average speed error",
              direction: "81%"),
        .init(name: "Walking", recorded: "45 straight stretches and 7 walks; phone in a pocket, distance counted by steps",
              distance: "+3.7%", speed: "5.0 km/h", speedLabel: "where GPS measured 4.6",
              direction: "93%"),
        .init(name: "Plane", recorded: "1 flight, 74 km; the takeoff measured, then the flight network",
              distance: "+2.8%", speed: "38 km/h", speedLabel: "speed error in the air",
              direction: "99%")
    ]

    static let distance: [Distance] = [
        .init(name: "Motorcycle", detail: "39 journeys, 82% within 20%",
              appKm: 155.5, gpsKm: 176.5, errorPercent: -11.9),
        .init(name: "Car", detail: "36 journeys, 62% within 20%",
              appKm: 162.9, gpsKm: 164.5, errorPercent: -1.0),
        .init(name: "Walking", detail: "45 straight stretches, counted by steps",
              appKm: 1.93, gpsKm: 1.87, errorPercent: 3.7),
        .init(name: "Plane", detail: "1 flight: takeoff, then the flight network",
              appKm: 76.1, gpsKm: 74.1, errorPercent: 2.8)
    ]

    static let speedBands: [SpeedBand] = [
        .init(band: "0–10", motorcycleGPS: 2.6, motorcycleApp: 2.6, carGPS: 2.7, carApp: 2.6),
        .init(band: "10–20", motorcycleGPS: 14.7, motorcycleApp: 18.8, carGPS: 15.2, carApp: 15.2),
        .init(band: "20–30", motorcycleGPS: 25.0, motorcycleApp: 26.6, carGPS: 25.1, carApp: 25.0),
        .init(band: "30–40", motorcycleGPS: 35.1, motorcycleApp: 30.2, carGPS: 35.1, carApp: 33.5),
        .init(band: "40–50", motorcycleGPS: 44.0, motorcycleApp: 34.6, carGPS: 43.7, carApp: 45.0),
        .init(band: "50–60", motorcycleGPS: 53.2, motorcycleApp: 40.3, carGPS: 54.6, carApp: 55.2),
        .init(band: "60–80", motorcycleGPS: 66.4, motorcycleApp: 39.9, carGPS: 68.9, carApp: 61.7),
        .init(band: "80+", motorcycleGPS: 98.4, motorcycleApp: 37.6, carGPS: 87.1, carApp: 71.1, plotted: false)
    ]

    static let direction: [Direction] = [
        .init(name: "Motorcycle", graded: "40 recordings", medianDegrees: 17, within30: 74),
        .init(name: "Car", graded: "26 recordings", medianDegrees: 16, within30: 81),
        .init(name: "Walking", graded: "7 walks", medianDegrees: 10, within30: 93),
        .init(name: "Plane", graded: "1 flight", medianDegrees: 10, within30: 99)
    ]

    /// The recorded flight replayed with no GPS through the app's own code.
    static let flight: [FlightPoint] = [
        .init(point: "Hold takeoff speed", errorPercent: -39),
        .init(point: "Flight network", errorPercent: 3),
        .init(point: "Flight store", errorPercent: -1)
    ]
    // END GENERATED
}

// MARK: - Tables, beside the charts or in place of them when the type is too large

private struct SpeedBandTable: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("GPS km/h").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("motorcycle").font(.caption2).foregroundStyle(.secondary)
                    .frame(minWidth: 84, alignment: .trailing)
                Text("car").font(.caption2).foregroundStyle(.secondary)
                    .frame(minWidth: 84, alignment: .trailing)
            }
            .padding(.bottom, 4)
            ForEach(VelocityMethodData.speedBands) { b in
                Divider()
                HStack {
                    Text(b.band).font(.caption)
                    Spacer(minLength: 8)
                    Text(String(format: "%.0f / %.0f", b.motorcycleApp, b.motorcycleGPS))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minWidth: 84, alignment: .trailing)
                    Text(String(format: "%.0f / %.0f", b.carApp, b.carGPS))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minWidth: 84, alignment: .trailing)
                }
                .padding(.vertical, 5)
            }
        }
    }
}

private struct DirectionTable: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(VelocityMethodData.direction.enumerated()), id: \.element.id) { i, d in
                if i > 0 { Divider() }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name).font(.caption).fontWeight(.medium)
                        Text("\(d.graded), median \(d.medianDegrees)°")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(d.within30)% within 30°")
                        .font(.system(.caption, design: .monospaced))
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
                    Text(String(format: "%+.0f%%", f.errorPercent))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(abs(f.errorPercent) > 10 ? Color.red : Color.green)
                }
                .padding(.vertical, 6)
            }
        }
    }
}
