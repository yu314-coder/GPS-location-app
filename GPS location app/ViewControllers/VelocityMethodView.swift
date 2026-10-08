import SwiftUI
import Charts

/// The paper's numbers, generated from its tables (see VelocityMethodData).
private typealias N = VelocityMethodData.Num

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
                with the app: on recordings it had never seen, \(N.NetMotoMae) km/h average error on a \
                motorcycle and \(N.NetCarMae) in a car, against \(N.MainMotoMae) and \(N.MainCarMae) for a full store. \
                The same network answers whenever the store declines, so the speed never waits for \
                GPS and never stalls while the vehicle moves.

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
                with the gyroscope's bias, so the drift is measured while the vehicle is stopped, \
                the phone still and the field reading like Earth's (30–60 µT), and taken off. \
                Where the heading started is corrected by the magnetometer, read directly, but only \
                from a field that proves it is Earth's: over a minute in which the phone turned at \
                least 30°, Earth's field stays put in the world, while a magnet in the car or beside \
                the phone turns with it. A minute whose field held within 8 µT while turning is \
                taken as north.
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
                Journey by journey the spread is wider: \(N.MotoWtwenty)% of motorcycle journeys and \(N.CarWtwenty)% of car \
                journeys came within 20% of GPS. On foot, \(N.WalkAfterTxt) in the first minutes after a ride \
                and \(N.WalkOtherTxt) at other times.
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
                In a car the middle reading is within about \(N.CarMidMax) km/h of GPS from 10 to 60 km/h, and \
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
                above 80 km/h there are too few half-minutes to plot. Average error \
                \(N.MotoMae) km/h on a motorcycle (\(N.MotoHalf) half-minutes) and \(N.CarMae) in a car (\(N.CarHalf)). \
                On foot, about \(N.WalkApp) km/h where GPS measured \(N.WalkGps).
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
                Median error \(N.MotoDirMed)° on a motorcycle, \(N.CarDirMed)° in a car, \(N.WalkDirMed)° on foot and \(N.PlaneDirMed)° on \
                the plane. Whole routes of at least 1 km, laid over the GPS track from the shared \
                start: the median route was turned \(N.MotoRtMed)° on a motorcycle (\(N.MotoRoutes) routes) and \
                \(N.CarRtMed)° in a car (\(N.CarRoutes)), and \(N.MotoRtWthirty)% and \(N.CarRtWthirty)% came within 30°.

                In cars, measuring the drift at stops took the seconds within 30° from \(N.AblCarSecA)% to \
                \(N.AblCarSecB)%, averaging right and left turns apart to \(N.AblCarSecC)%, the push check to \
                \(N.AblCarSecD)%, the clean-field magnetometer to \(N.AblCarSecE)%, counting drift only while \
                the field reads like Earth's to \(N.AblCarSecF)%, and taking north only from a field checked by \
                turning to \(N.AblCarSecG)%. Checked against GPS sample by sample, turn-checked north was \
                within 15° \(N.TurnSampFifteen)% of the time; the steady-field seconds used before, \(N.CleanSampFifteen)%.
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
                answer key underground: on \(N.CarParks) car journeys it kept claiming 10 m accuracy for \
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
                            Text(String(format: "%+.1f%%", f.errorPercent))
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
                Direction in the air: \(N.FlAir)° median error.
                """)
                .font(.caption2).foregroundStyle(.secondary)
                Divider()
                flightRoute
                flightSpeed
            }
        }
    }

    // MARK: - The flight, drawn

    /// The whole flight drawn from the first GPS point with nothing but what the phone senses, the
    /// same picture as the paper's figure of the whole flight and turned by the same arbitrary angle, so it shows how
    /// the drawing goes wrong without showing where it was recorded.
    private var flightRoute: some View {
        let s = VelocityMethodData.flightRouteStats
        return VStack(alignment: .leading, spacing: 8) {
            Text("The whole flight, drawn with no GPS after the first point").font(.subheadline).fontWeight(.semibold)
            if chartsFit {
                Chart {
                    ForEach(VelocityMethodData.flightRoute) { p in
                        LineMark(x: .value("km", p.x), y: .value("km", p.y), series: .value("Line", p.line))
                            .foregroundStyle(by: .value("Line", p.line))
                            .lineStyle(StrokeStyle(lineWidth: p.line == "GPS" ? 2.5 : 2,
                                                   dash: p.line == "Algorithm" ? [6, 4] : []))
                    }
                    PointMark(x: .value("km", 0), y: .value("km", 0))
                        .foregroundStyle(Color.green).symbolSize(60)
                        .annotation(position: .bottom, alignment: .leading) {
                            Text("start").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartForegroundStyleScale(VelocityMethodData.flightLines)
                .chartLegend(position: .top, alignment: .leading)
                .chartXScale(domain: -5...80)
                .chartYScale(domain: -12...30)
                .chartXAxisLabel("km")
                .aspectRatio(85.0 / 42.0, contentMode: .fit)
            }
            Text("""
            Turned by an arbitrary angle so it does not show where it was recorded. Both versions stay \
            within about a kilometre of GPS through the taxi and takeoff (median \(s.medianKm, specifier: "%.1f") km). \
            In the air the direction settles about \(Int(s.airOffsetDeg))° to one side of the track, and that, \
            more than the speed, carries the drawn ends \(s.neuralEndKm, specifier: "%.1f") km (neural) and \
            \(s.algorithmEndKm, specifier: "%.1f") km (algorithm) from where GPS ended: \(s.neuralKm, specifier: "%.1f") \
            and \(s.algorithmKm, specifier: "%.1f") km drawn, 74.1 by GPS.
            """)
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var flightSpeed: some View {
        let ph = VelocityMethodData.flightPhases
        return VStack(alignment: .leading, spacing: 8) {
            Text("Speed through the flight").font(.subheadline).fontWeight(.semibold)
            if chartsFit {
                Chart {
                    RectangleMark(xStart: .value("min", ph.airborneMinute), xEnd: .value("min", ph.enginesMinute))
                        .foregroundStyle(Color.blue.opacity(0.10))
                    ForEach(VelocityMethodData.flightSpeed) { p in
                        LineMark(x: .value("minute", p.minute), y: .value("km/h", p.kmh), series: .value("Line", p.line))
                            .foregroundStyle(by: .value("Line", p.line))
                            .lineStyle(StrokeStyle(lineWidth: p.line == "GPS" ? 2.2 : 1.6,
                                                   dash: p.line == "Algorithm" ? [5, 3] : []))
                    }
                }
                .chartForegroundStyleScale(VelocityMethodData.flightLines)
                .chartLegend(position: .top, alignment: .leading)
                .chartXAxisLabel("minutes from the start of the recording")
                .chartYAxisLabel("km/h")
                .frame(height: 210)
            }
            Text("""
            The shaded band is the measured takeoff; after it the flight engines take over. The neural \
            version reads about 50 km/h high early in the climb and matches GPS near the end; the \
            algorithm follows the same shape a little less smoothly.
            """)
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Where it goes wrong

    private var limits: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Where it goes wrong")
                Limitation("On a motorcycle, fast riding reads slow and slow riding reads fast.",
                           "Above 60 km/h the speed is under two-thirds of the true value; 10–20 km/h reads about \(N.MotoBandTenApp). Over a journey the two partly cancel, but a mostly fast journey comes out short.")
                Limitation("A constant turn over a whole drive.",
                           "Much of the remaining error is one angle that lasts the whole drive: \(N.TurnBig) of \(N.TurnN) graded recordings are turned by more than 15° on average. It comes from where the heading started and from the angle learned for the phone. On the car drive with a clean magnetic field, the magnetometer cut it from \(N.MagOffD)° to \(N.MagOffE)°.")
                Limitation("The first minute of a ride.",
                           "Until the angle the phone sits at is learned from the turns, direction comes from the heading alone. The saved route is redrawn afterwards, but a very short ride may never learn the angle well.")
                Limitation("A short drive in slow traffic.",
                           "The angle is learned only while the speed reads above 14 km/h, so a short, slow drive rests on a few turns. On one ten-minute drive at a median 9 km/h, the speeds read on the day kept \(N.SlowAppPct)% of graded seconds within 30°; replayed with a speed model rebuilt from the other journeys, a different handful of turns sets the angle each time that model changes, and over the last \(N.SlowReplayRuns) re-runs between \(N.SlowReplayLow)% and \(N.SlowReplayHigh)% were.")
                Limitation("A phone that moves.",
                           "A hand on the phone can lower the speed but not raise it, and a phone picked up while slowing keeps the speed it had when it was picked up. Held in the hand for a whole car drive, the phone read \(N.HandDist)% of the distance GPS measured, and \(N.HandFastApp) km/h where GPS said \(N.HandFastGps) above 50 km/h: the speed needs the phone resting in a pocket, flat or on a mount. A phone that shifts in a pocket turns the drawn route by about as much as it moved, until enough new turns have been learned.")
                Limitation("Keep the phone away from magnets.",
                           "Beside a car's MagSafe charger the phone read up to 2,600 µT, fifty times Earth's field, yet reported its compass as well calibrated. The app ignores such a field. On the drive with the charger there throughout, a few turning minutes still showed Earth's field and the seconds within 30° rose from \(N.MagSafeF)% to \(N.MagSafeG)%; a phone that never leaves such a field cannot be corrected.")
                Limitation("Walking with the phone in some pockets.",
                           "Each footfall can ring twice, and the echo a quarter of a second later counted as a step: on one walk after a ride, 2.5–2.75 steps a second against a rhythm of 1.85, and about twice the distance GPS saw. The app now finds the walking rhythm and refuses a peak that comes too soon. On \(N.EchoOver) of \(N.EchoN) graded stretches the count had run more than 15% fast; scaled by the count, walking would go from \(N.EchoNow)% to about \(N.EchoScaled)% of GPS. That is an estimate until walks recorded with the pedometer arrive.")
                Limitation("A ride that is never recognised.",
                           "On one short ride Apple's motion classifier never said \u{201C}driving\u{201D} and the step counter took the engine for footsteps: as recorded, the app counted 1.0 of 2.4 km.")
                Limitation("In an aircraft, the speed after the takeoff is a typical airliner's.",
                           "Learned from NASA flight data, not measured on this flight: a strong wind or a much faster or slower aircraft reads off. On NASA flights the middle 80% counted 91–118% of the distance.")
                Limitation("These numbers are one phone and one person.",
                           "\(N.Journeys) motorcycle and car journeys (\(N.Hours) hours, \(N.KmChecked) km that GPS could check), \(N.WalkStretches) straight stretches and \(N.Walks) walks on foot, and one flight, mostly in one city. Other people, phones and vehicles may behave differently, the built-in network most of all.")
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
    /// One point of a drawn route, km, in drawing order.
    struct RoutePoint: Identifiable { let id = UUID(); let line: String; let order: Int; let x: Double; let y: Double }
    struct SpeedPoint: Identifiable { let id = UUID(); let minute: Double; let line: String; let kmh: Double }
    /// GPS is the answer key, so it is drawn in the text colour; the two versions take the paper's colours.
    static let flightLines: KeyValuePairs<String, Color> = [
        "GPS": Color.primary, "Neural": AppTheme.duration, "Algorithm": AppTheme.pace
    ]

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
        .init(name: "Motorcycle", recorded: "52 recordings, 14.4 hours, 227 km checked by GPS; phone in a trouser pocket",
              distance: "−11.2%", speed: "9.0 km/h", speedLabel: "average speed error",
              direction: "76%"),
        .init(name: "Car", recorded: "52 recordings, 15.8 hours, 326 km checked by GPS; phone in a pocket, flat or in a mount",
              distance: "−3.2%", speed: "7.1 km/h", speedLabel: "average speed error",
              direction: "88%"),
        .init(name: "Walking", recorded: "103 straight stretches and 7 walks; phone in a pocket, distance counted by steps",
              distance: "+2.6%", speed: "5.1 km/h", speedLabel: "where GPS measured 4.6",
              direction: "93%"),
        .init(name: "Plane", recorded: "1 flight, 74 km; the takeoff measured, then the flight network",
              distance: "+2.9%", speed: "38 km/h", speedLabel: "speed error in the air",
              direction: "99%")
    ]

    static let distance: [Distance] = [
        .init(name: "Motorcycle", detail: "52 journeys, 75% within 20%",
              appKm: 201.7, gpsKm: 227.2, errorPercent: -11.2),
        .init(name: "Car", detail: "52 journeys, 76% within 20%",
              appKm: 315.1, gpsKm: 325.5, errorPercent: -3.2),
        .init(name: "Walking", detail: "103 straight stretches, counted by steps",
              appKm: 4.3, gpsKm: 4.19, errorPercent: 2.6),
        .init(name: "Plane", detail: "1 flight: takeoff, then the flight network",
              appKm: 76.2, gpsKm: 74.1, errorPercent: 2.9)
    ]

    static let speedBands: [SpeedBand] = [
        .init(band: "0–10", motorcycleGPS: 2.5, motorcycleApp: 2.1, carGPS: 2.7, carApp: 2.4),
        .init(band: "10–20", motorcycleGPS: 15.3, motorcycleApp: 19.9, carGPS: 15.0, carApp: 14.9),
        .init(band: "20–30", motorcycleGPS: 25.0, motorcycleApp: 27.2, carGPS: 25.2, carApp: 24.9),
        .init(band: "30–40", motorcycleGPS: 35.0, motorcycleApp: 31.5, carGPS: 35.0, carApp: 35.1),
        .init(band: "40–50", motorcycleGPS: 44.0, motorcycleApp: 35.1, carGPS: 44.4, carApp: 45.2),
        .init(band: "50–60", motorcycleGPS: 54.0, motorcycleApp: 37.6, carGPS: 54.3, carApp: 57.4),
        .init(band: "60–80", motorcycleGPS: 65.0, motorcycleApp: 37.2, carGPS: 68.5, carApp: 64.8),
        .init(band: "80+", motorcycleGPS: 98.4, motorcycleApp: 36.4, carGPS: 89.0, carApp: 56.1, plotted: false)
    ]

    static let direction: [Direction] = [
        .init(name: "Motorcycle", graded: "53 recordings", medianDegrees: 14, within30: 76),
        .init(name: "Car", graded: "43 recordings", medianDegrees: 13, within30: 88),
        .init(name: "Walking", graded: "7 walks", medianDegrees: 10, within30: 93),
        .init(name: "Plane", graded: "1 flight", medianDegrees: 12, within30: 99)
    ]

    /// The recorded flight replayed with no GPS through the app's own code.
    static let flight: [FlightPoint] = [
        .init(point: "Hold takeoff speed", errorPercent: -39.0),
        .init(point: "Flight network", errorPercent: 2.9),
        .init(point: "Flight store", errorPercent: -0.6)
    ]

    /// The recorded flight drawn with no GPS after the first point, turned by an arbitrary angle so it does
    /// not show where it was recorded (the paper's figure of the whole flight), km. Every 6 s.
    static let flightRoute: [RoutePoint] = [
        .init(line: "GPS", order: 0, x: -0.0, y: 0.0),
        .init(line: "GPS", order: 1, x: 0.0, y: -0.01),
        .init(line: "GPS", order: 2, x: 0.0, y: -0.02),
        .init(line: "GPS", order: 3, x: 0.0, y: -0.03),
        .init(line: "GPS", order: 4, x: 0.0, y: -0.04),
        .init(line: "GPS", order: 5, x: 0.0, y: -0.05),
        .init(line: "GPS", order: 6, x: 0.0, y: -0.05),
        .init(line: "GPS", order: 7, x: 0.0, y: -0.06),
        .init(line: "GPS", order: 8, x: 0.0, y: -0.07),
        .init(line: "GPS", order: 9, x: 0.0, y: -0.08),
        .init(line: "GPS", order: 10, x: 0.0, y: -0.09),
        .init(line: "GPS", order: 11, x: 0.0, y: -0.1),
        .init(line: "GPS", order: 12, x: 0.01, y: -0.11),
        .init(line: "GPS", order: 13, x: 0.01, y: -0.12),
        .init(line: "GPS", order: 14, x: 0.01, y: -0.12),
        .init(line: "GPS", order: 15, x: 0.0, y: -0.13),
        .init(line: "GPS", order: 16, x: 0.0, y: -0.14),
        .init(line: "GPS", order: 17, x: 0.0, y: -0.15),
        .init(line: "GPS", order: 18, x: 0.0, y: -0.15),
        .init(line: "GPS", order: 19, x: 0.0, y: -0.15),
        .init(line: "GPS", order: 20, x: 0.0, y: -0.15),
        .init(line: "GPS", order: 21, x: 0.0, y: -0.15),
        .init(line: "GPS", order: 22, x: 0.0, y: -0.15),
        .init(line: "GPS", order: 23, x: 0.0, y: -0.15),
        .init(line: "GPS", order: 24, x: 0.0, y: -0.15),
        .init(line: "GPS", order: 25, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 26, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 27, x: 0.0, y: -0.15),
        .init(line: "GPS", order: 28, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 29, x: 0.0, y: -0.15),
        .init(line: "GPS", order: 30, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 31, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 32, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 33, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 34, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 35, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 36, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 37, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 38, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 39, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 40, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 41, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 42, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 43, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 44, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 45, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 46, x: 0.01, y: -0.15),
        .init(line: "GPS", order: 47, x: 0.0, y: -0.12),
        .init(line: "GPS", order: 48, x: -0.0, y: -0.1),
        .init(line: "GPS", order: 49, x: -0.02, y: -0.08),
        .init(line: "GPS", order: 50, x: -0.06, y: -0.09),
        .init(line: "GPS", order: 51, x: -0.08, y: -0.09),
        .init(line: "GPS", order: 52, x: -0.11, y: -0.09),
        .init(line: "GPS", order: 53, x: -0.14, y: -0.09),
        .init(line: "GPS", order: 54, x: -0.17, y: -0.09),
        .init(line: "GPS", order: 55, x: -0.2, y: -0.1),
        .init(line: "GPS", order: 56, x: -0.21, y: -0.13),
        .init(line: "GPS", order: 57, x: -0.21, y: -0.15),
        .init(line: "GPS", order: 58, x: -0.21, y: -0.15),
        .init(line: "GPS", order: 59, x: -0.21, y: -0.15),
        .init(line: "GPS", order: 60, x: -0.21, y: -0.15),
        .init(line: "GPS", order: 61, x: -0.21, y: -0.15),
        .init(line: "GPS", order: 62, x: -0.21, y: -0.15),
        .init(line: "GPS", order: 63, x: -0.21, y: -0.17),
        .init(line: "GPS", order: 64, x: -0.21, y: -0.19),
        .init(line: "GPS", order: 65, x: -0.21, y: -0.21),
        .init(line: "GPS", order: 66, x: -0.21, y: -0.23),
        .init(line: "GPS", order: 67, x: -0.23, y: -0.25),
        .init(line: "GPS", order: 68, x: -0.26, y: -0.25),
        .init(line: "GPS", order: 69, x: -0.29, y: -0.24),
        .init(line: "GPS", order: 70, x: -0.34, y: -0.24),
        .init(line: "GPS", order: 71, x: -0.39, y: -0.24),
        .init(line: "GPS", order: 72, x: -0.43, y: -0.24),
        .init(line: "GPS", order: 73, x: -0.51, y: -0.24),
        .init(line: "GPS", order: 74, x: -0.5, y: -0.24),
        .init(line: "GPS", order: 75, x: -0.52, y: -0.24),
        .init(line: "GPS", order: 76, x: -0.54, y: -0.24),
        .init(line: "GPS", order: 77, x: -0.58, y: -0.24),
        .init(line: "GPS", order: 78, x: -0.61, y: -0.24),
        .init(line: "GPS", order: 79, x: -0.66, y: -0.24),
        .init(line: "GPS", order: 80, x: -0.71, y: -0.24),
        .init(line: "GPS", order: 81, x: -0.76, y: -0.24),
        .init(line: "GPS", order: 82, x: -0.82, y: -0.24),
        .init(line: "GPS", order: 83, x: -0.88, y: -0.24),
        .init(line: "GPS", order: 84, x: -0.94, y: -0.24),
        .init(line: "GPS", order: 85, x: -0.99, y: -0.24),
        .init(line: "GPS", order: 86, x: -1.05, y: -0.23),
        .init(line: "GPS", order: 87, x: -1.11, y: -0.23),
        .init(line: "GPS", order: 88, x: -1.18, y: -0.23),
        .init(line: "GPS", order: 89, x: -1.24, y: -0.23),
        .init(line: "GPS", order: 90, x: -1.3, y: -0.23),
        .init(line: "GPS", order: 91, x: -1.37, y: -0.23),
        .init(line: "GPS", order: 92, x: -1.43, y: -0.23),
        .init(line: "GPS", order: 93, x: -1.5, y: -0.23),
        .init(line: "GPS", order: 94, x: -1.57, y: -0.23),
        .init(line: "GPS", order: 95, x: -1.64, y: -0.23),
        .init(line: "GPS", order: 96, x: -1.7, y: -0.22),
        .init(line: "GPS", order: 97, x: -1.77, y: -0.22),
        .init(line: "GPS", order: 98, x: -1.84, y: -0.22),
        .init(line: "GPS", order: 99, x: -1.89, y: -0.22),
        .init(line: "GPS", order: 100, x: -1.92, y: -0.22),
        .init(line: "GPS", order: 101, x: -1.93, y: -0.22),
        .init(line: "GPS", order: 102, x: -1.93, y: -0.22),
        .init(line: "GPS", order: 103, x: -1.93, y: -0.22),
        .init(line: "GPS", order: 104, x: -1.93, y: -0.22),
        .init(line: "GPS", order: 105, x: -1.93, y: -0.22),
        .init(line: "GPS", order: 106, x: -1.93, y: -0.22),
        .init(line: "GPS", order: 107, x: -1.94, y: -0.22),
        .init(line: "GPS", order: 108, x: -1.96, y: -0.22),
        .init(line: "GPS", order: 109, x: -1.98, y: -0.21),
        .init(line: "GPS", order: 110, x: -2.0, y: -0.22),
        .init(line: "GPS", order: 111, x: -2.02, y: -0.24),
        .init(line: "GPS", order: 112, x: -2.02, y: -0.26),
        .init(line: "GPS", order: 113, x: -2.02, y: -0.26),
        .init(line: "GPS", order: 114, x: -2.02, y: -0.26),
        .init(line: "GPS", order: 115, x: -2.03, y: -0.27),
        .init(line: "GPS", order: 116, x: -2.03, y: -0.27),
        .init(line: "GPS", order: 117, x: -2.03, y: -0.27),
        .init(line: "GPS", order: 118, x: -2.03, y: -0.27),
        .init(line: "GPS", order: 119, x: -2.03, y: -0.27),
        .init(line: "GPS", order: 120, x: -2.03, y: -0.27),
        .init(line: "GPS", order: 121, x: -1.82, y: -0.24),
        .init(line: "GPS", order: 122, x: -2.02, y: -0.3),
        .init(line: "GPS", order: 123, x: -2.02, y: -0.32),
        .init(line: "GPS", order: 124, x: -2.02, y: -0.34),
        .init(line: "GPS", order: 125, x: -2.02, y: -0.36),
        .init(line: "GPS", order: 126, x: -2.02, y: -0.38),
        .init(line: "GPS", order: 127, x: -2.01, y: -0.4),
        .init(line: "GPS", order: 128, x: -1.98, y: -0.4),
        .init(line: "GPS", order: 129, x: -1.98, y: -0.4),
        .init(line: "GPS", order: 130, x: -1.98, y: -0.4),
        .init(line: "GPS", order: 131, x: -1.98, y: -0.4),
        .init(line: "GPS", order: 132, x: -1.98, y: -0.41),
        .init(line: "GPS", order: 133, x: -1.97, y: -0.4),
        .init(line: "GPS", order: 134, x: -1.93, y: -0.4),
        .init(line: "GPS", order: 135, x: -1.76, y: -0.38),
        .init(line: "GPS", order: 136, x: -1.53, y: -0.37),
        .init(line: "GPS", order: 137, x: -1.22, y: -0.37),
        .init(line: "GPS", order: 138, x: -0.82, y: -0.38),
        .init(line: "GPS", order: 139, x: -0.36, y: -0.39),
        .init(line: "GPS", order: 140, x: 0.16, y: -0.41),
        .init(line: "GPS", order: 141, x: 0.44, y: -0.42),
        .init(line: "GPS", order: 142, x: 1.85, y: -0.47),
        .init(line: "GPS", order: 143, x: 2.33, y: -0.45),
        .init(line: "GPS", order: 144, x: 2.86, y: -0.45),
        .init(line: "GPS", order: 145, x: 3.39, y: -0.45),
        .init(line: "GPS", order: 146, x: 3.91, y: -0.45),
        .init(line: "GPS", order: 147, x: 4.52, y: -0.53),
        .init(line: "GPS", order: 148, x: 4.95, y: -0.47),
        .init(line: "GPS", order: 149, x: 5.46, y: -0.5),
        .init(line: "GPS", order: 150, x: 5.98, y: -0.52),
        .init(line: "GPS", order: 151, x: 6.48, y: -0.6),
        .init(line: "GPS", order: 152, x: 6.99, y: -0.49),
        .init(line: "GPS", order: 153, x: 7.5, y: -0.4),
        .init(line: "GPS", order: 154, x: 8.02, y: -0.3),
        .init(line: "GPS", order: 155, x: 8.57, y: -0.2),
        .init(line: "GPS", order: 156, x: 9.08, y: 0.03),
        .init(line: "GPS", order: 157, x: 9.46, y: 0.12),
        .init(line: "GPS", order: 158, x: 10.25, y: 0.32),
        .init(line: "GPS", order: 159, x: 10.87, y: 0.47),
        .init(line: "GPS", order: 160, x: 11.52, y: 0.63),
        .init(line: "GPS", order: 161, x: 11.84, y: 0.72),
        .init(line: "GPS", order: 162, x: 13.02, y: 0.74),
        .init(line: "GPS", order: 163, x: 13.75, y: 0.9),
        .init(line: "GPS", order: 164, x: 14.51, y: 1.07),
        .init(line: "GPS", order: 165, x: 15.3, y: 1.18),
        .init(line: "GPS", order: 166, x: 16.09, y: 1.3),
        .init(line: "GPS", order: 167, x: 16.86, y: 1.42),
        .init(line: "GPS", order: 168, x: 17.62, y: 1.72),
        .init(line: "GPS", order: 169, x: 23.27, y: 2.84),
        .init(line: "GPS", order: 170, x: 24.09, y: 3.0),
        .init(line: "GPS", order: 171, x: 24.92, y: 3.16),
        .init(line: "GPS", order: 172, x: 25.74, y: 3.32),
        .init(line: "GPS", order: 173, x: 26.56, y: 3.49),
        .init(line: "GPS", order: 174, x: 27.38, y: 3.65),
        .init(line: "GPS", order: 175, x: 28.21, y: 3.82),
        .init(line: "GPS", order: 176, x: 29.04, y: 3.98),
        .init(line: "GPS", order: 177, x: 29.87, y: 4.15),
        .init(line: "GPS", order: 178, x: 30.71, y: 4.32),
        .init(line: "GPS", order: 179, x: 31.55, y: 4.49),
        .init(line: "GPS", order: 180, x: 32.38, y: 4.66),
        .init(line: "GPS", order: 181, x: 33.23, y: 4.84),
        .init(line: "GPS", order: 182, x: 34.1, y: 5.0),
        .init(line: "GPS", order: 183, x: 34.97, y: 5.19),
        .init(line: "GPS", order: 184, x: 35.87, y: 5.38),
        .init(line: "GPS", order: 185, x: 36.78, y: 5.57),
        .init(line: "GPS", order: 186, x: 37.72, y: 5.77),
        .init(line: "GPS", order: 187, x: 38.67, y: 5.96),
        .init(line: "GPS", order: 188, x: 39.48, y: 6.13),
        .init(line: "GPS", order: 189, x: 40.62, y: 6.36),
        .init(line: "GPS", order: 190, x: 41.62, y: 6.56),
        .init(line: "GPS", order: 191, x: 42.61, y: 6.77),
        .init(line: "GPS", order: 192, x: 43.45, y: 6.89),
        .init(line: "GPS", order: 193, x: 44.63, y: 7.05),
        .init(line: "GPS", order: 194, x: 45.64, y: 7.17),
        .init(line: "GPS", order: 195, x: 46.66, y: 7.29),
        .init(line: "GPS", order: 196, x: 47.17, y: 7.35),
        .init(line: "GPS", order: 197, x: 49.57, y: 7.63),
        .init(line: "GPS", order: 198, x: 50.6, y: 7.75),
        .init(line: "GPS", order: 199, x: 51.63, y: 7.87),
        .init(line: "GPS", order: 200, x: 52.68, y: 7.99),
        .init(line: "GPS", order: 201, x: 53.72, y: 8.11),
        .init(line: "GPS", order: 202, x: 54.78, y: 8.23),
        .init(line: "GPS", order: 203, x: 55.48, y: 8.31),
        .init(line: "GPS", order: 204, x: 56.91, y: 8.48),
        .init(line: "GPS", order: 205, x: 57.97, y: 8.6),
        .init(line: "GPS", order: 206, x: 59.05, y: 8.73),
        .init(line: "GPS", order: 207, x: 60.13, y: 8.85),
        .init(line: "GPS", order: 208, x: 61.21, y: 8.98),
        .init(line: "GPS", order: 209, x: 62.3, y: 9.1),
        .init(line: "GPS", order: 210, x: 63.38, y: 9.23),
        .init(line: "GPS", order: 211, x: 64.47, y: 9.36),
        .init(line: "GPS", order: 212, x: 65.56, y: 9.48),
        .init(line: "GPS", order: 213, x: 66.66, y: 9.6),
        .init(line: "GPS", order: 214, x: 67.76, y: 9.71),
        .init(line: "GPS", order: 215, x: 68.85, y: 9.82),
        .init(line: "GPS", order: 216, x: 69.96, y: 9.94),
        .init(line: "GPS", order: 217, x: 71.07, y: 10.06),
        .init(line: "GPS", order: 218, x: 72.18, y: 10.19),
        .init(line: "GPS", order: 219, x: 73.3, y: 10.31),
        .init(line: "GPS", order: 220, x: 73.86, y: 10.38),
        .init(line: "GPS", order: 221, x: 73.86, y: 10.38),
        .init(line: "Neural", order: 0, x: -0.0, y: 0.0),
        .init(line: "Neural", order: 1, x: -0.0, y: 0.0),
        .init(line: "Neural", order: 2, x: -0.0, y: 0.0),
        .init(line: "Neural", order: 3, x: 0.0, y: 0.0),
        .init(line: "Neural", order: 4, x: 0.0, y: 0.0),
        .init(line: "Neural", order: 5, x: 0.0, y: 0.0),
        .init(line: "Neural", order: 6, x: 0.0, y: 0.0),
        .init(line: "Neural", order: 7, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 8, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 9, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 10, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 11, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 12, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 13, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 14, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 15, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 16, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 17, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 18, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 19, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 20, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 21, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 22, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 23, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 24, x: -0.0, y: 0.01),
        .init(line: "Neural", order: 25, x: 0.0, y: 0.02),
        .init(line: "Neural", order: 26, x: 0.0, y: 0.03),
        .init(line: "Neural", order: 27, x: 0.0, y: 0.03),
        .init(line: "Neural", order: 28, x: 0.0, y: 0.04),
        .init(line: "Neural", order: 29, x: 0.0, y: 0.05),
        .init(line: "Neural", order: 30, x: 0.0, y: 0.05),
        .init(line: "Neural", order: 31, x: 0.01, y: 0.06),
        .init(line: "Neural", order: 32, x: 0.01, y: 0.07),
        .init(line: "Neural", order: 33, x: 0.03, y: 0.07),
        .init(line: "Neural", order: 34, x: 0.04, y: 0.08),
        .init(line: "Neural", order: 35, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 36, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 37, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 38, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 39, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 40, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 41, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 42, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 43, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 44, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 45, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 46, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 47, x: 0.05, y: 0.09),
        .init(line: "Neural", order: 48, x: 0.05, y: 0.1),
        .init(line: "Neural", order: 49, x: 0.03, y: 0.11),
        .init(line: "Neural", order: 50, x: 0.01, y: 0.12),
        .init(line: "Neural", order: 51, x: -0.01, y: 0.13),
        .init(line: "Neural", order: 52, x: -0.04, y: 0.14),
        .init(line: "Neural", order: 53, x: -0.06, y: 0.15),
        .init(line: "Neural", order: 54, x: -0.09, y: 0.15),
        .init(line: "Neural", order: 55, x: -0.11, y: 0.15),
        .init(line: "Neural", order: 56, x: -0.12, y: 0.13),
        .init(line: "Neural", order: 57, x: -0.12, y: 0.13),
        .init(line: "Neural", order: 58, x: -0.12, y: 0.13),
        .init(line: "Neural", order: 59, x: -0.12, y: 0.13),
        .init(line: "Neural", order: 60, x: -0.12, y: 0.13),
        .init(line: "Neural", order: 61, x: -0.12, y: 0.13),
        .init(line: "Neural", order: 62, x: -0.12, y: 0.13),
        .init(line: "Neural", order: 63, x: -0.12, y: 0.13),
        .init(line: "Neural", order: 64, x: -0.12, y: 0.13),
        .init(line: "Neural", order: 65, x: -0.13, y: 0.12),
        .init(line: "Neural", order: 66, x: -0.13, y: 0.1),
        .init(line: "Neural", order: 67, x: -0.14, y: 0.09),
        .init(line: "Neural", order: 68, x: -0.16, y: 0.08),
        .init(line: "Neural", order: 69, x: -0.18, y: 0.08),
        .init(line: "Neural", order: 70, x: -0.2, y: 0.08),
        .init(line: "Neural", order: 71, x: -0.25, y: 0.08),
        .init(line: "Neural", order: 72, x: -0.29, y: 0.07),
        .init(line: "Neural", order: 73, x: -0.32, y: 0.07),
        .init(line: "Neural", order: 74, x: -0.34, y: 0.07),
        .init(line: "Neural", order: 75, x: -0.35, y: 0.07),
        .init(line: "Neural", order: 76, x: -0.35, y: 0.07),
        .init(line: "Neural", order: 77, x: -0.36, y: 0.07),
        .init(line: "Neural", order: 78, x: -0.39, y: 0.07),
        .init(line: "Neural", order: 79, x: -0.43, y: 0.08),
        .init(line: "Neural", order: 80, x: -0.47, y: 0.08),
        .init(line: "Neural", order: 81, x: -0.51, y: 0.08),
        .init(line: "Neural", order: 82, x: -0.55, y: 0.09),
        .init(line: "Neural", order: 83, x: -0.57, y: 0.09),
        .init(line: "Neural", order: 84, x: -0.58, y: 0.09),
        .init(line: "Neural", order: 85, x: -0.6, y: 0.09),
        .init(line: "Neural", order: 86, x: -0.61, y: 0.09),
        .init(line: "Neural", order: 87, x: -0.61, y: 0.09),
        .init(line: "Neural", order: 88, x: -0.63, y: 0.09),
        .init(line: "Neural", order: 89, x: -0.66, y: 0.1),
        .init(line: "Neural", order: 90, x: -0.7, y: 0.11),
        .init(line: "Neural", order: 91, x: -0.74, y: 0.11),
        .init(line: "Neural", order: 92, x: -0.77, y: 0.12),
        .init(line: "Neural", order: 93, x: -0.82, y: 0.13),
        .init(line: "Neural", order: 94, x: -0.86, y: 0.14),
        .init(line: "Neural", order: 95, x: -0.9, y: 0.14),
        .init(line: "Neural", order: 96, x: -0.94, y: 0.15),
        .init(line: "Neural", order: 97, x: -0.99, y: 0.16),
        .init(line: "Neural", order: 98, x: -1.01, y: 0.16),
        .init(line: "Neural", order: 99, x: -1.04, y: 0.17),
        .init(line: "Neural", order: 100, x: -1.07, y: 0.17),
        .init(line: "Neural", order: 101, x: -1.07, y: 0.17),
        .init(line: "Neural", order: 102, x: -1.07, y: 0.17),
        .init(line: "Neural", order: 103, x: -1.07, y: 0.17),
        .init(line: "Neural", order: 104, x: -1.07, y: 0.17),
        .init(line: "Neural", order: 105, x: -1.07, y: 0.17),
        .init(line: "Neural", order: 106, x: -1.07, y: 0.17),
        .init(line: "Neural", order: 107, x: -1.07, y: 0.17),
        .init(line: "Neural", order: 108, x: -1.07, y: 0.17),
        .init(line: "Neural", order: 109, x: -1.07, y: 0.17),
        .init(line: "Neural", order: 110, x: -1.09, y: 0.17),
        .init(line: "Neural", order: 111, x: -1.09, y: 0.17),
        .init(line: "Neural", order: 112, x: -1.09, y: 0.17),
        .init(line: "Neural", order: 113, x: -1.09, y: 0.16),
        .init(line: "Neural", order: 114, x: -1.09, y: 0.16),
        .init(line: "Neural", order: 115, x: -1.09, y: 0.16),
        .init(line: "Neural", order: 116, x: -1.09, y: 0.16),
        .init(line: "Neural", order: 117, x: -1.09, y: 0.16),
        .init(line: "Neural", order: 118, x: -1.09, y: 0.16),
        .init(line: "Neural", order: 119, x: -1.09, y: 0.16),
        .init(line: "Neural", order: 120, x: -1.09, y: 0.16),
        .init(line: "Neural", order: 121, x: -1.09, y: 0.16),
        .init(line: "Neural", order: 122, x: -1.09, y: 0.16),
        .init(line: "Neural", order: 123, x: -1.1, y: 0.14),
        .init(line: "Neural", order: 124, x: -1.1, y: 0.13),
        .init(line: "Neural", order: 125, x: -1.1, y: 0.11),
        .init(line: "Neural", order: 126, x: -1.1, y: 0.1),
        .init(line: "Neural", order: 127, x: -1.1, y: 0.1),
        .init(line: "Neural", order: 128, x: -1.1, y: 0.1),
        .init(line: "Neural", order: 129, x: -1.1, y: 0.1),
        .init(line: "Neural", order: 130, x: -1.1, y: 0.1),
        .init(line: "Neural", order: 131, x: -1.1, y: 0.1),
        .init(line: "Neural", order: 132, x: -1.1, y: 0.1),
        .init(line: "Neural", order: 133, x: -1.09, y: 0.1),
        .init(line: "Neural", order: 134, x: -1.04, y: 0.1),
        .init(line: "Neural", order: 135, x: -0.98, y: 0.11),
        .init(line: "Neural", order: 136, x: -0.92, y: 0.12),
        .init(line: "Neural", order: 137, x: -0.86, y: 0.12),
        .init(line: "Neural", order: 138, x: -0.79, y: 0.13),
        .init(line: "Neural", order: 139, x: -0.72, y: 0.14),
        .init(line: "Neural", order: 140, x: -0.37, y: 0.2),
        .init(line: "Neural", order: 141, x: 0.14, y: 0.28),
        .init(line: "Neural", order: 142, x: 0.72, y: 0.38),
        .init(line: "Neural", order: 143, x: 1.21, y: 0.47),
        .init(line: "Neural", order: 144, x: 1.7, y: 0.61),
        .init(line: "Neural", order: 145, x: 2.18, y: 0.74),
        .init(line: "Neural", order: 146, x: 2.67, y: 0.87),
        .init(line: "Neural", order: 147, x: 3.16, y: 0.98),
        .init(line: "Neural", order: 148, x: 3.65, y: 1.03),
        .init(line: "Neural", order: 149, x: 4.14, y: 1.13),
        .init(line: "Neural", order: 150, x: 4.64, y: 1.25),
        .init(line: "Neural", order: 151, x: 5.18, y: 1.37),
        .init(line: "Neural", order: 152, x: 5.88, y: 1.6),
        .init(line: "Neural", order: 153, x: 6.58, y: 1.89),
        .init(line: "Neural", order: 154, x: 7.3, y: 2.15),
        .init(line: "Neural", order: 155, x: 8.03, y: 2.39),
        .init(line: "Neural", order: 156, x: 8.75, y: 2.67),
        .init(line: "Neural", order: 157, x: 9.48, y: 2.95),
        .init(line: "Neural", order: 158, x: 10.22, y: 3.23),
        .init(line: "Neural", order: 159, x: 10.96, y: 3.53),
        .init(line: "Neural", order: 160, x: 11.7, y: 3.84),
        .init(line: "Neural", order: 161, x: 12.44, y: 4.17),
        .init(line: "Neural", order: 162, x: 13.2, y: 4.49),
        .init(line: "Neural", order: 163, x: 13.96, y: 4.83),
        .init(line: "Neural", order: 164, x: 14.72, y: 5.18),
        .init(line: "Neural", order: 165, x: 15.48, y: 5.54),
        .init(line: "Neural", order: 166, x: 16.26, y: 5.88),
        .init(line: "Neural", order: 167, x: 17.06, y: 6.2),
        .init(line: "Neural", order: 168, x: 17.87, y: 6.51),
        .init(line: "Neural", order: 169, x: 18.82, y: 6.88),
        .init(line: "Neural", order: 170, x: 19.66, y: 7.24),
        .init(line: "Neural", order: 171, x: 20.5, y: 7.6),
        .init(line: "Neural", order: 172, x: 21.35, y: 7.96),
        .init(line: "Neural", order: 173, x: 22.2, y: 8.32),
        .init(line: "Neural", order: 174, x: 23.04, y: 8.7),
        .init(line: "Neural", order: 175, x: 23.89, y: 9.08),
        .init(line: "Neural", order: 176, x: 24.75, y: 9.45),
        .init(line: "Neural", order: 177, x: 25.61, y: 9.84),
        .init(line: "Neural", order: 178, x: 26.48, y: 10.21),
        .init(line: "Neural", order: 179, x: 27.35, y: 10.59),
        .init(line: "Neural", order: 180, x: 28.22, y: 10.98),
        .init(line: "Neural", order: 181, x: 29.09, y: 11.38),
        .init(line: "Neural", order: 182, x: 29.96, y: 11.78),
        .init(line: "Neural", order: 183, x: 30.84, y: 12.18),
        .init(line: "Neural", order: 184, x: 31.72, y: 12.59),
        .init(line: "Neural", order: 185, x: 32.6, y: 13.0),
        .init(line: "Neural", order: 186, x: 33.5, y: 13.42),
        .init(line: "Neural", order: 187, x: 34.41, y: 13.84),
        .init(line: "Neural", order: 188, x: 35.35, y: 14.27),
        .init(line: "Neural", order: 189, x: 36.29, y: 14.71),
        .init(line: "Neural", order: 190, x: 37.25, y: 15.14),
        .init(line: "Neural", order: 191, x: 38.2, y: 15.58),
        .init(line: "Neural", order: 192, x: 39.16, y: 16.0),
        .init(line: "Neural", order: 193, x: 40.14, y: 16.38),
        .init(line: "Neural", order: 194, x: 41.12, y: 16.77),
        .init(line: "Neural", order: 195, x: 42.11, y: 17.16),
        .init(line: "Neural", order: 196, x: 43.1, y: 17.54),
        .init(line: "Neural", order: 197, x: 44.26, y: 17.99),
        .init(line: "Neural", order: 198, x: 45.25, y: 18.39),
        .init(line: "Neural", order: 199, x: 46.24, y: 18.8),
        .init(line: "Neural", order: 200, x: 47.25, y: 19.2),
        .init(line: "Neural", order: 201, x: 48.26, y: 19.6),
        .init(line: "Neural", order: 202, x: 49.28, y: 20.01),
        .init(line: "Neural", order: 203, x: 50.29, y: 20.43),
        .init(line: "Neural", order: 204, x: 51.31, y: 20.85),
        .init(line: "Neural", order: 205, x: 52.33, y: 21.28),
        .init(line: "Neural", order: 206, x: 53.35, y: 21.71),
        .init(line: "Neural", order: 207, x: 54.37, y: 22.15),
        .init(line: "Neural", order: 208, x: 55.4, y: 22.59),
        .init(line: "Neural", order: 209, x: 56.42, y: 23.03),
        .init(line: "Neural", order: 210, x: 57.44, y: 23.48),
        .init(line: "Neural", order: 211, x: 58.47, y: 23.92),
        .init(line: "Neural", order: 212, x: 59.51, y: 24.35),
        .init(line: "Neural", order: 213, x: 60.54, y: 24.79),
        .init(line: "Neural", order: 214, x: 61.58, y: 25.23),
        .init(line: "Neural", order: 215, x: 62.61, y: 25.68),
        .init(line: "Neural", order: 216, x: 63.64, y: 26.14),
        .init(line: "Neural", order: 217, x: 64.67, y: 26.6),
        .init(line: "Neural", order: 218, x: 65.69, y: 27.06),
        .init(line: "Neural", order: 219, x: 66.72, y: 27.53),
        .init(line: "Neural", order: 220, x: 67.74, y: 28.01),
        .init(line: "Neural", order: 221, x: 68.07, y: 28.17),
        .init(line: "Algorithm", order: 0, x: -0.0, y: 0.0),
        .init(line: "Algorithm", order: 1, x: -0.0, y: 0.0),
        .init(line: "Algorithm", order: 2, x: -0.0, y: 0.0),
        .init(line: "Algorithm", order: 3, x: 0.0, y: 0.0),
        .init(line: "Algorithm", order: 4, x: 0.0, y: 0.0),
        .init(line: "Algorithm", order: 5, x: 0.0, y: 0.0),
        .init(line: "Algorithm", order: 6, x: 0.0, y: 0.0),
        .init(line: "Algorithm", order: 7, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 8, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 9, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 10, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 11, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 12, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 13, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 14, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 15, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 16, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 17, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 18, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 19, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 20, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 21, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 22, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 23, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 24, x: -0.0, y: 0.01),
        .init(line: "Algorithm", order: 25, x: 0.0, y: 0.02),
        .init(line: "Algorithm", order: 26, x: 0.0, y: 0.03),
        .init(line: "Algorithm", order: 27, x: 0.0, y: 0.03),
        .init(line: "Algorithm", order: 28, x: 0.0, y: 0.04),
        .init(line: "Algorithm", order: 29, x: 0.0, y: 0.05),
        .init(line: "Algorithm", order: 30, x: 0.0, y: 0.05),
        .init(line: "Algorithm", order: 31, x: 0.01, y: 0.06),
        .init(line: "Algorithm", order: 32, x: 0.01, y: 0.07),
        .init(line: "Algorithm", order: 33, x: 0.03, y: 0.07),
        .init(line: "Algorithm", order: 34, x: 0.04, y: 0.08),
        .init(line: "Algorithm", order: 35, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 36, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 37, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 38, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 39, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 40, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 41, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 42, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 43, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 44, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 45, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 46, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 47, x: 0.05, y: 0.09),
        .init(line: "Algorithm", order: 48, x: 0.05, y: 0.1),
        .init(line: "Algorithm", order: 49, x: 0.03, y: 0.11),
        .init(line: "Algorithm", order: 50, x: 0.01, y: 0.12),
        .init(line: "Algorithm", order: 51, x: -0.01, y: 0.13),
        .init(line: "Algorithm", order: 52, x: -0.04, y: 0.14),
        .init(line: "Algorithm", order: 53, x: -0.06, y: 0.15),
        .init(line: "Algorithm", order: 54, x: -0.09, y: 0.15),
        .init(line: "Algorithm", order: 55, x: -0.11, y: 0.15),
        .init(line: "Algorithm", order: 56, x: -0.12, y: 0.13),
        .init(line: "Algorithm", order: 57, x: -0.12, y: 0.13),
        .init(line: "Algorithm", order: 58, x: -0.12, y: 0.13),
        .init(line: "Algorithm", order: 59, x: -0.12, y: 0.13),
        .init(line: "Algorithm", order: 60, x: -0.12, y: 0.13),
        .init(line: "Algorithm", order: 61, x: -0.12, y: 0.13),
        .init(line: "Algorithm", order: 62, x: -0.12, y: 0.13),
        .init(line: "Algorithm", order: 63, x: -0.12, y: 0.13),
        .init(line: "Algorithm", order: 64, x: -0.12, y: 0.13),
        .init(line: "Algorithm", order: 65, x: -0.13, y: 0.12),
        .init(line: "Algorithm", order: 66, x: -0.13, y: 0.1),
        .init(line: "Algorithm", order: 67, x: -0.14, y: 0.09),
        .init(line: "Algorithm", order: 68, x: -0.16, y: 0.08),
        .init(line: "Algorithm", order: 69, x: -0.18, y: 0.08),
        .init(line: "Algorithm", order: 70, x: -0.2, y: 0.08),
        .init(line: "Algorithm", order: 71, x: -0.25, y: 0.08),
        .init(line: "Algorithm", order: 72, x: -0.29, y: 0.07),
        .init(line: "Algorithm", order: 73, x: -0.32, y: 0.07),
        .init(line: "Algorithm", order: 74, x: -0.34, y: 0.07),
        .init(line: "Algorithm", order: 75, x: -0.35, y: 0.07),
        .init(line: "Algorithm", order: 76, x: -0.35, y: 0.07),
        .init(line: "Algorithm", order: 77, x: -0.36, y: 0.07),
        .init(line: "Algorithm", order: 78, x: -0.39, y: 0.07),
        .init(line: "Algorithm", order: 79, x: -0.43, y: 0.08),
        .init(line: "Algorithm", order: 80, x: -0.47, y: 0.08),
        .init(line: "Algorithm", order: 81, x: -0.51, y: 0.08),
        .init(line: "Algorithm", order: 82, x: -0.55, y: 0.09),
        .init(line: "Algorithm", order: 83, x: -0.57, y: 0.09),
        .init(line: "Algorithm", order: 84, x: -0.58, y: 0.09),
        .init(line: "Algorithm", order: 85, x: -0.6, y: 0.09),
        .init(line: "Algorithm", order: 86, x: -0.61, y: 0.09),
        .init(line: "Algorithm", order: 87, x: -0.61, y: 0.09),
        .init(line: "Algorithm", order: 88, x: -0.63, y: 0.09),
        .init(line: "Algorithm", order: 89, x: -0.66, y: 0.1),
        .init(line: "Algorithm", order: 90, x: -0.7, y: 0.11),
        .init(line: "Algorithm", order: 91, x: -0.74, y: 0.11),
        .init(line: "Algorithm", order: 92, x: -0.77, y: 0.12),
        .init(line: "Algorithm", order: 93, x: -0.82, y: 0.13),
        .init(line: "Algorithm", order: 94, x: -0.86, y: 0.14),
        .init(line: "Algorithm", order: 95, x: -0.9, y: 0.14),
        .init(line: "Algorithm", order: 96, x: -0.94, y: 0.15),
        .init(line: "Algorithm", order: 97, x: -0.99, y: 0.16),
        .init(line: "Algorithm", order: 98, x: -1.01, y: 0.16),
        .init(line: "Algorithm", order: 99, x: -1.04, y: 0.17),
        .init(line: "Algorithm", order: 100, x: -1.07, y: 0.17),
        .init(line: "Algorithm", order: 101, x: -1.07, y: 0.17),
        .init(line: "Algorithm", order: 102, x: -1.07, y: 0.17),
        .init(line: "Algorithm", order: 103, x: -1.07, y: 0.17),
        .init(line: "Algorithm", order: 104, x: -1.07, y: 0.17),
        .init(line: "Algorithm", order: 105, x: -1.07, y: 0.17),
        .init(line: "Algorithm", order: 106, x: -1.07, y: 0.17),
        .init(line: "Algorithm", order: 107, x: -1.07, y: 0.17),
        .init(line: "Algorithm", order: 108, x: -1.07, y: 0.17),
        .init(line: "Algorithm", order: 109, x: -1.07, y: 0.17),
        .init(line: "Algorithm", order: 110, x: -1.09, y: 0.17),
        .init(line: "Algorithm", order: 111, x: -1.09, y: 0.17),
        .init(line: "Algorithm", order: 112, x: -1.09, y: 0.17),
        .init(line: "Algorithm", order: 113, x: -1.09, y: 0.16),
        .init(line: "Algorithm", order: 114, x: -1.09, y: 0.16),
        .init(line: "Algorithm", order: 115, x: -1.09, y: 0.16),
        .init(line: "Algorithm", order: 116, x: -1.09, y: 0.16),
        .init(line: "Algorithm", order: 117, x: -1.09, y: 0.16),
        .init(line: "Algorithm", order: 118, x: -1.09, y: 0.16),
        .init(line: "Algorithm", order: 119, x: -1.09, y: 0.16),
        .init(line: "Algorithm", order: 120, x: -1.09, y: 0.16),
        .init(line: "Algorithm", order: 121, x: -1.09, y: 0.16),
        .init(line: "Algorithm", order: 122, x: -1.09, y: 0.16),
        .init(line: "Algorithm", order: 123, x: -1.1, y: 0.14),
        .init(line: "Algorithm", order: 124, x: -1.1, y: 0.13),
        .init(line: "Algorithm", order: 125, x: -1.1, y: 0.11),
        .init(line: "Algorithm", order: 126, x: -1.1, y: 0.1),
        .init(line: "Algorithm", order: 127, x: -1.1, y: 0.1),
        .init(line: "Algorithm", order: 128, x: -1.1, y: 0.1),
        .init(line: "Algorithm", order: 129, x: -1.1, y: 0.1),
        .init(line: "Algorithm", order: 130, x: -1.1, y: 0.1),
        .init(line: "Algorithm", order: 131, x: -1.1, y: 0.1),
        .init(line: "Algorithm", order: 132, x: -1.1, y: 0.1),
        .init(line: "Algorithm", order: 133, x: -1.09, y: 0.1),
        .init(line: "Algorithm", order: 134, x: -1.04, y: 0.1),
        .init(line: "Algorithm", order: 135, x: -0.98, y: 0.11),
        .init(line: "Algorithm", order: 136, x: -0.92, y: 0.11),
        .init(line: "Algorithm", order: 137, x: -0.85, y: 0.12),
        .init(line: "Algorithm", order: 138, x: -0.79, y: 0.12),
        .init(line: "Algorithm", order: 139, x: -0.72, y: 0.13),
        .init(line: "Algorithm", order: 140, x: -0.37, y: 0.17),
        .init(line: "Algorithm", order: 141, x: 0.14, y: 0.24),
        .init(line: "Algorithm", order: 142, x: 0.72, y: 0.32),
        .init(line: "Algorithm", order: 143, x: 1.22, y: 0.4),
        .init(line: "Algorithm", order: 144, x: 1.71, y: 0.52),
        .init(line: "Algorithm", order: 145, x: 2.2, y: 0.64),
        .init(line: "Algorithm", order: 146, x: 2.7, y: 0.75),
        .init(line: "Algorithm", order: 147, x: 3.19, y: 0.84),
        .init(line: "Algorithm", order: 148, x: 3.68, y: 0.88),
        .init(line: "Algorithm", order: 149, x: 4.17, y: 0.96),
        .init(line: "Algorithm", order: 150, x: 4.67, y: 1.06),
        .init(line: "Algorithm", order: 151, x: 5.22, y: 1.17),
        .init(line: "Algorithm", order: 152, x: 5.86, y: 1.36),
        .init(line: "Algorithm", order: 153, x: 6.48, y: 1.59),
        .init(line: "Algorithm", order: 154, x: 7.1, y: 1.79),
        .init(line: "Algorithm", order: 155, x: 7.72, y: 1.98),
        .init(line: "Algorithm", order: 156, x: 8.36, y: 2.2),
        .init(line: "Algorithm", order: 157, x: 9.06, y: 2.45),
        .init(line: "Algorithm", order: 158, x: 9.8, y: 2.7),
        .init(line: "Algorithm", order: 159, x: 10.56, y: 2.98),
        .init(line: "Algorithm", order: 160, x: 11.33, y: 3.27),
        .init(line: "Algorithm", order: 161, x: 12.13, y: 3.59),
        .init(line: "Algorithm", order: 162, x: 12.92, y: 3.9),
        .init(line: "Algorithm", order: 163, x: 13.7, y: 4.2),
        .init(line: "Algorithm", order: 164, x: 14.46, y: 4.51),
        .init(line: "Algorithm", order: 165, x: 15.2, y: 4.83),
        .init(line: "Algorithm", order: 166, x: 15.94, y: 5.14),
        .init(line: "Algorithm", order: 167, x: 16.74, y: 5.45),
        .init(line: "Algorithm", order: 168, x: 17.59, y: 5.77),
        .init(line: "Algorithm", order: 169, x: 18.59, y: 6.15),
        .init(line: "Algorithm", order: 170, x: 19.45, y: 6.52),
        .init(line: "Algorithm", order: 171, x: 20.3, y: 6.88),
        .init(line: "Algorithm", order: 172, x: 21.16, y: 7.23),
        .init(line: "Algorithm", order: 173, x: 22.02, y: 7.59),
        .init(line: "Algorithm", order: 174, x: 22.87, y: 7.97),
        .init(line: "Algorithm", order: 175, x: 23.73, y: 8.35),
        .init(line: "Algorithm", order: 176, x: 24.59, y: 8.71),
        .init(line: "Algorithm", order: 177, x: 25.44, y: 9.09),
        .init(line: "Algorithm", order: 178, x: 26.31, y: 9.45),
        .init(line: "Algorithm", order: 179, x: 27.19, y: 9.83),
        .init(line: "Algorithm", order: 180, x: 28.08, y: 10.22),
        .init(line: "Algorithm", order: 181, x: 28.96, y: 10.63),
        .init(line: "Algorithm", order: 182, x: 29.83, y: 11.03),
        .init(line: "Algorithm", order: 183, x: 30.7, y: 11.42),
        .init(line: "Algorithm", order: 184, x: 31.57, y: 11.82),
        .init(line: "Algorithm", order: 185, x: 32.44, y: 12.21),
        .init(line: "Algorithm", order: 186, x: 33.3, y: 12.61),
        .init(line: "Algorithm", order: 187, x: 34.17, y: 13.01),
        .init(line: "Algorithm", order: 188, x: 35.07, y: 13.42),
        .init(line: "Algorithm", order: 189, x: 35.97, y: 13.83),
        .init(line: "Algorithm", order: 190, x: 36.87, y: 14.23),
        .init(line: "Algorithm", order: 191, x: 37.78, y: 14.64),
        .init(line: "Algorithm", order: 192, x: 38.68, y: 15.03),
        .init(line: "Algorithm", order: 193, x: 39.62, y: 15.38),
        .init(line: "Algorithm", order: 194, x: 40.54, y: 15.75),
        .init(line: "Algorithm", order: 195, x: 41.47, y: 16.11),
        .init(line: "Algorithm", order: 196, x: 42.4, y: 16.46),
        .init(line: "Algorithm", order: 197, x: 43.46, y: 16.87),
        .init(line: "Algorithm", order: 198, x: 44.38, y: 17.23),
        .init(line: "Algorithm", order: 199, x: 45.31, y: 17.6),
        .init(line: "Algorithm", order: 200, x: 46.26, y: 17.98),
        .init(line: "Algorithm", order: 201, x: 47.23, y: 18.35),
        .init(line: "Algorithm", order: 202, x: 48.2, y: 18.74),
        .init(line: "Algorithm", order: 203, x: 49.15, y: 19.14),
        .init(line: "Algorithm", order: 204, x: 50.11, y: 19.52),
        .init(line: "Algorithm", order: 205, x: 51.06, y: 19.91),
        .init(line: "Algorithm", order: 206, x: 52.03, y: 20.32),
        .init(line: "Algorithm", order: 207, x: 53.01, y: 20.73),
        .init(line: "Algorithm", order: 208, x: 53.99, y: 21.15),
        .init(line: "Algorithm", order: 209, x: 54.97, y: 21.57),
        .init(line: "Algorithm", order: 210, x: 55.93, y: 21.98),
        .init(line: "Algorithm", order: 211, x: 56.9, y: 22.39),
        .init(line: "Algorithm", order: 212, x: 57.88, y: 22.79),
        .init(line: "Algorithm", order: 213, x: 58.85, y: 23.2),
        .init(line: "Algorithm", order: 214, x: 59.82, y: 23.61),
        .init(line: "Algorithm", order: 215, x: 60.78, y: 24.02),
        .init(line: "Algorithm", order: 216, x: 61.73, y: 24.43),
        .init(line: "Algorithm", order: 217, x: 62.68, y: 24.85),
        .init(line: "Algorithm", order: 218, x: 63.65, y: 25.29),
        .init(line: "Algorithm", order: 219, x: 64.65, y: 25.74),
        .init(line: "Algorithm", order: 220, x: 65.65, y: 26.2),
        .init(line: "Algorithm", order: 221, x: 65.98, y: 26.35)
    ]
    static let flightTakeoff = (x: -0.11, y: -0.39)
    static let flightRouteStats = (neuralKm: 76.2, algorithmKm: 73.7, neuralEndKm: 18.7, algorithmEndKm: 17.9, medianKm: 0.9, airOffsetDeg: 14)

    /// Speed through the flight, km/h, every 8 s: GPS (the answer key), then the two versions.
    static let flightSpeed: [SpeedPoint] = [
        .init(minute: 0.0, line: "GPS", kmh: 6),
        .init(minute: 0.0, line: "Neural", kmh: 0),
        .init(minute: 0.0, line: "Algorithm", kmh: 0),
        .init(minute: 0.13, line: "GPS", kmh: 6),
        .init(minute: 0.13, line: "Neural", kmh: 0),
        .init(minute: 0.13, line: "Algorithm", kmh: 0),
        .init(minute: 0.27, line: "GPS", kmh: 6),
        .init(minute: 0.27, line: "Neural", kmh: 0),
        .init(minute: 0.27, line: "Algorithm", kmh: 0),
        .init(minute: 0.4, line: "GPS", kmh: 6),
        .init(minute: 0.4, line: "Neural", kmh: 0),
        .init(minute: 0.4, line: "Algorithm", kmh: 0),
        .init(minute: 0.53, line: "GPS", kmh: 5),
        .init(minute: 0.53, line: "Neural", kmh: 0),
        .init(minute: 0.53, line: "Algorithm", kmh: 0),
        .init(minute: 0.67, line: "GPS", kmh: 3),
        .init(minute: 0.67, line: "Neural", kmh: 1),
        .init(minute: 0.67, line: "Algorithm", kmh: 1),
        .init(minute: 0.8, line: "GPS", kmh: 6),
        .init(minute: 0.8, line: "Neural", kmh: 0),
        .init(minute: 0.8, line: "Algorithm", kmh: 0),
        .init(minute: 0.93, line: "GPS", kmh: 6),
        .init(minute: 0.93, line: "Neural", kmh: 0),
        .init(minute: 0.93, line: "Algorithm", kmh: 0),
        .init(minute: 1.07, line: "GPS", kmh: 5),
        .init(minute: 1.07, line: "Neural", kmh: 0),
        .init(minute: 1.07, line: "Algorithm", kmh: 0),
        .init(minute: 1.2, line: "GPS", kmh: 6),
        .init(minute: 1.2, line: "Neural", kmh: 0),
        .init(minute: 1.2, line: "Algorithm", kmh: 0),
        .init(minute: 1.33, line: "GPS", kmh: 6),
        .init(minute: 1.33, line: "Neural", kmh: 0),
        .init(minute: 1.33, line: "Algorithm", kmh: 0),
        .init(minute: 1.47, line: "GPS", kmh: 6),
        .init(minute: 1.47, line: "Neural", kmh: 0),
        .init(minute: 1.47, line: "Algorithm", kmh: 0),
        .init(minute: 1.6, line: "GPS", kmh: 5),
        .init(minute: 1.6, line: "Neural", kmh: 0),
        .init(minute: 1.6, line: "Algorithm", kmh: 0),
        .init(minute: 1.73, line: "GPS", kmh: 1),
        .init(minute: 1.73, line: "Neural", kmh: 0),
        .init(minute: 1.73, line: "Algorithm", kmh: 0),
        .init(minute: 1.87, line: "GPS", kmh: 0),
        .init(minute: 1.87, line: "Neural", kmh: 0),
        .init(minute: 1.87, line: "Algorithm", kmh: 0),
        .init(minute: 2.0, line: "GPS", kmh: 0),
        .init(minute: 2.0, line: "Neural", kmh: 0),
        .init(minute: 2.0, line: "Algorithm", kmh: 0),
        .init(minute: 2.13, line: "GPS", kmh: 0),
        .init(minute: 2.13, line: "Neural", kmh: 0),
        .init(minute: 2.13, line: "Algorithm", kmh: 0),
        .init(minute: 2.27, line: "GPS", kmh: 0),
        .init(minute: 2.27, line: "Neural", kmh: 0),
        .init(minute: 2.27, line: "Algorithm", kmh: 0),
        .init(minute: 2.4, line: "GPS", kmh: 0),
        .init(minute: 2.4, line: "Neural", kmh: 0),
        .init(minute: 2.4, line: "Algorithm", kmh: 0),
        .init(minute: 2.53, line: "GPS", kmh: 0),
        .init(minute: 2.53, line: "Neural", kmh: 11),
        .init(minute: 2.53, line: "Algorithm", kmh: 11),
        .init(minute: 2.67, line: "GPS", kmh: 0),
        .init(minute: 2.67, line: "Neural", kmh: 1),
        .init(minute: 2.67, line: "Algorithm", kmh: 1),
        .init(minute: 2.8, line: "GPS", kmh: 0),
        .init(minute: 2.8, line: "Neural", kmh: 4),
        .init(minute: 2.8, line: "Algorithm", kmh: 4),
        .init(minute: 2.93, line: "GPS", kmh: 0),
        .init(minute: 2.93, line: "Neural", kmh: 4),
        .init(minute: 2.93, line: "Algorithm", kmh: 4),
        .init(minute: 3.07, line: "GPS", kmh: 0),
        .init(minute: 3.07, line: "Neural", kmh: 10),
        .init(minute: 3.07, line: "Algorithm", kmh: 10),
        .init(minute: 3.2, line: "GPS", kmh: 0),
        .init(minute: 3.2, line: "Neural", kmh: 4),
        .init(minute: 3.2, line: "Algorithm", kmh: 4),
        .init(minute: 3.33, line: "GPS", kmh: 0),
        .init(minute: 3.33, line: "Neural", kmh: 4),
        .init(minute: 3.33, line: "Algorithm", kmh: 4),
        .init(minute: 3.47, line: "GPS", kmh: 0),
        .init(minute: 3.47, line: "Neural", kmh: 0),
        .init(minute: 3.47, line: "Algorithm", kmh: 0),
        .init(minute: 3.6, line: "GPS", kmh: 0),
        .init(minute: 3.6, line: "Neural", kmh: 0),
        .init(minute: 3.6, line: "Algorithm", kmh: 0),
        .init(minute: 3.73, line: "GPS", kmh: 0),
        .init(minute: 3.73, line: "Neural", kmh: 0),
        .init(minute: 3.73, line: "Algorithm", kmh: 0),
        .init(minute: 3.87, line: "GPS", kmh: 0),
        .init(minute: 3.87, line: "Neural", kmh: 0),
        .init(minute: 3.87, line: "Algorithm", kmh: 0),
        .init(minute: 4.0, line: "GPS", kmh: 0),
        .init(minute: 4.0, line: "Neural", kmh: 0),
        .init(minute: 4.0, line: "Algorithm", kmh: 0),
        .init(minute: 4.13, line: "GPS", kmh: 0),
        .init(minute: 4.13, line: "Neural", kmh: 0),
        .init(minute: 4.13, line: "Algorithm", kmh: 0),
        .init(minute: 4.27, line: "GPS", kmh: 0),
        .init(minute: 4.27, line: "Neural", kmh: 0),
        .init(minute: 4.27, line: "Algorithm", kmh: 0),
        .init(minute: 4.4, line: "GPS", kmh: 0),
        .init(minute: 4.4, line: "Neural", kmh: 0),
        .init(minute: 4.4, line: "Algorithm", kmh: 0),
        .init(minute: 4.53, line: "GPS", kmh: 0),
        .init(minute: 4.53, line: "Neural", kmh: 0),
        .init(minute: 4.53, line: "Algorithm", kmh: 0),
        .init(minute: 4.67, line: "GPS", kmh: 0),
        .init(minute: 4.67, line: "Neural", kmh: 1),
        .init(minute: 4.67, line: "Algorithm", kmh: 1),
        .init(minute: 4.8, line: "GPS", kmh: 16),
        .init(minute: 4.8, line: "Neural", kmh: 9),
        .init(minute: 4.8, line: "Algorithm", kmh: 9),
        .init(minute: 4.93, line: "GPS", kmh: 18),
        .init(minute: 4.93, line: "Neural", kmh: 15),
        .init(minute: 4.93, line: "Algorithm", kmh: 15),
        .init(minute: 5.07, line: "GPS", kmh: 17),
        .init(minute: 5.07, line: "Neural", kmh: 13),
        .init(minute: 5.07, line: "Algorithm", kmh: 13),
        .init(minute: 5.2, line: "GPS", kmh: 18),
        .init(minute: 5.2, line: "Neural", kmh: 13),
        .init(minute: 5.2, line: "Algorithm", kmh: 13),
        .init(minute: 5.33, line: "GPS", kmh: 18),
        .init(minute: 5.33, line: "Neural", kmh: 17),
        .init(minute: 5.33, line: "Algorithm", kmh: 17),
        .init(minute: 5.47, line: "GPS", kmh: 20),
        .init(minute: 5.47, line: "Neural", kmh: 15),
        .init(minute: 5.47, line: "Algorithm", kmh: 15),
        .init(minute: 5.6, line: "GPS", kmh: 15),
        .init(minute: 5.6, line: "Neural", kmh: 12),
        .init(minute: 5.6, line: "Algorithm", kmh: 12),
        .init(minute: 5.73, line: "GPS", kmh: 2),
        .init(minute: 5.73, line: "Neural", kmh: 0),
        .init(minute: 5.73, line: "Algorithm", kmh: 0),
        .init(minute: 5.87, line: "GPS", kmh: 0),
        .init(minute: 5.87, line: "Neural", kmh: 0),
        .init(minute: 5.87, line: "Algorithm", kmh: 0),
        .init(minute: 6.0, line: "GPS", kmh: 0),
        .init(minute: 6.0, line: "Neural", kmh: 0),
        .init(minute: 6.0, line: "Algorithm", kmh: 0),
        .init(minute: 6.13, line: "GPS", kmh: 0),
        .init(minute: 6.13, line: "Neural", kmh: 0),
        .init(minute: 6.13, line: "Algorithm", kmh: 0),
        .init(minute: 6.27, line: "GPS", kmh: 6),
        .init(minute: 6.27, line: "Neural", kmh: 0),
        .init(minute: 6.27, line: "Algorithm", kmh: 0),
        .init(minute: 6.4, line: "GPS", kmh: 12),
        .init(minute: 6.4, line: "Neural", kmh: 1),
        .init(minute: 6.4, line: "Algorithm", kmh: 1),
        .init(minute: 6.53, line: "GPS", kmh: 16),
        .init(minute: 6.53, line: "Neural", kmh: 10),
        .init(minute: 6.53, line: "Algorithm", kmh: 10),
        .init(minute: 6.67, line: "GPS", kmh: 17),
        .init(minute: 6.67, line: "Neural", kmh: 7),
        .init(minute: 6.67, line: "Algorithm", kmh: 7),
        .init(minute: 6.8, line: "GPS", kmh: 19),
        .init(minute: 6.8, line: "Neural", kmh: 11),
        .init(minute: 6.8, line: "Algorithm", kmh: 11),
        .init(minute: 6.93, line: "GPS", kmh: 28),
        .init(minute: 6.93, line: "Neural", kmh: 12),
        .init(minute: 6.93, line: "Algorithm", kmh: 12),
        .init(minute: 7.07, line: "GPS", kmh: 29),
        .init(minute: 7.07, line: "Neural", kmh: 24),
        .init(minute: 7.07, line: "Algorithm", kmh: 24),
        .init(minute: 7.2, line: "GPS", kmh: 27),
        .init(minute: 7.2, line: "Neural", kmh: 22),
        .init(minute: 7.2, line: "Algorithm", kmh: 22),
        .init(minute: 7.33, line: "GPS", kmh: 17),
        .init(minute: 7.33, line: "Neural", kmh: 15),
        .init(minute: 7.33, line: "Algorithm", kmh: 15),
        .init(minute: 7.47, line: "GPS", kmh: 14),
        .init(minute: 7.47, line: "Neural", kmh: 2),
        .init(minute: 7.47, line: "Algorithm", kmh: 2),
        .init(minute: 7.6, line: "GPS", kmh: 15),
        .init(minute: 7.6, line: "Neural", kmh: 1),
        .init(minute: 7.6, line: "Algorithm", kmh: 1),
        .init(minute: 7.73, line: "GPS", kmh: 20),
        .init(minute: 7.73, line: "Neural", kmh: 17),
        .init(minute: 7.73, line: "Algorithm", kmh: 17),
        .init(minute: 7.87, line: "GPS", kmh: 28),
        .init(minute: 7.87, line: "Neural", kmh: 22),
        .init(minute: 7.87, line: "Algorithm", kmh: 22),
        .init(minute: 8.0, line: "GPS", kmh: 33),
        .init(minute: 8.0, line: "Neural", kmh: 28),
        .init(minute: 8.0, line: "Algorithm", kmh: 28),
        .init(minute: 8.13, line: "GPS", kmh: 34),
        .init(minute: 8.13, line: "Neural", kmh: 27),
        .init(minute: 8.13, line: "Algorithm", kmh: 27),
        .init(minute: 8.27, line: "GPS", kmh: 35),
        .init(minute: 8.27, line: "Neural", kmh: 7),
        .init(minute: 8.27, line: "Algorithm", kmh: 7),
        .init(minute: 8.4, line: "GPS", kmh: 35),
        .init(minute: 8.4, line: "Neural", kmh: 4),
        .init(minute: 8.4, line: "Algorithm", kmh: 4),
        .init(minute: 8.53, line: "GPS", kmh: 37),
        .init(minute: 8.53, line: "Neural", kmh: 10),
        .init(minute: 8.53, line: "Algorithm", kmh: 10),
        .init(minute: 8.67, line: "GPS", kmh: 34),
        .init(minute: 8.67, line: "Neural", kmh: 3),
        .init(minute: 8.67, line: "Algorithm", kmh: 3),
        .init(minute: 8.8, line: "GPS", kmh: 37),
        .init(minute: 8.8, line: "Neural", kmh: 20),
        .init(minute: 8.8, line: "Algorithm", kmh: 20),
        .init(minute: 8.93, line: "GPS", kmh: 38),
        .init(minute: 8.93, line: "Neural", kmh: 29),
        .init(minute: 8.93, line: "Algorithm", kmh: 29),
        .init(minute: 9.07, line: "GPS", kmh: 41),
        .init(minute: 9.07, line: "Neural", kmh: 20),
        .init(minute: 9.07, line: "Algorithm", kmh: 20),
        .init(minute: 9.2, line: "GPS", kmh: 40),
        .init(minute: 9.2, line: "Neural", kmh: 27),
        .init(minute: 9.2, line: "Algorithm", kmh: 27),
        .init(minute: 9.33, line: "GPS", kmh: 40),
        .init(minute: 9.33, line: "Neural", kmh: 24),
        .init(minute: 9.33, line: "Algorithm", kmh: 24),
        .init(minute: 9.47, line: "GPS", kmh: 41),
        .init(minute: 9.47, line: "Neural", kmh: 22),
        .init(minute: 9.47, line: "Algorithm", kmh: 22),
        .init(minute: 9.6, line: "GPS", kmh: 41),
        .init(minute: 9.6, line: "Neural", kmh: 28),
        .init(minute: 9.6, line: "Algorithm", kmh: 28),
        .init(minute: 9.73, line: "GPS", kmh: 38),
        .init(minute: 9.73, line: "Neural", kmh: 15),
        .init(minute: 9.73, line: "Algorithm", kmh: 15),
        .init(minute: 9.87, line: "GPS", kmh: 32),
        .init(minute: 9.87, line: "Neural", kmh: 21),
        .init(minute: 9.87, line: "Algorithm", kmh: 21),
        .init(minute: 10.0, line: "GPS", kmh: 8),
        .init(minute: 10.0, line: "Neural", kmh: 7),
        .init(minute: 10.0, line: "Algorithm", kmh: 7),
        .init(minute: 10.13, line: "GPS", kmh: 0),
        .init(minute: 10.13, line: "Neural", kmh: 0),
        .init(minute: 10.13, line: "Algorithm", kmh: 0),
        .init(minute: 10.27, line: "GPS", kmh: 0),
        .init(minute: 10.27, line: "Neural", kmh: 0),
        .init(minute: 10.27, line: "Algorithm", kmh: 0),
        .init(minute: 10.4, line: "GPS", kmh: 0),
        .init(minute: 10.4, line: "Neural", kmh: 0),
        .init(minute: 10.4, line: "Algorithm", kmh: 0),
        .init(minute: 10.53, line: "GPS", kmh: 0),
        .init(minute: 10.53, line: "Neural", kmh: 0),
        .init(minute: 10.53, line: "Algorithm", kmh: 0),
        .init(minute: 10.67, line: "GPS", kmh: 8),
        .init(minute: 10.67, line: "Neural", kmh: 0),
        .init(minute: 10.67, line: "Algorithm", kmh: 0),
        .init(minute: 10.8, line: "GPS", kmh: 13),
        .init(minute: 10.8, line: "Neural", kmh: 1),
        .init(minute: 10.8, line: "Algorithm", kmh: 1),
        .init(minute: 10.93, line: "GPS", kmh: 16),
        .init(minute: 10.93, line: "Neural", kmh: 9),
        .init(minute: 10.93, line: "Algorithm", kmh: 9),
        .init(minute: 11.07, line: "GPS", kmh: 14),
        .init(minute: 11.07, line: "Neural", kmh: 0),
        .init(minute: 11.07, line: "Algorithm", kmh: 0),
        .init(minute: 11.2, line: "GPS", kmh: 8),
        .init(minute: 11.2, line: "Neural", kmh: 0),
        .init(minute: 11.2, line: "Algorithm", kmh: 0),
        .init(minute: 11.33, line: "GPS", kmh: 1),
        .init(minute: 11.33, line: "Neural", kmh: 0),
        .init(minute: 11.33, line: "Algorithm", kmh: 0),
        .init(minute: 11.47, line: "GPS", kmh: 0),
        .init(minute: 11.47, line: "Neural", kmh: 0),
        .init(minute: 11.47, line: "Algorithm", kmh: 0),
        .init(minute: 11.6, line: "GPS", kmh: 0),
        .init(minute: 11.6, line: "Neural", kmh: 0),
        .init(minute: 11.6, line: "Algorithm", kmh: 0),
        .init(minute: 11.73, line: "GPS", kmh: 0),
        .init(minute: 11.73, line: "Neural", kmh: 0),
        .init(minute: 11.73, line: "Algorithm", kmh: 0),
        .init(minute: 11.87, line: "GPS", kmh: 0),
        .init(minute: 11.87, line: "Neural", kmh: 0),
        .init(minute: 11.87, line: "Algorithm", kmh: 0),
        .init(minute: 12.0, line: "GPS", kmh: 0),
        .init(minute: 12.0, line: "Neural", kmh: 0),
        .init(minute: 12.0, line: "Algorithm", kmh: 0),
        .init(minute: 12.13, line: "GPS", kmh: 12),
        .init(minute: 12.13, line: "Neural", kmh: 3),
        .init(minute: 12.13, line: "Algorithm", kmh: 3),
        .init(minute: 12.27, line: "GPS", kmh: 13),
        .init(minute: 12.27, line: "Neural", kmh: 15),
        .init(minute: 12.27, line: "Algorithm", kmh: 15),
        .init(minute: 12.4, line: "GPS", kmh: 12),
        .init(minute: 12.4, line: "Neural", kmh: 4),
        .init(minute: 12.4, line: "Algorithm", kmh: 4),
        .init(minute: 12.53, line: "GPS", kmh: 13),
        .init(minute: 12.53, line: "Neural", kmh: 5),
        .init(minute: 12.53, line: "Algorithm", kmh: 5),
        .init(minute: 12.67, line: "GPS", kmh: 13),
        .init(minute: 12.67, line: "Neural", kmh: 6),
        .init(minute: 12.67, line: "Algorithm", kmh: 6),
        .init(minute: 12.8, line: "GPS", kmh: 7),
        .init(minute: 12.8, line: "Neural", kmh: 1),
        .init(minute: 12.8, line: "Algorithm", kmh: 1),
        .init(minute: 12.93, line: "GPS", kmh: 7),
        .init(minute: 12.93, line: "Neural", kmh: 0),
        .init(minute: 12.93, line: "Algorithm", kmh: 0),
        .init(minute: 13.07, line: "GPS", kmh: 1),
        .init(minute: 13.07, line: "Neural", kmh: 0),
        .init(minute: 13.07, line: "Algorithm", kmh: 0),
        .init(minute: 13.2, line: "GPS", kmh: 0),
        .init(minute: 13.2, line: "Neural", kmh: 0),
        .init(minute: 13.2, line: "Algorithm", kmh: 0),
        .init(minute: 13.33, line: "GPS", kmh: 42),
        .init(minute: 13.33, line: "Neural", kmh: 24),
        .init(minute: 13.33, line: "Algorithm", kmh: 24),
        .init(minute: 13.47, line: "GPS", kmh: 78),
        .init(minute: 13.47, line: "Neural", kmh: 38),
        .init(minute: 13.47, line: "Algorithm", kmh: 38),
        .init(minute: 13.6, line: "GPS", kmh: 160),
        .init(minute: 13.6, line: "Neural", kmh: 36),
        .init(minute: 13.6, line: "Algorithm", kmh: 36),
        .init(minute: 13.73, line: "GPS", kmh: 223),
        .init(minute: 13.73, line: "Neural", kmh: 43),
        .init(minute: 13.73, line: "Algorithm", kmh: 43),
        .init(minute: 13.87, line: "GPS", kmh: 273),
        .init(minute: 13.87, line: "Neural", kmh: 40),
        .init(minute: 13.87, line: "Algorithm", kmh: 40),
        .init(minute: 14.0, line: "GPS", kmh: 323),
        .init(minute: 14.0, line: "Neural", kmh: 308),
        .init(minute: 14.0, line: "Algorithm", kmh: 308),
        .init(minute: 14.23, line: "GPS", kmh: 339),
        .init(minute: 14.23, line: "Neural", kmh: 298),
        .init(minute: 14.23, line: "Algorithm", kmh: 298),
        .init(minute: 14.37, line: "GPS", kmh: 317),
        .init(minute: 14.37, line: "Neural", kmh: 305),
        .init(minute: 14.37, line: "Algorithm", kmh: 305),
        .init(minute: 14.5, line: "GPS", kmh: 318),
        .init(minute: 14.5, line: "Neural", kmh: 302),
        .init(minute: 14.5, line: "Algorithm", kmh: 302),
        .init(minute: 14.63, line: "GPS", kmh: 315),
        .init(minute: 14.63, line: "Neural", kmh: 303),
        .init(minute: 14.63, line: "Algorithm", kmh: 303),
        .init(minute: 14.77, line: "GPS", kmh: 322),
        .init(minute: 14.77, line: "Neural", kmh: 300),
        .init(minute: 14.77, line: "Algorithm", kmh: 300),
        .init(minute: 14.9, line: "GPS", kmh: 304),
        .init(minute: 14.9, line: "Neural", kmh: 297),
        .init(minute: 14.9, line: "Algorithm", kmh: 297),
        .init(minute: 15.03, line: "GPS", kmh: 308),
        .init(minute: 15.03, line: "Neural", kmh: 305),
        .init(minute: 15.03, line: "Algorithm", kmh: 305),
        .init(minute: 15.17, line: "GPS", kmh: 306),
        .init(minute: 15.17, line: "Neural", kmh: 319),
        .init(minute: 15.17, line: "Algorithm", kmh: 319),
        .init(minute: 15.3, line: "GPS", kmh: 304),
        .init(minute: 15.3, line: "Neural", kmh: 447),
        .init(minute: 15.3, line: "Algorithm", kmh: 396),
        .init(minute: 15.43, line: "GPS", kmh: 309),
        .init(minute: 15.43, line: "Neural", kmh: 457),
        .init(minute: 15.43, line: "Algorithm", kmh: 391),
        .init(minute: 15.57, line: "GPS", kmh: 319),
        .init(minute: 15.57, line: "Neural", kmh: 462),
        .init(minute: 15.57, line: "Algorithm", kmh: 390),
        .init(minute: 15.7, line: "GPS", kmh: 340),
        .init(minute: 15.7, line: "Neural", kmh: 467),
        .init(minute: 15.7, line: "Algorithm", kmh: 417),
        .init(minute: 15.83, line: "GPS", kmh: 364),
        .init(minute: 15.83, line: "Neural", kmh: 473),
        .init(minute: 15.83, line: "Algorithm", kmh: 463),
        .init(minute: 15.97, line: "GPS", kmh: 384),
        .init(minute: 15.97, line: "Neural", kmh: 478),
        .init(minute: 15.97, line: "Algorithm", kmh: 483),
        .init(minute: 16.1, line: "GPS", kmh: 406),
        .init(minute: 16.1, line: "Neural", kmh: 485),
        .init(minute: 16.1, line: "Algorithm", kmh: 505),
        .init(minute: 16.23, line: "GPS", kmh: 430),
        .init(minute: 16.23, line: "Neural", kmh: 493),
        .init(minute: 16.23, line: "Algorithm", kmh: 511),
        .init(minute: 16.37, line: "GPS", kmh: 452),
        .init(minute: 16.37, line: "Neural", kmh: 500),
        .init(minute: 16.37, line: "Algorithm", kmh: 500),
        .init(minute: 16.5, line: "GPS", kmh: 464),
        .init(minute: 16.5, line: "Neural", kmh: 505),
        .init(minute: 16.5, line: "Algorithm", kmh: 488),
        .init(minute: 16.63, line: "GPS", kmh: 483),
        .init(minute: 16.63, line: "Neural", kmh: 510),
        .init(minute: 16.63, line: "Algorithm", kmh: 472),
        .init(minute: 16.77, line: "GPS", kmh: 477),
        .init(minute: 16.77, line: "Neural", kmh: 515),
        .init(minute: 16.77, line: "Algorithm", kmh: 523),
        .init(minute: 16.9, line: "GPS", kmh: 485),
        .init(minute: 16.9, line: "Neural", kmh: 520),
        .init(minute: 16.9, line: "Algorithm", kmh: 545),
        .init(minute: 17.63, line: "GPS", kmh: 500),
        .init(minute: 17.63, line: "Neural", kmh: 546),
        .init(minute: 17.63, line: "Algorithm", kmh: 558),
        .init(minute: 17.77, line: "GPS", kmh: 503),
        .init(minute: 17.77, line: "Neural", kmh: 549),
        .init(minute: 17.77, line: "Algorithm", kmh: 558),
        .init(minute: 17.9, line: "GPS", kmh: 503),
        .init(minute: 17.9, line: "Neural", kmh: 553),
        .init(minute: 17.9, line: "Algorithm", kmh: 558),
        .init(minute: 18.03, line: "GPS", kmh: 504),
        .init(minute: 18.03, line: "Neural", kmh: 556),
        .init(minute: 18.03, line: "Algorithm", kmh: 561),
        .init(minute: 18.17, line: "GPS", kmh: 505),
        .init(minute: 18.17, line: "Neural", kmh: 560),
        .init(minute: 18.17, line: "Algorithm", kmh: 562),
        .init(minute: 18.3, line: "GPS", kmh: 507),
        .init(minute: 18.3, line: "Neural", kmh: 563),
        .init(minute: 18.3, line: "Algorithm", kmh: 560),
        .init(minute: 18.43, line: "GPS", kmh: 512),
        .init(minute: 18.43, line: "Neural", kmh: 566),
        .init(minute: 18.43, line: "Algorithm", kmh: 562),
        .init(minute: 18.57, line: "GPS", kmh: 512),
        .init(minute: 18.57, line: "Neural", kmh: 570),
        .init(minute: 18.57, line: "Algorithm", kmh: 576),
        .init(minute: 18.7, line: "GPS", kmh: 513),
        .init(minute: 18.7, line: "Neural", kmh: 573),
        .init(minute: 18.7, line: "Algorithm", kmh: 584),
        .init(minute: 18.83, line: "GPS", kmh: 529),
        .init(minute: 18.83, line: "Neural", kmh: 575),
        .init(minute: 18.83, line: "Algorithm", kmh: 574),
        .init(minute: 18.97, line: "GPS", kmh: 539),
        .init(minute: 18.97, line: "Neural", kmh: 579),
        .init(minute: 18.97, line: "Algorithm", kmh: 570),
        .init(minute: 19.1, line: "GPS", kmh: 554),
        .init(minute: 19.1, line: "Neural", kmh: 584),
        .init(minute: 19.1, line: "Algorithm", kmh: 581),
        .init(minute: 19.23, line: "GPS", kmh: 569),
        .init(minute: 19.23, line: "Neural", kmh: 592),
        .init(minute: 19.23, line: "Algorithm", kmh: 571),
        .init(minute: 19.37, line: "GPS", kmh: 583),
        .init(minute: 19.37, line: "Neural", kmh: 605),
        .init(minute: 19.37, line: "Algorithm", kmh: 571),
        .init(minute: 19.5, line: "GPS", kmh: 596),
        .init(minute: 19.5, line: "Neural", kmh: 622),
        .init(minute: 19.5, line: "Algorithm", kmh: 591),
        .init(minute: 19.63, line: "GPS", kmh: 606),
        .init(minute: 19.63, line: "Neural", kmh: 628),
        .init(minute: 19.63, line: "Algorithm", kmh: 596),
        .init(minute: 19.77, line: "GPS", kmh: 608),
        .init(minute: 19.77, line: "Neural", kmh: 632),
        .init(minute: 19.77, line: "Algorithm", kmh: 594),
        .init(minute: 19.9, line: "GPS", kmh: 608),
        .init(minute: 19.9, line: "Neural", kmh: 628),
        .init(minute: 19.9, line: "Algorithm", kmh: 596),
        .init(minute: 20.03, line: "GPS", kmh: 612),
        .init(minute: 20.03, line: "Neural", kmh: 632),
        .init(minute: 20.03, line: "Algorithm", kmh: 599),
        .init(minute: 20.17, line: "GPS", kmh: 619),
        .init(minute: 20.17, line: "Neural", kmh: 636),
        .init(minute: 20.17, line: "Algorithm", kmh: 600),
        .init(minute: 20.3, line: "GPS", kmh: 619),
        .init(minute: 20.3, line: "Neural", kmh: 638),
        .init(minute: 20.3, line: "Algorithm", kmh: 589),
        .init(minute: 20.52, line: "GPS", kmh: 621),
        .init(minute: 20.52, line: "Neural", kmh: 643),
        .init(minute: 20.52, line: "Algorithm", kmh: 588),
        .init(minute: 20.65, line: "GPS", kmh: 627),
        .init(minute: 20.65, line: "Neural", kmh: 646),
        .init(minute: 20.65, line: "Algorithm", kmh: 602),
        .init(minute: 20.78, line: "GPS", kmh: 633),
        .init(minute: 20.78, line: "Neural", kmh: 650),
        .init(minute: 20.78, line: "Algorithm", kmh: 620),
        .init(minute: 20.92, line: "GPS", kmh: 635),
        .init(minute: 20.92, line: "Neural", kmh: 657),
        .init(minute: 20.92, line: "Algorithm", kmh: 625),
        .init(minute: 21.05, line: "GPS", kmh: 641),
        .init(minute: 21.05, line: "Neural", kmh: 660),
        .init(minute: 21.05, line: "Algorithm", kmh: 623),
        .init(minute: 21.18, line: "GPS", kmh: 645),
        .init(minute: 21.18, line: "Neural", kmh: 663),
        .init(minute: 21.18, line: "Algorithm", kmh: 617),
        .init(minute: 21.32, line: "GPS", kmh: 647),
        .init(minute: 21.32, line: "Neural", kmh: 665),
        .init(minute: 21.32, line: "Algorithm", kmh: 627),
        .init(minute: 21.45, line: "GPS", kmh: 654),
        .init(minute: 21.45, line: "Neural", kmh: 668),
        .init(minute: 21.45, line: "Algorithm", kmh: 642),
        .init(minute: 21.58, line: "GPS", kmh: 658),
        .init(minute: 21.58, line: "Neural", kmh: 670),
        .init(minute: 21.58, line: "Algorithm", kmh: 641),
        .init(minute: 21.72, line: "GPS", kmh: 657),
        .init(minute: 21.72, line: "Neural", kmh: 670),
        .init(minute: 21.72, line: "Algorithm", kmh: 633),
        .init(minute: 21.85, line: "GPS", kmh: 657),
        .init(minute: 21.85, line: "Neural", kmh: 673),
        .init(minute: 21.85, line: "Algorithm", kmh: 632),
        .init(minute: 21.98, line: "GPS", kmh: 661),
        .init(minute: 21.98, line: "Neural", kmh: 674),
        .init(minute: 21.98, line: "Algorithm", kmh: 636),
        .init(minute: 22.12, line: "GPS", kmh: 662),
        .init(minute: 22.12, line: "Neural", kmh: 675),
        .init(minute: 22.12, line: "Algorithm", kmh: 629),
        .init(minute: 22.25, line: "GPS", kmh: 658),
        .init(minute: 22.25, line: "Neural", kmh: 677),
        .init(minute: 22.25, line: "Algorithm", kmh: 629),
        .init(minute: 22.38, line: "GPS", kmh: 668),
        .init(minute: 22.38, line: "Neural", kmh: 677),
        .init(minute: 22.38, line: "Algorithm", kmh: 625),
        .init(minute: 22.52, line: "GPS", kmh: 669),
        .init(minute: 22.52, line: "Neural", kmh: 675),
        .init(minute: 22.52, line: "Algorithm", kmh: 633),
        .init(minute: 22.65, line: "GPS", kmh: 674),
        .init(minute: 22.65, line: "Neural", kmh: 675),
        .init(minute: 22.65, line: "Algorithm", kmh: 660),
        .init(minute: 22.78, line: "GPS", kmh: 679),
        .init(minute: 22.78, line: "Neural", kmh: 674),
        .init(minute: 22.78, line: "Algorithm", kmh: 661)
    ]
    static let flightPhases = (airborneMinute: 13.95, enginesMinute: 15.2)

    /// Every data-dependent number the paper's text quotes (tables/numbers.tex), for the page's own text.
    enum Num {
        static let AblBigA = "11"
        static let AblBigC = "9"
        static let AblBigF = "9"
        static let AblBigG = "6"
        static let AblCarRtA = "65"
        static let AblCarRtC = "79"
        static let AblCarRtF = "81"
        static let AblCarRtG = "86"
        static let AblCarSecA = "66"
        static let AblCarSecB = "70"
        static let AblCarSecC = "72"
        static let AblCarSecD = "73"
        static let AblCarSecE = "76"
        static let AblCarSecF = "81"
        static let AblCarSecG = "88"
        static let AblFlA = "93"
        static let AblFlB = "99"
        static let AblGate = "+4"
        static let AblMag = "+3"
        static let AblMotoSpan = "2"
        static let AblPush = "+1"
        static let AblTurn = "+7"
        static let AppDownTxt = ", and the 47 seconds of one journey in which iOS had ended the app"
        static let BothAppKm = "517"
        static let BothGpsKm = "553"
        static let BothShort = "6.5"
        static let CarAppKm = "315"
        static let CarBandEightyApp = "56"
        static let CarBandEightyGps = "89"
        static let CarBandSixtyApp = "65"
        static let CarBandSixtyGps = "69"
        static let CarBandTenApp = "15"
        static let CarBandTenGps = "15"
        static let CarBandThirtyApp = "35"
        static let CarBandThirtyGps = "35"
        static let CarBandTwentyApp = "25"
        static let CarBandTwentyGps = "25"
        static let CarDirMed = "13"
        static let CarDirRec = "43"
        static let CarDist = "-3.2"
        static let CarDistTxt = "3.2% short"
        static let CarDrift = "17"
        static let CarGpsKm = "326"
        static let CarHalf = "1,326"
        static let CarHours = "15.8"
        static let CarMae = "7.1"
        static let CarMedJourneyTxt = "2.3% long"
        static let CarMidMax = "4"
        static let CarNinety = "35"
        static let CarParks = "10"
        static let CarRec = "52"
        static let CarRoutes = "43"
        static let CarRtBig = "2"
        static let CarRtBigShort = "1"
        static let CarRtMed = "14"
        static let CarRtWthirty = "86"
        static let CarSize = "0.97"
        static let CarWthirty = "88"
        static let CarWtwenty = "76"
        static let CleanSampFifteen = "65"
        static let CleanSampMed = "11"
        static let CleanSampN = "1761"
        static let CleanSampRecs = "21"
        static let CleanSampWorst = "171"
        static let EchoBetter = "44"
        static let EchoN = "103"
        static let EchoNow = "+2.6"
        static let EchoOver = "33"
        static let EchoScaled = "-4.5"
        static let EchoWorse = "10"
        static let EchoWorseTxt = "all but one of them already short, and that one within 1% of GPS"
        static let EchoWtwentyNow = "43"
        static let EchoWtwentyScaled = "55"
        static let FifthMagD = "100"
        static let FifthMagG = "99"
        static let FifthMagTurn = "169"
        static let FirstMagF = "85"
        static let FirstMagG = "95"
        static let FlAir = "14"
        static let FlEnd = "16"
        static let FlEndNet = "18.7"
        static let FlEndShare = "25"
        static let FlEndStore = "17.9"
        static let FlGround = "9"
        static let FlMainShare = "102.9"
        static let FlMissPush = "1"
        static let FlMissRunway = "11"
        static let FlMisses = "12"
        static let FlNetShare = "103.0"
        static let FlOffset = "14"
        static let FlRouteMed = "0.9"
        static let FlSpeedDiff = "3.5"
        static let FlWithin = "3"
        static let ForgetDeclHi = "44"
        static let ForgetDeclLo = "41"
        static let ForgetLiveA = "49"
        static let ForgetLiveB = "58"
        static let ForgetNetA = "89"
        static let ForgetNetB = "88"
        static let GpsFlightKm = "74.1"
        static let GpsModeTxt = "One car journey was recorded with the app measuring by GPS, so the app made no walking decisions in it; it was replayed as a car and, from the first step after the car stopped, as walking, as described when recorded, with GPS from every fix the phone logged."
        static let HandDist = "77"
        static let HandFastApp = "31"
        static let HandFastGps = "65"
        static let HandFlagged = "83"
        static let HandMae = "13.7"
        static let HandSteady = "66"
        static let HoldAirErr = "196"
        static let HoldKm = "45.2"
        static let HoldShare = "61"
        static let Hours = "30"
        static let Journeys = "104"
        static let KmChecked = "553"
        static let LongDriftEarth = "94"
        static let LongDriftEvery = "45"
        static let LongDriftNone = "88"
        static let LongDriveF = "94"
        static let LongDriveG = "94"
        static let LongDriveTurn = "0"
        static let MagCars = "19"
        static let MagMotos = "13"
        static let MagOffD = "34"
        static let MagOffE = "22"
        static let MagPooledF = "80"
        static let MagPooledG = "89"
        static let MagRecs = "33"
        static let MagRecsTurn = "26"
        static let MagSafeClean = "51"
        static let MagSafeF = "0"
        static let MagSafeG = "41"
        static let MagSafeTurn = "27"
        static let MagSafeTxt = "and with them the seconds within 30\\dg rose from 0% to 41%"
        static let MagWD = "19"
        static let MagWE = "89"
        static let MainCarMae = "7.1"
        static let MainCarShare = "96.8"
        static let MainMotoMae = "8.9"
        static let MainMotoShare = "88.9"
        static let MotoAppKm = "202"
        static let MotoBandEightyApp = "36"
        static let MotoBandEightyGps = "98"
        static let MotoBandSixtyApp = "37"
        static let MotoBandSixtyGps = "65"
        static let MotoBandTenApp = "20"
        static let MotoBandTenGps = "15"
        static let MotoBandThirtyApp = "31"
        static let MotoBandThirtyGps = "35"
        static let MotoBandTwentyApp = "27"
        static let MotoBandTwentyGps = "25"
        static let MotoDirMed = "14"
        static let MotoDirRec = "53"
        static let MotoDist = "-11.2"
        static let MotoDistTxt = "11% short"
        static let MotoDrift = "18"
        static let MotoFourClean = "13"
        static let MotoFourG = "90"
        static let MotoFourTurn = "0"
        static let MotoGpsKm = "227"
        static let MotoHalf = "1,062"
        static let MotoHours = "14.4"
        static let MotoMae = "9.0"
        static let MotoMagClean = "88"
        static let MotoMagD = "94"
        static let MotoMagF = "97"
        static let MotoMagG = "96"
        static let MotoMagN = "69"
        static let MotoMagTurn = "5"
        static let MotoMedJourneyTxt = "7.4% short"
        static let MotoMidMax = "17"
        static let MotoNinety = "54"
        static let MotoRec = "52"
        static let MotoRoutes = "54"
        static let MotoRtBig = "4"
        static let MotoRtBigShort = "3"
        static let MotoRtMed = "9"
        static let MotoRtWthirty = "89"
        static let MotoSize = "0.83"
        static let MotoThreeD = "82"
        static let MotoThreeG = "82"
        static let MotoTwoG = "28"
        static let MotoWthirty = "76"
        static let MotoWtwenty = "75"
        static let NetAirErr = "38"
        static let NetAll = "7.6"
        static let NetCarMae = "6.6"
        static let NetCarShare = "95.6"
        static let NetKm = "76.2"
        static let NetMotoMae = "8.9"
        static let NetMotoShare = "93.9"
        static let NetShare = "103"
        static let NetVsStore = "a little more accurate than"
        static let PlaneDirMed = "12"
        static let PlaneDist = "+2.9"
        static let PlaneWthirty = "99"
        static let RecDiff = "7"
        static let RecN = "12"
        static let SixthMagD = "86"
        static let SixthMagG = "83"
        static let SixthMagTurn = "152"
        static let SlowAppPct = "100"
        static let SlowGraded = "87"
        static let SlowReplayHigh = "43"
        static let SlowReplayLow = "26"
        static let SlowReplayPct = "41"
        static let SlowReplayRuns = "6"
        static let SlowReplayTxt = "over the last 6 re-runs, which differed only in the journeys added, between 26% and 43%"
        static let StepRideBig = "7"
        static let StepRideGps = "13.5"
        static let StepRideLive = "1.9"
        static let StepRideN = "25"
        static let StepRideWorst = "79"
        static let StoreAirErr = "37"
        static let StoreFourK = "8.1"
        static let StoreKm = "73.7"
        static let StoreShare = "99"
        static let StoreSixty = "9.5"
        static let StoreThousand = "8.3"
        static let StoreVsNet = "still a little behind"
        static let TaxiApp = "13"
        static let TaxiGps = "18"
        static let ThirdMagF = "79"
        static let ThirdMagG = "77"
        static let ThirdMagTurn = "7"
        static let TurnBig = "30"
        static let TurnFixed = "89"
        static let TurnMedFixed = "7.9"
        static let TurnMedNow = "13.4"
        static let TurnN = "96"
        static let TurnNow = "82"
        static let TurnSampFifteen = "83"
        static let TurnSampMed = "7"
        static let TurnSampN = "1125"
        static let TurnSampRecs = "19"
        static let TurnSampWorst = "68"
        static let WalkAfterTxt = "5% more"
        static let WalkApp = "5.1"
        static let WalkDirMed = "10"
        static let WalkDist = "+2.6"
        static let WalkDistTxt = "3% more"
        static let WalkGps = "4.6"
        static let WalkOtherTxt = "2% less"
        static let WalkShare = "100.2"
        static let WalkStretches = "103"
        static let WalkWthirty = "93"
        static let Walks = "7"
    }
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
                    Text(String(format: "%+.1f%%", f.errorPercent))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(abs(f.errorPercent) > 10 ? Color.red : Color.green)
                }
                .padding(.vertical, 6)
            }
        }
    }
}
