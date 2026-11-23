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
                // Lazy (build 160): the sections and their charts are built as they scroll in, not all on open.
                LazyVStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
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
                to 4,000: half from trips with the phone in a motorcycle rider's pocket, half from \
                every other trip, so a long week of driving cannot crowd out the bike. In Velocity \
                Mode those examples join the store only when the workout ends, so the route being \
                drawn never uses them. Once a trip shows which kind it is, it reads only its own \
                half. Without GPS it averages the 12 stored fingerprints closest to the current \
                one, nearer ones counting more:
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
                the phone still and the field reading like Earth's (30–60 µT), and taken off; a \
                drift measured faster than 3° a minute is not believed and not taken off. \
                Where the heading started is corrected by the magnetometer, read directly, but only \
                from a field that proves it is Earth's: over a minute in which the phone turned at \
                least 30°, Earth's field stays put in the world, while a magnet in the car or beside \
                the phone turns with it. A minute whose field held within 8 µT while turning, and \
                within 12 µT over the turning seconds themselves, is taken as north.
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
                // Laid out by hand (build 169): Swift Charts put each name above its bar, clear of
                // the axis, and the tick labels beside their grid lines rather than under them.
                BarRows(rows: VelocityMethodData.distance.map {
                            .init(name: $0.name, value: 100 + $0.errorPercent,
                                  label: Self.signed($0.errorPercent),
                                  color: VelocityMethodData.color($0.name))
                        },
                        domain: 110, ticks: [0, 25, 50, 75, 100], reference: 100,
                        axisLabel: "distance counted, % of GPS (dashed line); the plane against ADS-B")

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

    /// "+1.3%" / "−7.7%", with a real minus sign as in the overview.
    private static func signed(_ v: Double) -> String {
        String(format: "%+.1f%%", v).replacingOccurrences(of: "-", with: "\u{2212}")
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
                .centeredXLabels([0, 20, 40, 60, 80])
                .chartYAxis { AxisMarks(position: .leading, values: [0, 20, 40, 60, 80]) { AxisGridLine(); AxisTick(); AxisValueLabel() } }
                .chartYAxisLabel("the app, km/h")
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 260)
                }
                Divider()
                SpeedBandTable()
                Text("""
                The table gives the app's middle reading over GPS's, in each band of GPS speed; \
                the band above 80 km/h is in the table only. Average error \
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
                BarRows(rows: VelocityMethodData.direction.map {
                            .init(name: $0.name, value: Double($0.within30), label: "\($0.within30)%",
                                  color: VelocityMethodData.color($0.name))
                        },
                        domain: 100, ticks: [0, 25, 50, 75, 100], reference: nil,
                        axisLabel: "seconds within 30° of GPS, %")
                Text("""
                Median error \(N.MotoDirMed)° on a motorcycle, \(N.CarDirMed)° in a car, \(N.WalkDirMed)° on foot and \(N.PlaneDirMed)° on \
                the plane. Whole routes of at least 1 km, laid over the GPS track from the shared \
                start: the median route was turned \(N.MotoRtMed)° on a motorcycle (\(N.MotoRoutes) routes) and \
                \(N.CarRtMed)° in a car (\(N.CarRoutes)), and \(N.MotoRtWthirty)% and \(N.CarRtWthirty)% came within 30°.

                Built up one part at a time, the car seconds within 30° were \(N.AblCarSecA)% with the heading \
                and the angle from turns alone, \(N.AblCarSecB)% with drift measured at stops, \(N.AblCarSecC)% \
                with right and left turns averaged apart, \(N.AblCarSecD)% with the push check, \(N.AblCarSecE)% \
                with the clean-field magnetometer, \(N.AblCarSecF)% with drift counted only while the field \
                reads like Earth's, and \(N.AblCarSecG)% with north taken only from a field checked by turning. Checked against GPS sample by sample, turn-checked north was \
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
                              subtitle: "the takeoff measured, then the typical flight") { EmptyView() }
                Text("""
                Two four-hour airliner flights, one out and one back, were recorded on several devices \
                with no satellite fix in the air, and graded afterwards by each aircraft's public \
                ADS-B track; a 23-minute flight had GPS throughout. Replayed with no GPS at all, the \
                distance the app counts now, and the ways it replaced:
                """)
                .font(.callout)
                BarRows(rows: VelocityMethodData.flight.map { f in
                            .init(name: f.point, value: 100 + f.errorPercent,
                                  label: Self.signed(f.errorPercent),
                                  color: f.current ? AppTheme.duration : Color.secondary.opacity(0.55))
                        },
                        domain: 110, ticks: [0, 25, 50, 75, 100], reference: 100,
                        axisLabel: "distance counted, % of the real distance (dashed line); coloured = the app now, grey = earlier versions")
                Text("""
                A smooth cabin reads as standing still, so the phone measures the takeoff itself for \
                two minutes from the still moment before the roll: 265 km/h forty seconds in, where \
                GPS measured 266. Holding the 317 km/h it reached misses the climb to 680. A takeoff \
                counts only once the cabin's pressure has fallen 0.25 kPa, which it had 99 to 112 seconds \
                after the roll on all four real takeoffs; until then its distance waits, and without that \
                fall in two and a half minutes it is dropped. A phone carried from a parked car into a \
                lift once passed for a takeoff and would otherwise have added 3.9 km.

                After that the speed is the median of real airliners at the same point, from two sources \
                pooled: a day of the OpenSky Network's worldwide ADS-B data (1,194 jet takeoffs followed \
                to cruise and 1,079 descents) and NASA's 302 DASHlink flight recordings, whose \
                once-a-second data covers the takeoff roll and how long a plane stays faster or slower \
                than typical. On the clock are minutes since the takeoff roll, and, \
                once the cabin pressure has started down, minutes since the descent began. The cabin is \
                used for that timing only, never as an altitude. No tilt is read, so a phone that turns \
                over in a bag or moves in a hand reads the same, and a pause by iOS is made up afterwards. \
                The speed the takeoff measured is carried into the climb, most of it for two minutes and \
                a little for twenty. Neither GPS nor an aircraft speed is used. On flights it had never \
                seen it counted a median of 99% of the distance, within 10% on 72%; on the two four-hour \
                flights, 95% and \(VelocityMethodData.flightPhases.share)%; the earlier tilt-reading engines \
                (shown above) counted 39% on a phone in a bag. What it gives is a typical airliner's \
                speed, so wind or a faster or slower aircraft will move it. ADS-B data: OpenSky Network, \
                "Bringing up OpenSky: A large-scale ADS-B sensor network for research" (IPSN 2014).

                The direction in the air does not use the compass, which a cabin disturbs: it starts \
                from the takeoff roll's push, matched to a runway of the airport the phone was last \
                fixed at (OurAirports, public domain), and follows the gyroscope through felt turns \
                and gentle steady ones, leaving out its drift and any moment the phone is in a hand. \
                iOS quietly shortens a smooth turn on a phone lying still, so each turn is also measured \
                by how far the magnetic field turned around the phone, and the field's angle is used when \
                it was steady and the gyroscope fell short. Direction in the air: \(N.FlAir)° median \
                error on three flights graded by ADS-B and GPS (\(N.FlAirOld)° in build 123).
                """)
                .font(.caption2).foregroundStyle(.secondary)
                Divider()
                flightRoute
                flightSpeed
            }
        }
    }

    // MARK: - The flight, drawn

    /// The four-hour flight back drawn with no GPS from the takeoff roll on, in the paper's km frame turned by an
    /// arbitrary angle, against the aircraft's ADS-B track.
    private var flightRoute: some View {
        let s = VelocityMethodData.flightRouteStats
        return VStack(alignment: .leading, spacing: 8) {
            Text("Four hours back, drawn with no GPS").font(.subheadline).fontWeight(.semibold)
            if chartsFit {
                Chart {
                    ForEach(VelocityMethodData.flightRoute) { p in
                        LineMark(x: .value("km", p.x), y: .value("km", p.y), series: .value("Line", p.line))
                            .foregroundStyle(by: .value("Line", p.line))
                            .lineStyle(StrokeStyle(lineWidth: p.line == "ADS-B" ? 2.5 : 2,
                                                   dash: p.line == "Phone by a socket" ? [6, 4] : []))
                    }
                    PointMark(x: .value("km", 0), y: .value("km", 0))
                        .foregroundStyle(Color.green).symbolSize(50)
                }
                .chartForegroundStyleScale(VelocityMethodData.flightRouteLines)
                .chartLegend(position: .top, alignment: .leading)
                .chartXScale(domain: -60...3300)
                .chartYScale(domain: -300...600)
                .chartXAxisLabel("km along the way")
                .centeredXLabels([0, 1000, 2000, 3000])
                .chartYAxis { AxisMarks(position: .leading, values: [-200, 0, 200, 400]) { AxisGridLine(); AxisTick(); AxisValueLabel() } }
                .chartYAxisLabel("km to the side")
                .frame(height: 200)
            }
            Text("""
            Started at the takeoff roll and turned by an arbitrary angle; the sideways scale is \
            stretched about two and a half times so the gap shows. Where ADS-B coverage was lost over \
            the sea its track is a straight line. Both phones counted \(s.appKm.formatted()) km of the \
            \(s.realKm.formatted()) flown. The drawn routes ended \(s.inUseEndKm) km (phone in use) and \
            \(s.socketEndKm) km (phone lying by a socket) from the arrival runway; with the direction of \
            builds 118–123 they ended \(s.inUseEndOldKm.formatted()) and \(s.socketEndOldKm.formatted()) km off.
            """)
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var flightSpeed: some View {
        let ph = VelocityMethodData.flightPhases
        return VStack(alignment: .leading, spacing: 8) {
            Text("Speed through the flight back").font(.subheadline).fontWeight(.semibold)
            if chartsFit {
                Chart {
                    RectangleMark(xStart: .value("h", 0), xEnd: .value("h", ph.climbEndHour))
                        .foregroundStyle(Color.blue.opacity(0.08))
                    RectangleMark(xStart: .value("h", ph.descentHour), xEnd: .value("h", 4.4))
                        .foregroundStyle(Color.blue.opacity(0.08))
                    ForEach(VelocityMethodData.flightSpeed) { p in
                        LineMark(x: .value("hours", p.minute / 60), y: .value("km/h", p.kmh), series: .value("Line", p.line))
                            .foregroundStyle(by: .value("Line", p.line))
                            .lineStyle(StrokeStyle(lineWidth: p.line == "ADS-B" ? 2.2 : 1.6))
                    }
                }
                .chartForegroundStyleScale(VelocityMethodData.flightSpeedLines)
                .chartLegend(position: .top, alignment: .leading)
                .chartXScale(domain: 0...4.4)
                .chartYScale(domain: 0...1000)
                .chartXAxisLabel("hours since the takeoff roll")
                .centeredXLabels([0, 1, 2, 3, 4])
                .chartYAxis { AxisMarks(position: .leading, values: [0, 250, 500, 750, 1000]) { AxisGridLine(); AxisTick(); AxisValueLabel() } }
                .chartYAxisLabel("km/h")
                .frame(height: 210)
            }
            Text("""
            The speed the phones showed in the air, against the aircraft's ADS-B ground speed. \
            Shaded: the climb and the descent. Typical error \(ph.climbErr) km/h in the climb, \
            \(ph.cruiseErr) in the cruise and \(ph.descentErr) in the descent, which ran longer than a \
            typical airliner's; \(ph.share)% of the distance in all. The cruise is a typical airliner's, \
            so this 777's faster cruise and the wind on the day show as the gap.
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
                           "The angle is learned only while the speed reads above 14 km/h, so a short, slow drive rests on a few turns. On one ten-minute drive at a median 9 km/h, the speeds read on the day kept \(N.SlowAppPct)% of graded seconds within 30°; replayed with a speed model rebuilt from the other journeys, a different handful of turns sets the angle each time that model changes; \(N.SlowReplayTxt).")
                Limitation("A phone that moves.",
                           "A hand on the phone can lower the speed but not raise it, and a phone picked up while slowing keeps the speed it had when it was picked up — except on a motorcycle with the phone in a pocket, where the rider takes it out at a stop, so that speed fades within seconds. Held in the hand for a whole car drive, the phone read \(N.HandDist)% of the distance GPS measured, and \(N.HandFastApp) km/h where GPS said \(N.HandFastGps) above 50 km/h: the speed needs the phone resting in a pocket, flat or on a mount. A phone that shifts in a pocket turns the drawn route by about as much as it moved, until enough new turns have been learned.")
                Limitation("Keep the phone away from magnets.",
                           "Beside a car's MagSafe charger the phone read up to 2,600 µT, fifty times Earth's field, yet reported its compass as well calibrated. The app ignores such a field. On the drive with the charger there throughout, a few turning minutes still showed Earth's field and the seconds within 30° rose from \(N.MagSafeF)% to \(N.MagSafeG)%; a phone that never leaves such a field cannot be corrected.")
                Limitation("Walking with the phone in some pockets.",
                           "Each footfall can ring twice, and the echo a quarter of a second later counted as a step: on one walk after a ride, 2.5–2.75 steps a second against a rhythm of 1.85, and about twice the distance GPS saw. The app now finds the walking rhythm and refuses a peak that comes too soon. On \(N.EchoOver) of \(N.EchoN) graded stretches the count had run more than 15% fast; on the \(N.EchoOldN) recorded before the pedometer was logged, scaling by the count would take walking from \(N.EchoNow)% to about \(N.EchoScaled)% of GPS. The \(N.EchoPedN) stretches walked since, with the check and the pedometer both live, came out \(N.EchoPedLiveTxt) than GPS.")
                Limitation("A ride taken for a walk.",
                           "The step counter can take a ride's bumps for footsteps: on \(N.StepRideN) journeys, as recorded, \(N.StepRideGps) km that GPS measured at 10 km/h or more were counted by steps as \(N.StepRideLive) km. Steps now end a ride only while the phone swings, as a pocket on a walking leg does and one on a moving bike does not; replayed that way, \(N.StepRideNowN) journeys still have such stretches.")
                Limitation("In an aircraft, the speed after the takeoff is a typical airliner's.",
                           "Learned from real airliners (OpenSky Network ADS-B data and NASA flight recordings), not measured on the flight: a strong wind or a much faster or slower aircraft reads off. Typical cruise 831 km/h; twin-aisle jets cruised near 905, so a 777 reads about 8% low in cruise, a slow regional jet high.")
                Limitation("These numbers are one phone and one person.",
                           "\(N.Journeys) motorcycle and car journeys (\(N.Hours) hours, \(N.KmChecked) km that GPS could check), \(N.WalkStretches) straight stretches and \(N.Walks) walks on foot, and three flights, mostly in one city. Other people, phones and vehicles may behave differently, the built-in network most of all.")
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
        Figure(value: o.distance, label: o.name == "Plane" ? "distance vs ADS-B, long flights" : "distance vs GPS")
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
    struct FlightPoint: Identifiable {
        let id = UUID(); let point: String; let errorPercent: Double
        /// The way the app reads speed in the air now; the others are the ones it replaced.
        var current = false
    }
    /// One point of a drawn route, km, in drawing order.
    struct RoutePoint: Identifiable { let id = UUID(); let line: String; let order: Int; let x: Double; let y: Double }
    struct SpeedPoint: Identifiable { let id = UUID(); let minute: Double; let line: String; let kmh: Double }
    /// ADS-B is the answer key, so it is drawn in the text colour; the app takes the plane's colour.
    static let flightRouteLines: KeyValuePairs<String, Color> = [
        "ADS-B": Color.primary, "Phone in use": AppTheme.duration, "Phone by a socket": AppTheme.pace
    ]
    static let flightSpeedLines: KeyValuePairs<String, Color> = [
        "ADS-B": Color.primary, "The app": AppTheme.duration
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
        .init(name: "Motorcycle", recorded: "65 recordings, 18.2 hours, 308 km checked by GPS; phone in a trouser pocket",
              distance: "−7.7%", speed: "8.7 km/h", speedLabel: "average speed error",
              direction: "77%"),
        .init(name: "Car", recorded: "62 recordings, 23.6 hours, 546 km checked by GPS; phone in a pocket, flat or in a mount",
              distance: "−9.0%", speed: "7.8 km/h", speedLabel: "average speed error",
              direction: "78%"),
        .init(name: "Walking", recorded: "143 straight stretches and 7 walks; phone in a pocket, distance counted by steps",
              distance: "−0.3%", speed: "4.8 km/h", speedLabel: "where GPS measured 4.5",
              direction: "93%"),
        .init(name: "Plane", recorded: "3 flights: two of four hours graded by their ADS-B tracks (3,392 and 3,506 km), one short one by GPS; the takeoff measured, then the typical flight",
              distance: "−5% / −6%", speed: "61 km/h", speedLabel: "typical error in the cruise",
              direction: "72%")
    ]

    static let distance: [Distance] = [
        .init(name: "Motorcycle", detail: "65 journeys, 73% within 20%",
              appKm: 284.6, gpsKm: 308.5, errorPercent: -7.7),
        .init(name: "Car", detail: "62 journeys, 77% within 20%",
              appKm: 496.7, gpsKm: 545.9, errorPercent: -9.0),
        .init(name: "Walking", detail: "143 straight stretches, counted by steps",
              appKm: 5.73, gpsKm: 5.75, errorPercent: -0.3),
        .init(name: "Plane", detail: "two four-hour flights against their ADS-B tracks",
              appKm: 6506, gpsKm: 6898, errorPercent: -5.7)
    ]

    static let speedBands: [SpeedBand] = [
        .init(band: "0–10", motorcycleGPS: 2.6, motorcycleApp: 1.8, carGPS: 2.7, carApp: 2.6),
        .init(band: "10–20", motorcycleGPS: 15.3, motorcycleApp: 19.0, carGPS: 15.0, carApp: 14.8),
        .init(band: "20–30", motorcycleGPS: 25.2, motorcycleApp: 27.7, carGPS: 25.1, carApp: 24.0),
        .init(band: "30–40", motorcycleGPS: 34.7, motorcycleApp: 33.2, carGPS: 35.1, carApp: 33.4),
        .init(band: "40–50", motorcycleGPS: 44.0, motorcycleApp: 37.6, carGPS: 44.6, carApp: 44.0),
        .init(band: "50–60", motorcycleGPS: 54.4, motorcycleApp: 40.9, carGPS: 54.1, carApp: 56.2),
        .init(band: "60–80", motorcycleGPS: 64.8, motorcycleApp: 40.8, carGPS: 69.6, carApp: 64.5),
        .init(band: "80+", motorcycleGPS: 94.0, motorcycleApp: 44.0, carGPS: 94.2, carApp: 59.3, plotted: false)
    ]

    static let direction: [Direction] = [
        .init(name: "Motorcycle", graded: "67 recordings", medianDegrees: 14, within30: 77),
        .init(name: "Car", graded: "53 recordings", medianDegrees: 15, within30: 78),
        .init(name: "Walking", graded: "7 walks", medianDegrees: 10, within30: 93),
        .init(name: "Plane", graded: "6 recordings, 3 flights", medianDegrees: 13, within30: 72)
    ]

    /// Distance in the air, replayed with no GPS through the app's own code: the way it reads speed now on
    /// all three flights, then the ways it replaced, on the four-hour flight out.
    static let flight: [FlightPoint] = [
        .init(point: "Four hours out, against ADS-B", errorPercent: -5.3, current: true),
        .init(point: "Four hours back, against ADS-B", errorPercent: -6.0, current: true),
        .init(point: "Short flight, against GPS", errorPercent: 1.3, current: true),
        .init(point: "Out: NASA medians alone", errorPercent: -13.0),
        .init(point: "Out: tilt engines, phone in a hand", errorPercent: -20.0),
        .init(point: "Out: tilt engines, phone in a bag", errorPercent: -61.0)
    ]

    /// The four-hour flight back drawn with no GPS from the takeoff roll on, in the paper's km frame turned by an
    /// arbitrary angle: the ADS-B track (a coverage gap is its straight chord) and the app on two phones. Every ~8 km.
    static let flightRoute: [RoutePoint] = [
        .init(line: "ADS-B", order: 0, x: -2.4, y: -0.8),
        .init(line: "ADS-B", order: 1, x: -7.2, y: -7.9),
        .init(line: "ADS-B", order: 2, x: -1.1, y: -14.1),
        .init(line: "ADS-B", order: 3, x: 5.1, y: -8.3),
        .init(line: "ADS-B", order: 4, x: 10.6, y: 2.9),
        .init(line: "ADS-B", order: 5, x: 15.4, y: 12.4),
        .init(line: "ADS-B", order: 6, x: 20.6, y: 23.0),
        .init(line: "ADS-B", order: 7, x: 25.9, y: 33.8),
        .init(line: "ADS-B", order: 8, x: 34.2, y: 44.3),
        .init(line: "ADS-B", order: 9, x: 43.6, y: 55.0),
        .init(line: "ADS-B", order: 10, x: 52.7, y: 65.2),
        .init(line: "ADS-B", order: 11, x: 62.3, y: 75.8),
        .init(line: "ADS-B", order: 12, x: 69.1, y: 83.4),
        .init(line: "ADS-B", order: 13, x: 74.5, y: 89.4),
        .init(line: "ADS-B", order: 14, x: 85.0, y: 98.6),
        .init(line: "ADS-B", order: 15, x: 92.3, y: 101.9),
        .init(line: "ADS-B", order: 16, x: 101.7, y: 105.9),
        .init(line: "ADS-B", order: 17, x: 116.0, y: 112.1),
        .init(line: "ADS-B", order: 18, x: 130.5, y: 118.3),
        .init(line: "ADS-B", order: 19, x: 146.4, y: 125.1),
        .init(line: "ADS-B", order: 20, x: 161.3, y: 131.6),
        .init(line: "ADS-B", order: 21, x: 176.2, y: 138.0),
        .init(line: "ADS-B", order: 22, x: 184.2, y: 141.4),
        .init(line: "ADS-B", order: 23, x: 196.1, y: 146.5),
        .init(line: "ADS-B", order: 24, x: 212.8, y: 151.6),
        .init(line: "ADS-B", order: 25, x: 222.3, y: 153.9),
        .init(line: "ADS-B", order: 26, x: 234.7, y: 155.2),
        .init(line: "ADS-B", order: 27, x: 247.0, y: 155.9),
        .init(line: "ADS-B", order: 28, x: 258.2, y: 156.4),
        .init(line: "ADS-B", order: 29, x: 269.4, y: 157.0),
        .init(line: "ADS-B", order: 30, x: 278.2, y: 157.4),
        .init(line: "ADS-B", order: 31, x: 286.9, y: 157.8),
        .init(line: "ADS-B", order: 32, x: 302.4, y: 156.7),
        .init(line: "ADS-B", order: 33, x: 317.2, y: 154.4),
        .init(line: "ADS-B", order: 34, x: 332.0, y: 152.1),
        .init(line: "ADS-B", order: 35, x: 348.3, y: 149.6),
        .init(line: "ADS-B", order: 36, x: 470.5, y: 155.9),
        .init(line: "ADS-B", order: 37, x: 750.5, y: 167.5),
        .init(line: "ADS-B", order: 38, x: 758.6, y: 167.0),
        .init(line: "ADS-B", order: 39, x: 772.8, y: 166.1),
        .init(line: "ADS-B", order: 40, x: 780.9, y: 165.6),
        .init(line: "ADS-B", order: 41, x: 795.5, y: 164.6),
        .init(line: "ADS-B", order: 42, x: 808.8, y: 163.8),
        .init(line: "ADS-B", order: 43, x: 865.8, y: 151.3),
        .init(line: "ADS-B", order: 44, x: 887.1, y: 146.3),
        .init(line: "ADS-B", order: 45, x: 896.6, y: 144.1),
        .init(line: "ADS-B", order: 46, x: 904.9, y: 142.7),
        .init(line: "ADS-B", order: 47, x: 913.6, y: 141.7),
        .init(line: "ADS-B", order: 48, x: 928.1, y: 140.0),
        .init(line: "ADS-B", order: 49, x: 942.8, y: 138.2),
        .init(line: "ADS-B", order: 50, x: 957.3, y: 136.5),
        .init(line: "ADS-B", order: 51, x: 971.9, y: 134.8),
        .init(line: "ADS-B", order: 52, x: 984.2, y: 133.4),
        .init(line: "ADS-B", order: 53, x: 1007.5, y: 130.6),
        .init(line: "ADS-B", order: 54, x: 1022.8, y: 128.8),
        .init(line: "ADS-B", order: 55, x: 1035.7, y: 127.3),
        .init(line: "ADS-B", order: 56, x: 1044.5, y: 126.2),
        .init(line: "ADS-B", order: 57, x: 1053.3, y: 125.1),
        .init(line: "ADS-B", order: 58, x: 1068.0, y: 123.4),
        .init(line: "ADS-B", order: 59, x: 1087.9, y: 121.0),
        .init(line: "ADS-B", order: 60, x: 1107.5, y: 118.6),
        .init(line: "ADS-B", order: 61, x: 1116.7, y: 117.5),
        .init(line: "ADS-B", order: 62, x: 1127.9, y: 116.1),
        .init(line: "ADS-B", order: 63, x: 1142.6, y: 114.3),
        .init(line: "ADS-B", order: 64, x: 1164.0, y: 111.7),
        .init(line: "ADS-B", order: 65, x: 1177.0, y: 110.1),
        .init(line: "ADS-B", order: 66, x: 1189.9, y: 108.5),
        .init(line: "ADS-B", order: 67, x: 1199.0, y: 107.4),
        .init(line: "ADS-B", order: 68, x: 1211.3, y: 105.8),
        .init(line: "ADS-B", order: 69, x: 1220.5, y: 104.7),
        .init(line: "ADS-B", order: 70, x: 1233.8, y: 103.0),
        .init(line: "ADS-B", order: 71, x: 1243.7, y: 101.8),
        .init(line: "ADS-B", order: 72, x: 1258.4, y: 100.0),
        .init(line: "ADS-B", order: 73, x: 1273.0, y: 98.1),
        .init(line: "ADS-B", order: 74, x: 1287.9, y: 96.2),
        .init(line: "ADS-B", order: 75, x: 1302.7, y: 94.3),
        .init(line: "ADS-B", order: 76, x: 1317.5, y: 92.4),
        .init(line: "ADS-B", order: 77, x: 1332.4, y: 90.5),
        .init(line: "ADS-B", order: 78, x: 1347.3, y: 88.6),
        .init(line: "ADS-B", order: 79, x: 1359.9, y: 87.0),
        .init(line: "ADS-B", order: 80, x: 1369.3, y: 85.8),
        .init(line: "ADS-B", order: 81, x: 1391.7, y: 82.9),
        .init(line: "ADS-B", order: 82, x: 1410.0, y: 80.5),
        .init(line: "ADS-B", order: 83, x: 1425.2, y: 78.5),
        .init(line: "ADS-B", order: 84, x: 1446.4, y: 75.7),
        .init(line: "ADS-B", order: 85, x: 1455.1, y: 74.5),
        .init(line: "ADS-B", order: 86, x: 1477.2, y: 71.9),
        .init(line: "ADS-B", order: 87, x: 1496.8, y: 71.8),
        .init(line: "ADS-B", order: 88, x: 1511.9, y: 72.1),
        .init(line: "ADS-B", order: 89, x: 1527.0, y: 72.3),
        .init(line: "ADS-B", order: 90, x: 1542.1, y: 72.5),
        .init(line: "ADS-B", order: 91, x: 1557.0, y: 72.7),
        .init(line: "ADS-B", order: 92, x: 1585.4, y: 73.1),
        .init(line: "ADS-B", order: 93, x: 1594.4, y: 73.2),
        .init(line: "ADS-B", order: 94, x: 1614.7, y: 73.5),
        .init(line: "ADS-B", order: 95, x: 1624.0, y: 73.6),
        .init(line: "ADS-B", order: 96, x: 2469.8, y: 4.4),
        .init(line: "ADS-B", order: 97, x: 2488.7, y: 2.4),
        .init(line: "ADS-B", order: 98, x: 2497.3, y: 3.3),
        .init(line: "ADS-B", order: 99, x: 2512.4, y: 6.4),
        .init(line: "ADS-B", order: 100, x: 2535.1, y: 11.0),
        .init(line: "ADS-B", order: 101, x: 2543.1, y: 12.6),
        .init(line: "ADS-B", order: 102, x: 2551.2, y: 14.3),
        .init(line: "ADS-B", order: 103, x: 2563.1, y: 16.7),
        .init(line: "ADS-B", order: 104, x: 2572.1, y: 18.5),
        .init(line: "ADS-B", order: 105, x: 2581.0, y: 20.3),
        .init(line: "ADS-B", order: 106, x: 2595.5, y: 23.2),
        .init(line: "ADS-B", order: 107, x: 2610.5, y: 26.1),
        .init(line: "ADS-B", order: 108, x: 2619.7, y: 28.0),
        .init(line: "ADS-B", order: 109, x: 2634.0, y: 30.8),
        .init(line: "ADS-B", order: 110, x: 2650.8, y: 34.1),
        .init(line: "ADS-B", order: 111, x: 2659.0, y: 35.7),
        .init(line: "ADS-B", order: 112, x: 2667.6, y: 37.4),
        .init(line: "ADS-B", order: 113, x: 2676.2, y: 39.1),
        .init(line: "ADS-B", order: 114, x: 2684.1, y: 40.7),
        .init(line: "ADS-B", order: 115, x: 2692.3, y: 42.2),
        .init(line: "ADS-B", order: 116, x: 2706.8, y: 45.1),
        .init(line: "ADS-B", order: 117, x: 2721.3, y: 47.9),
        .init(line: "ADS-B", order: 118, x: 2737.0, y: 50.9),
        .init(line: "ADS-B", order: 119, x: 2746.4, y: 52.7),
        .init(line: "ADS-B", order: 120, x: 2762.6, y: 55.8),
        .init(line: "ADS-B", order: 121, x: 2777.0, y: 58.6),
        .init(line: "ADS-B", order: 122, x: 2791.9, y: 61.4),
        .init(line: "ADS-B", order: 123, x: 2806.4, y: 64.2),
        .init(line: "ADS-B", order: 124, x: 2820.8, y: 66.9),
        .init(line: "ADS-B", order: 125, x: 2835.4, y: 69.6),
        .init(line: "ADS-B", order: 126, x: 2850.0, y: 72.3),
        .init(line: "ADS-B", order: 127, x: 2864.7, y: 75.1),
        .init(line: "ADS-B", order: 128, x: 2874.2, y: 78.7),
        .init(line: "ADS-B", order: 129, x: 2881.7, y: 88.2),
        .init(line: "ADS-B", order: 130, x: 2890.1, y: 100.9),
        .init(line: "ADS-B", order: 131, x: 2898.0, y: 112.8),
        .init(line: "ADS-B", order: 132, x: 2906.1, y: 125.0),
        .init(line: "ADS-B", order: 133, x: 2913.7, y: 136.3),
        .init(line: "ADS-B", order: 134, x: 2921.3, y: 147.8),
        .init(line: "ADS-B", order: 135, x: 2929.2, y: 159.7),
        .init(line: "ADS-B", order: 136, x: 2936.7, y: 171.1),
        .init(line: "ADS-B", order: 137, x: 2943.9, y: 181.9),
        .init(line: "ADS-B", order: 138, x: 2950.9, y: 192.5),
        .init(line: "ADS-B", order: 139, x: 2957.6, y: 202.7),
        .init(line: "ADS-B", order: 140, x: 2964.3, y: 212.7),
        .init(line: "ADS-B", order: 141, x: 2970.7, y: 222.5),
        .init(line: "ADS-B", order: 142, x: 2977.6, y: 233.0),
        .init(line: "ADS-B", order: 143, x: 2984.0, y: 242.6),
        .init(line: "ADS-B", order: 144, x: 2991.0, y: 253.2),
        .init(line: "ADS-B", order: 145, x: 2997.5, y: 263.1),
        .init(line: "ADS-B", order: 146, x: 3000.8, y: 270.5),
        .init(line: "ADS-B", order: 147, x: 3000.7, y: 281.4),
        .init(line: "ADS-B", order: 148, x: 3000.4, y: 291.3),
        .init(line: "ADS-B", order: 149, x: 3007.0, y: 299.4),
        .init(line: "ADS-B", order: 150, x: 3017.1, y: 303.4),
        .init(line: "ADS-B", order: 151, x: 3027.5, y: 307.5),
        .init(line: "ADS-B", order: 152, x: 3037.7, y: 311.6),
        .init(line: "ADS-B", order: 153, x: 3047.7, y: 315.6),
        .init(line: "ADS-B", order: 154, x: 3057.8, y: 319.6),
        .init(line: "ADS-B", order: 155, x: 3067.9, y: 323.6),
        .init(line: "ADS-B", order: 156, x: 3078.0, y: 327.6),
        .init(line: "ADS-B", order: 157, x: 3088.1, y: 331.6),
        .init(line: "ADS-B", order: 158, x: 3098.3, y: 335.6),
        .init(line: "ADS-B", order: 159, x: 3108.2, y: 339.5),
        .init(line: "ADS-B", order: 160, x: 3117.5, y: 343.2),
        .init(line: "ADS-B", order: 161, x: 3126.4, y: 346.7),
        .init(line: "ADS-B", order: 162, x: 3134.8, y: 350.0),
        .init(line: "ADS-B", order: 163, x: 3143.0, y: 353.2),
        .init(line: "ADS-B", order: 164, x: 3151.0, y: 356.3),
        .init(line: "ADS-B", order: 165, x: 3159.6, y: 359.7),
        .init(line: "ADS-B", order: 166, x: 3170.6, y: 362.4),
        .init(line: "ADS-B", order: 167, x: 3179.7, y: 362.0),
        .init(line: "ADS-B", order: 168, x: 3188.7, y: 361.6),
        .init(line: "ADS-B", order: 169, x: 3198.0, y: 361.2),
        .init(line: "ADS-B", order: 170, x: 3206.0, y: 360.9),
        .init(line: "ADS-B", order: 171, x: 3208.1, y: 369.0),
        .init(line: "ADS-B", order: 172, x: 3198.8, y: 368.6),
        .init(line: "ADS-B", order: 173, x: 3190.8, y: 363.8),
        .init(line: "ADS-B", order: 174, x: 3193.5, y: 354.7),
        .init(line: "ADS-B", order: 175, x: 3200.4, y: 350.1),
        .init(line: "ADS-B", order: 176, x: 3211.0, y: 348.1),
        .init(line: "ADS-B", order: 177, x: 3219.6, y: 346.6),
        .init(line: "ADS-B", order: 178, x: 3230.2, y: 344.8),
        .init(line: "ADS-B", order: 179, x: 3238.4, y: 343.4),
        .init(line: "ADS-B", order: 180, x: 3245.1, y: 342.3),
        .init(line: "Phone in use", order: 0, x: 0.0, y: 0.0),
        .init(line: "Phone in use", order: 1, x: -7.3, y: -5.1),
        .init(line: "Phone in use", order: 2, x: 1.2, y: -12.5),
        .init(line: "Phone in use", order: 3, x: 5.7, y: -4.5),
        .init(line: "Phone in use", order: 4, x: 9.6, y: 4.8),
        .init(line: "Phone in use", order: 5, x: 13.8, y: 14.7),
        .init(line: "Phone in use", order: 6, x: 18.2, y: 25.0),
        .init(line: "Phone in use", order: 7, x: 22.8, y: 35.7),
        .init(line: "Phone in use", order: 8, x: 29.7, y: 45.4),
        .init(line: "Phone in use", order: 9, x: 37.2, y: 55.0),
        .init(line: "Phone in use", order: 10, x: 44.9, y: 64.8),
        .init(line: "Phone in use", order: 11, x: 52.8, y: 74.8),
        .init(line: "Phone in use", order: 12, x: 60.8, y: 85.0),
        .init(line: "Phone in use", order: 13, x: 69.2, y: 95.2),
        .init(line: "Phone in use", order: 14, x: 80.6, y: 101.8),
        .init(line: "Phone in use", order: 15, x: 92.5, y: 107.9),
        .init(line: "Phone in use", order: 16, x: 104.5, y: 114.0),
        .init(line: "Phone in use", order: 17, x: 116.5, y: 120.2),
        .init(line: "Phone in use", order: 18, x: 128.6, y: 126.3),
        .init(line: "Phone in use", order: 19, x: 140.6, y: 132.5),
        .init(line: "Phone in use", order: 20, x: 152.7, y: 138.6),
        .init(line: "Phone in use", order: 21, x: 164.8, y: 144.8),
        .init(line: "Phone in use", order: 22, x: 177.4, y: 149.9),
        .init(line: "Phone in use", order: 23, x: 190.4, y: 153.8),
        .init(line: "Phone in use", order: 24, x: 203.9, y: 155.8),
        .init(line: "Phone in use", order: 25, x: 217.5, y: 157.5),
        .init(line: "Phone in use", order: 26, x: 231.1, y: 159.2),
        .init(line: "Phone in use", order: 27, x: 244.7, y: 160.8),
        .init(line: "Phone in use", order: 28, x: 258.3, y: 161.2),
        .init(line: "Phone in use", order: 29, x: 271.9, y: 160.1),
        .init(line: "Phone in use", order: 30, x: 285.6, y: 159.0),
        .init(line: "Phone in use", order: 31, x: 299.3, y: 158.0),
        .init(line: "Phone in use", order: 32, x: 313.0, y: 156.9),
        .init(line: "Phone in use", order: 33, x: 326.7, y: 155.9),
        .init(line: "Phone in use", order: 34, x: 340.4, y: 155.2),
        .init(line: "Phone in use", order: 35, x: 353.9, y: 157.7),
        .init(line: "Phone in use", order: 36, x: 367.3, y: 160.5),
        .init(line: "Phone in use", order: 37, x: 380.9, y: 163.4),
        .init(line: "Phone in use", order: 38, x: 394.5, y: 166.2),
        .init(line: "Phone in use", order: 39, x: 408.1, y: 169.1),
        .init(line: "Phone in use", order: 40, x: 421.7, y: 171.9),
        .init(line: "Phone in use", order: 41, x: 435.2, y: 174.8),
        .init(line: "Phone in use", order: 42, x: 448.8, y: 177.6),
        .init(line: "Phone in use", order: 43, x: 462.4, y: 180.5),
        .init(line: "Phone in use", order: 44, x: 476.0, y: 183.3),
        .init(line: "Phone in use", order: 45, x: 489.6, y: 186.2),
        .init(line: "Phone in use", order: 46, x: 503.2, y: 189.0),
        .init(line: "Phone in use", order: 47, x: 516.8, y: 191.3),
        .init(line: "Phone in use", order: 48, x: 530.7, y: 191.9),
        .init(line: "Phone in use", order: 49, x: 544.6, y: 192.4),
        .init(line: "Phone in use", order: 50, x: 558.5, y: 193.0),
        .init(line: "Phone in use", order: 51, x: 572.4, y: 193.5),
        .init(line: "Phone in use", order: 52, x: 586.3, y: 194.1),
        .init(line: "Phone in use", order: 53, x: 600.2, y: 194.6),
        .init(line: "Phone in use", order: 54, x: 614.1, y: 195.2),
        .init(line: "Phone in use", order: 55, x: 627.9, y: 195.8),
        .init(line: "Phone in use", order: 56, x: 641.8, y: 196.3),
        .init(line: "Phone in use", order: 57, x: 655.7, y: 196.9),
        .init(line: "Phone in use", order: 58, x: 669.6, y: 197.4),
        .init(line: "Phone in use", order: 59, x: 683.5, y: 197.9),
        .init(line: "Phone in use", order: 60, x: 697.4, y: 198.5),
        .init(line: "Phone in use", order: 61, x: 711.3, y: 199.0),
        .init(line: "Phone in use", order: 62, x: 725.2, y: 199.6),
        .init(line: "Phone in use", order: 63, x: 739.1, y: 200.0),
        .init(line: "Phone in use", order: 64, x: 753.0, y: 198.6),
        .init(line: "Phone in use", order: 65, x: 766.8, y: 197.0),
        .init(line: "Phone in use", order: 66, x: 780.7, y: 195.4),
        .init(line: "Phone in use", order: 67, x: 794.5, y: 193.8),
        .init(line: "Phone in use", order: 68, x: 808.3, y: 192.2),
        .init(line: "Phone in use", order: 69, x: 822.2, y: 190.6),
        .init(line: "Phone in use", order: 70, x: 836.0, y: 189.0),
        .init(line: "Phone in use", order: 71, x: 849.9, y: 187.4),
        .init(line: "Phone in use", order: 72, x: 863.7, y: 185.8),
        .init(line: "Phone in use", order: 73, x: 877.6, y: 184.2),
        .init(line: "Phone in use", order: 74, x: 891.4, y: 182.6),
        .init(line: "Phone in use", order: 75, x: 905.3, y: 181.0),
        .init(line: "Phone in use", order: 76, x: 919.2, y: 179.3),
        .init(line: "Phone in use", order: 77, x: 933.0, y: 177.7),
        .init(line: "Phone in use", order: 78, x: 946.9, y: 176.1),
        .init(line: "Phone in use", order: 79, x: 960.7, y: 174.5),
        .init(line: "Phone in use", order: 80, x: 974.6, y: 172.9),
        .init(line: "Phone in use", order: 81, x: 988.5, y: 171.3),
        .init(line: "Phone in use", order: 82, x: 1002.3, y: 169.6),
        .init(line: "Phone in use", order: 83, x: 1016.2, y: 168.0),
        .init(line: "Phone in use", order: 84, x: 1030.1, y: 166.4),
        .init(line: "Phone in use", order: 85, x: 1043.9, y: 164.8),
        .init(line: "Phone in use", order: 86, x: 1057.8, y: 163.1),
        .init(line: "Phone in use", order: 87, x: 1071.7, y: 161.5),
        .init(line: "Phone in use", order: 88, x: 1085.6, y: 159.9),
        .init(line: "Phone in use", order: 89, x: 1099.4, y: 158.2),
        .init(line: "Phone in use", order: 90, x: 1113.3, y: 156.6),
        .init(line: "Phone in use", order: 91, x: 1127.2, y: 155.0),
        .init(line: "Phone in use", order: 92, x: 1141.1, y: 153.3),
        .init(line: "Phone in use", order: 93, x: 1155.0, y: 151.7),
        .init(line: "Phone in use", order: 94, x: 1168.9, y: 150.0),
        .init(line: "Phone in use", order: 95, x: 1182.7, y: 148.4),
        .init(line: "Phone in use", order: 96, x: 1196.6, y: 146.7),
        .init(line: "Phone in use", order: 97, x: 1210.5, y: 145.1),
        .init(line: "Phone in use", order: 98, x: 1224.4, y: 143.4),
        .init(line: "Phone in use", order: 99, x: 1238.3, y: 141.8),
        .init(line: "Phone in use", order: 100, x: 1252.2, y: 140.1),
        .init(line: "Phone in use", order: 101, x: 1266.1, y: 138.4),
        .init(line: "Phone in use", order: 102, x: 1280.0, y: 136.8),
        .init(line: "Phone in use", order: 103, x: 1293.9, y: 135.1),
        .init(line: "Phone in use", order: 104, x: 1307.8, y: 133.5),
        .init(line: "Phone in use", order: 105, x: 1321.7, y: 131.8),
        .init(line: "Phone in use", order: 106, x: 1335.6, y: 130.1),
        .init(line: "Phone in use", order: 107, x: 1349.5, y: 128.4),
        .init(line: "Phone in use", order: 108, x: 1363.5, y: 127.0),
        .init(line: "Phone in use", order: 109, x: 1377.5, y: 126.7),
        .init(line: "Phone in use", order: 110, x: 1391.4, y: 126.5),
        .init(line: "Phone in use", order: 111, x: 1405.4, y: 126.2),
        .init(line: "Phone in use", order: 112, x: 1419.4, y: 126.0),
        .init(line: "Phone in use", order: 113, x: 1433.4, y: 125.8),
        .init(line: "Phone in use", order: 114, x: 1447.4, y: 125.5),
        .init(line: "Phone in use", order: 115, x: 1461.4, y: 125.3),
        .init(line: "Phone in use", order: 116, x: 1475.4, y: 125.0),
        .init(line: "Phone in use", order: 117, x: 1489.4, y: 124.7),
        .init(line: "Phone in use", order: 118, x: 1503.4, y: 124.5),
        .init(line: "Phone in use", order: 119, x: 1517.4, y: 124.2),
        .init(line: "Phone in use", order: 120, x: 1531.4, y: 124.0),
        .init(line: "Phone in use", order: 121, x: 1545.5, y: 123.7),
        .init(line: "Phone in use", order: 122, x: 1559.5, y: 123.4),
        .init(line: "Phone in use", order: 123, x: 1573.5, y: 123.1),
        .init(line: "Phone in use", order: 124, x: 1587.5, y: 122.9),
        .init(line: "Phone in use", order: 125, x: 1601.5, y: 122.6),
        .init(line: "Phone in use", order: 126, x: 1615.6, y: 122.3),
        .init(line: "Phone in use", order: 127, x: 1629.6, y: 122.0),
        .init(line: "Phone in use", order: 128, x: 1643.6, y: 121.8),
        .init(line: "Phone in use", order: 129, x: 1657.6, y: 121.5),
        .init(line: "Phone in use", order: 130, x: 1671.7, y: 121.2),
        .init(line: "Phone in use", order: 131, x: 1685.7, y: 120.8),
        .init(line: "Phone in use", order: 132, x: 1699.7, y: 119.2),
        .init(line: "Phone in use", order: 133, x: 1713.7, y: 117.6),
        .init(line: "Phone in use", order: 134, x: 1727.7, y: 115.9),
        .init(line: "Phone in use", order: 135, x: 1741.7, y: 114.3),
        .init(line: "Phone in use", order: 136, x: 1755.6, y: 112.6),
        .init(line: "Phone in use", order: 137, x: 1769.6, y: 111.0),
        .init(line: "Phone in use", order: 138, x: 1783.6, y: 109.3),
        .init(line: "Phone in use", order: 139, x: 1797.6, y: 107.6),
        .init(line: "Phone in use", order: 140, x: 1811.6, y: 106.0),
        .init(line: "Phone in use", order: 141, x: 1825.6, y: 104.3),
        .init(line: "Phone in use", order: 142, x: 1839.6, y: 102.6),
        .init(line: "Phone in use", order: 143, x: 1853.7, y: 101.0),
        .init(line: "Phone in use", order: 144, x: 1867.7, y: 99.3),
        .init(line: "Phone in use", order: 145, x: 1881.2, y: 95.3),
        .init(line: "Phone in use", order: 146, x: 1894.2, y: 89.5),
        .init(line: "Phone in use", order: 147, x: 1907.3, y: 83.9),
        .init(line: "Phone in use", order: 148, x: 1921.1, y: 81.1),
        .init(line: "Phone in use", order: 149, x: 1935.0, y: 78.5),
        .init(line: "Phone in use", order: 150, x: 1949.0, y: 75.8),
        .init(line: "Phone in use", order: 151, x: 1962.9, y: 73.2),
        .init(line: "Phone in use", order: 152, x: 1976.9, y: 71.7),
        .init(line: "Phone in use", order: 153, x: 1991.0, y: 70.2),
        .init(line: "Phone in use", order: 154, x: 2005.0, y: 68.7),
        .init(line: "Phone in use", order: 155, x: 2019.1, y: 67.2),
        .init(line: "Phone in use", order: 156, x: 2033.1, y: 65.7),
        .init(line: "Phone in use", order: 157, x: 2047.2, y: 64.1),
        .init(line: "Phone in use", order: 158, x: 2061.2, y: 62.6),
        .init(line: "Phone in use", order: 159, x: 2075.3, y: 60.8),
        .init(line: "Phone in use", order: 160, x: 2089.2, y: 57.9),
        .init(line: "Phone in use", order: 161, x: 2103.1, y: 54.9),
        .init(line: "Phone in use", order: 162, x: 2117.0, y: 51.9),
        .init(line: "Phone in use", order: 163, x: 2130.9, y: 48.9),
        .init(line: "Phone in use", order: 164, x: 2144.7, y: 45.8),
        .init(line: "Phone in use", order: 165, x: 2158.6, y: 42.8),
        .init(line: "Phone in use", order: 166, x: 2172.6, y: 39.8),
        .init(line: "Phone in use", order: 167, x: 2186.5, y: 36.8),
        .init(line: "Phone in use", order: 168, x: 2200.4, y: 33.8),
        .init(line: "Phone in use", order: 169, x: 2214.3, y: 30.8),
        .init(line: "Phone in use", order: 170, x: 2228.2, y: 27.7),
        .init(line: "Phone in use", order: 171, x: 2242.1, y: 24.7),
        .init(line: "Phone in use", order: 172, x: 2256.0, y: 21.7),
        .init(line: "Phone in use", order: 173, x: 2270.0, y: 18.6),
        .init(line: "Phone in use", order: 174, x: 2283.9, y: 15.6),
        .init(line: "Phone in use", order: 175, x: 2297.8, y: 12.6),
        .init(line: "Phone in use", order: 176, x: 2311.8, y: 9.6),
        .init(line: "Phone in use", order: 177, x: 2325.8, y: 9.9),
        .init(line: "Phone in use", order: 178, x: 2339.9, y: 11.2),
        .init(line: "Phone in use", order: 179, x: 2353.9, y: 12.4),
        .init(line: "Phone in use", order: 180, x: 2367.9, y: 13.6),
        .init(line: "Phone in use", order: 181, x: 2382.0, y: 14.8),
        .init(line: "Phone in use", order: 182, x: 2396.0, y: 16.0),
        .init(line: "Phone in use", order: 183, x: 2410.1, y: 17.2),
        .init(line: "Phone in use", order: 184, x: 2424.1, y: 18.4),
        .init(line: "Phone in use", order: 185, x: 2438.2, y: 19.6),
        .init(line: "Phone in use", order: 186, x: 2452.2, y: 20.8),
        .init(line: "Phone in use", order: 187, x: 2466.3, y: 22.0),
        .init(line: "Phone in use", order: 188, x: 2480.3, y: 23.2),
        .init(line: "Phone in use", order: 189, x: 2494.4, y: 24.4),
        .init(line: "Phone in use", order: 190, x: 2508.5, y: 25.6),
        .init(line: "Phone in use", order: 191, x: 2522.5, y: 26.8),
        .init(line: "Phone in use", order: 192, x: 2536.6, y: 27.9),
        .init(line: "Phone in use", order: 193, x: 2550.7, y: 29.1),
        .init(line: "Phone in use", order: 194, x: 2564.8, y: 30.3),
        .init(line: "Phone in use", order: 195, x: 2578.9, y: 31.4),
        .init(line: "Phone in use", order: 196, x: 2593.0, y: 32.6),
        .init(line: "Phone in use", order: 197, x: 2607.1, y: 33.7),
        .init(line: "Phone in use", order: 198, x: 2621.1, y: 34.9),
        .init(line: "Phone in use", order: 199, x: 2635.2, y: 36.0),
        .init(line: "Phone in use", order: 200, x: 2649.4, y: 37.2),
        .init(line: "Phone in use", order: 201, x: 2663.5, y: 38.3),
        .init(line: "Phone in use", order: 202, x: 2677.6, y: 39.5),
        .init(line: "Phone in use", order: 203, x: 2690.7, y: 43.5),
        .init(line: "Phone in use", order: 204, x: 2700.4, y: 53.4),
        .init(line: "Phone in use", order: 205, x: 2710.0, y: 63.4),
        .init(line: "Phone in use", order: 206, x: 2719.7, y: 73.4),
        .init(line: "Phone in use", order: 207, x: 2729.3, y: 83.4),
        .init(line: "Phone in use", order: 208, x: 2738.9, y: 93.4),
        .init(line: "Phone in use", order: 209, x: 2748.5, y: 103.4),
        .init(line: "Phone in use", order: 210, x: 2758.1, y: 113.4),
        .init(line: "Phone in use", order: 211, x: 2767.8, y: 123.4),
        .init(line: "Phone in use", order: 212, x: 2777.4, y: 133.4),
        .init(line: "Phone in use", order: 213, x: 2787.0, y: 143.4),
        .init(line: "Phone in use", order: 214, x: 2796.6, y: 153.3),
        .init(line: "Phone in use", order: 215, x: 2806.2, y: 163.3),
        .init(line: "Phone in use", order: 216, x: 2815.8, y: 173.3),
        .init(line: "Phone in use", order: 217, x: 2825.2, y: 183.1),
        .init(line: "Phone in use", order: 218, x: 2834.2, y: 192.4),
        .init(line: "Phone in use", order: 219, x: 2843.0, y: 201.6),
        .init(line: "Phone in use", order: 220, x: 2851.6, y: 210.5),
        .init(line: "Phone in use", order: 221, x: 2857.1, y: 221.2),
        .init(line: "Phone in use", order: 222, x: 2858.1, y: 233.5),
        .init(line: "Phone in use", order: 223, x: 2862.2, y: 244.2),
        .init(line: "Phone in use", order: 224, x: 2873.0, y: 247.4),
        .init(line: "Phone in use", order: 225, x: 2884.3, y: 248.0),
        .init(line: "Phone in use", order: 226, x: 2895.3, y: 248.5),
        .init(line: "Phone in use", order: 227, x: 2906.0, y: 249.1),
        .init(line: "Phone in use", order: 228, x: 2916.2, y: 249.6),
        .init(line: "Phone in use", order: 229, x: 2926.0, y: 250.1),
        .init(line: "Phone in use", order: 230, x: 2935.5, y: 250.6),
        .init(line: "Phone in use", order: 231, x: 2944.7, y: 251.1),
        .init(line: "Phone in use", order: 232, x: 2953.6, y: 251.6),
        .init(line: "Phone in use", order: 233, x: 2962.2, y: 252.0),
        .init(line: "Phone in use", order: 234, x: 2970.6, y: 252.4),
        .init(line: "Phone in use", order: 235, x: 2978.6, y: 252.8),
        .init(line: "Phone in use", order: 236, x: 2993.6, y: 253.6),
        .init(line: "Phone in use", order: 237, x: 3007.3, y: 254.3),
        .init(line: "Phone in use", order: 238, x: 3019.9, y: 253.5),
        .init(line: "Phone in use", order: 239, x: 3031.3, y: 248.9),
        .init(line: "Phone in use", order: 240, x: 3042.2, y: 244.7),
        .init(line: "Phone in use", order: 241, x: 3035.8, y: 251.8),
        .init(line: "Phone in use", order: 242, x: 3033.6, y: 241.0),
        .init(line: "Phone in use", order: 243, x: 3041.8, y: 234.5),
        .init(line: "Phone in use", order: 244, x: 3050.2, y: 228.3),
        .init(line: "Phone in use", order: 245, x: 3058.7, y: 222.2),
        .init(line: "Phone in use", order: 246, x: 3067.2, y: 216.0),
        .init(line: "Phone in use", order: 247, x: 3069.9, y: 214.1),
        .init(line: "Phone by a socket", order: 0, x: 0.0, y: 0.0),
        .init(line: "Phone by a socket", order: 1, x: -7.0, y: -5.3),
        .init(line: "Phone by a socket", order: 2, x: 2.1, y: -12.9),
        .init(line: "Phone by a socket", order: 3, x: 7.2, y: -5.2),
        .init(line: "Phone by a socket", order: 4, x: 12.1, y: 3.5),
        .init(line: "Phone by a socket", order: 5, x: 17.4, y: 12.9),
        .init(line: "Phone by a socket", order: 6, x: 22.9, y: 22.7),
        .init(line: "Phone by a socket", order: 7, x: 28.5, y: 32.9),
        .init(line: "Phone by a socket", order: 8, x: 34.9, y: 42.9),
        .init(line: "Phone by a socket", order: 9, x: 43.4, y: 51.7),
        .init(line: "Phone by a socket", order: 10, x: 52.1, y: 60.6),
        .init(line: "Phone by a socket", order: 11, x: 61.4, y: 69.3),
        .init(line: "Phone by a socket", order: 12, x: 70.9, y: 78.2),
        .init(line: "Phone by a socket", order: 13, x: 80.6, y: 87.0),
        .init(line: "Phone by a socket", order: 14, x: 92.7, y: 92.5),
        .init(line: "Phone by a socket", order: 15, x: 105.1, y: 97.3),
        .init(line: "Phone by a socket", order: 16, x: 117.7, y: 102.2),
        .init(line: "Phone by a socket", order: 17, x: 130.3, y: 107.1),
        .init(line: "Phone by a socket", order: 18, x: 142.9, y: 112.0),
        .init(line: "Phone by a socket", order: 19, x: 155.5, y: 116.9),
        .init(line: "Phone by a socket", order: 20, x: 168.1, y: 121.8),
        .init(line: "Phone by a socket", order: 21, x: 181.0, y: 126.3),
        .init(line: "Phone by a socket", order: 22, x: 194.1, y: 129.8),
        .init(line: "Phone by a socket", order: 23, x: 207.5, y: 132.2),
        .init(line: "Phone by a socket", order: 24, x: 221.1, y: 132.8),
        .init(line: "Phone by a socket", order: 25, x: 234.8, y: 133.2),
        .init(line: "Phone by a socket", order: 26, x: 248.5, y: 133.6),
        .init(line: "Phone by a socket", order: 27, x: 262.1, y: 134.1),
        .init(line: "Phone by a socket", order: 28, x: 275.8, y: 134.8),
        .init(line: "Phone by a socket", order: 29, x: 289.4, y: 133.0),
        .init(line: "Phone by a socket", order: 30, x: 302.9, y: 131.1),
        .init(line: "Phone by a socket", order: 31, x: 316.5, y: 129.1),
        .init(line: "Phone by a socket", order: 32, x: 330.1, y: 127.2),
        .init(line: "Phone by a socket", order: 33, x: 343.7, y: 125.2),
        .init(line: "Phone by a socket", order: 34, x: 357.3, y: 123.7),
        .init(line: "Phone by a socket", order: 35, x: 371.0, y: 125.2),
        .init(line: "Phone by a socket", order: 36, x: 384.6, y: 127.0),
        .init(line: "Phone by a socket", order: 37, x: 398.4, y: 128.7),
        .init(line: "Phone by a socket", order: 38, x: 412.2, y: 130.5),
        .init(line: "Phone by a socket", order: 39, x: 425.9, y: 132.2),
        .init(line: "Phone by a socket", order: 40, x: 439.7, y: 134.0),
        .init(line: "Phone by a socket", order: 41, x: 453.5, y: 135.7),
        .init(line: "Phone by a socket", order: 42, x: 467.2, y: 137.5),
        .init(line: "Phone by a socket", order: 43, x: 481.0, y: 139.2),
        .init(line: "Phone by a socket", order: 44, x: 494.8, y: 141.0),
        .init(line: "Phone by a socket", order: 45, x: 508.6, y: 142.7),
        .init(line: "Phone by a socket", order: 46, x: 522.3, y: 144.5),
        .init(line: "Phone by a socket", order: 47, x: 536.2, y: 145.8),
        .init(line: "Phone by a socket", order: 48, x: 550.1, y: 145.8),
        .init(line: "Phone by a socket", order: 49, x: 564.0, y: 145.8),
        .init(line: "Phone by a socket", order: 50, x: 577.9, y: 145.7),
        .init(line: "Phone by a socket", order: 51, x: 591.8, y: 145.7),
        .init(line: "Phone by a socket", order: 52, x: 605.7, y: 145.7),
        .init(line: "Phone by a socket", order: 53, x: 619.6, y: 145.7),
        .init(line: "Phone by a socket", order: 54, x: 633.5, y: 145.7),
        .init(line: "Phone by a socket", order: 55, x: 647.4, y: 145.7),
        .init(line: "Phone by a socket", order: 56, x: 661.3, y: 145.7),
        .init(line: "Phone by a socket", order: 57, x: 675.2, y: 145.7),
        .init(line: "Phone by a socket", order: 58, x: 689.1, y: 145.7),
        .init(line: "Phone by a socket", order: 59, x: 703.0, y: 145.7),
        .init(line: "Phone by a socket", order: 60, x: 716.9, y: 145.6),
        .init(line: "Phone by a socket", order: 61, x: 730.8, y: 145.6),
        .init(line: "Phone by a socket", order: 62, x: 744.7, y: 145.6),
        .init(line: "Phone by a socket", order: 63, x: 758.6, y: 145.5),
        .init(line: "Phone by a socket", order: 64, x: 772.3, y: 143.1),
        .init(line: "Phone by a socket", order: 65, x: 786.0, y: 140.1),
        .init(line: "Phone by a socket", order: 66, x: 799.6, y: 137.2),
        .init(line: "Phone by a socket", order: 67, x: 813.2, y: 134.2),
        .init(line: "Phone by a socket", order: 68, x: 826.8, y: 131.2),
        .init(line: "Phone by a socket", order: 69, x: 840.6, y: 128.8),
        .init(line: "Phone by a socket", order: 70, x: 854.3, y: 126.7),
        .init(line: "Phone by a socket", order: 71, x: 868.1, y: 124.6),
        .init(line: "Phone by a socket", order: 72, x: 881.9, y: 122.6),
        .init(line: "Phone by a socket", order: 73, x: 895.7, y: 120.5),
        .init(line: "Phone by a socket", order: 74, x: 909.5, y: 118.4),
        .init(line: "Phone by a socket", order: 75, x: 923.3, y: 116.3),
        .init(line: "Phone by a socket", order: 76, x: 937.1, y: 114.2),
        .init(line: "Phone by a socket", order: 77, x: 950.9, y: 112.1),
        .init(line: "Phone by a socket", order: 78, x: 964.7, y: 110.0),
        .init(line: "Phone by a socket", order: 79, x: 978.5, y: 107.9),
        .init(line: "Phone by a socket", order: 80, x: 992.3, y: 105.9),
        .init(line: "Phone by a socket", order: 81, x: 1006.1, y: 103.8),
        .init(line: "Phone by a socket", order: 82, x: 1019.9, y: 101.7),
        .init(line: "Phone by a socket", order: 83, x: 1033.7, y: 99.6),
        .init(line: "Phone by a socket", order: 84, x: 1047.5, y: 97.5),
        .init(line: "Phone by a socket", order: 85, x: 1061.3, y: 95.4),
        .init(line: "Phone by a socket", order: 86, x: 1075.1, y: 93.3),
        .init(line: "Phone by a socket", order: 87, x: 1088.9, y: 91.2),
        .init(line: "Phone by a socket", order: 88, x: 1102.7, y: 89.0),
        .init(line: "Phone by a socket", order: 89, x: 1116.5, y: 86.9),
        .init(line: "Phone by a socket", order: 90, x: 1130.3, y: 84.8),
        .init(line: "Phone by a socket", order: 91, x: 1144.2, y: 82.7),
        .init(line: "Phone by a socket", order: 92, x: 1158.0, y: 80.6),
        .init(line: "Phone by a socket", order: 93, x: 1171.8, y: 78.5),
        .init(line: "Phone by a socket", order: 94, x: 1185.6, y: 76.4),
        .init(line: "Phone by a socket", order: 95, x: 1199.4, y: 74.2),
        .init(line: "Phone by a socket", order: 96, x: 1213.3, y: 72.1),
        .init(line: "Phone by a socket", order: 97, x: 1227.1, y: 70.0),
        .init(line: "Phone by a socket", order: 98, x: 1240.9, y: 67.9),
        .init(line: "Phone by a socket", order: 99, x: 1254.7, y: 65.7),
        .init(line: "Phone by a socket", order: 100, x: 1268.6, y: 63.6),
        .init(line: "Phone by a socket", order: 101, x: 1282.4, y: 61.5),
        .init(line: "Phone by a socket", order: 102, x: 1296.2, y: 59.3),
        .init(line: "Phone by a socket", order: 103, x: 1310.1, y: 57.2),
        .init(line: "Phone by a socket", order: 104, x: 1323.9, y: 55.1),
        .init(line: "Phone by a socket", order: 105, x: 1337.8, y: 52.9),
        .init(line: "Phone by a socket", order: 106, x: 1351.6, y: 50.8),
        .init(line: "Phone by a socket", order: 107, x: 1365.4, y: 48.6),
        .init(line: "Phone by a socket", order: 108, x: 1379.3, y: 46.7),
        .init(line: "Phone by a socket", order: 109, x: 1393.3, y: 45.5),
        .init(line: "Phone by a socket", order: 110, x: 1407.2, y: 44.4),
        .init(line: "Phone by a socket", order: 111, x: 1421.2, y: 43.2),
        .init(line: "Phone by a socket", order: 112, x: 1435.1, y: 42.0),
        .init(line: "Phone by a socket", order: 113, x: 1449.1, y: 40.8),
        .init(line: "Phone by a socket", order: 114, x: 1463.0, y: 39.6),
        .init(line: "Phone by a socket", order: 115, x: 1477.0, y: 38.4),
        .init(line: "Phone by a socket", order: 116, x: 1490.9, y: 37.2),
        .init(line: "Phone by a socket", order: 117, x: 1504.9, y: 36.1),
        .init(line: "Phone by a socket", order: 118, x: 1518.9, y: 34.9),
        .init(line: "Phone by a socket", order: 119, x: 1532.8, y: 33.7),
        .init(line: "Phone by a socket", order: 120, x: 1546.8, y: 32.5),
        .init(line: "Phone by a socket", order: 121, x: 1560.8, y: 31.3),
        .init(line: "Phone by a socket", order: 122, x: 1574.8, y: 30.1),
        .init(line: "Phone by a socket", order: 123, x: 1588.7, y: 28.9),
        .init(line: "Phone by a socket", order: 124, x: 1602.7, y: 27.6),
        .init(line: "Phone by a socket", order: 125, x: 1616.7, y: 26.4),
        .init(line: "Phone by a socket", order: 126, x: 1630.7, y: 25.2),
        .init(line: "Phone by a socket", order: 127, x: 1644.7, y: 24.0),
        .init(line: "Phone by a socket", order: 128, x: 1658.7, y: 22.8),
        .init(line: "Phone by a socket", order: 129, x: 1672.6, y: 21.6),
        .init(line: "Phone by a socket", order: 130, x: 1686.6, y: 20.3),
        .init(line: "Phone by a socket", order: 131, x: 1700.6, y: 19.1),
        .init(line: "Phone by a socket", order: 132, x: 1714.6, y: 17.9),
        .init(line: "Phone by a socket", order: 133, x: 1728.6, y: 16.7),
        .init(line: "Phone by a socket", order: 134, x: 1742.6, y: 15.4),
        .init(line: "Phone by a socket", order: 135, x: 1756.6, y: 14.2),
        .init(line: "Phone by a socket", order: 136, x: 1770.6, y: 12.9),
        .init(line: "Phone by a socket", order: 137, x: 1784.7, y: 11.7),
        .init(line: "Phone by a socket", order: 138, x: 1798.7, y: 10.5),
        .init(line: "Phone by a socket", order: 139, x: 1812.7, y: 9.2),
        .init(line: "Phone by a socket", order: 140, x: 1826.7, y: 8.0),
        .init(line: "Phone by a socket", order: 141, x: 1840.7, y: 6.7),
        .init(line: "Phone by a socket", order: 142, x: 1854.7, y: 5.5),
        .init(line: "Phone by a socket", order: 143, x: 1868.8, y: 4.2),
        .init(line: "Phone by a socket", order: 144, x: 1882.8, y: 2.9),
        .init(line: "Phone by a socket", order: 145, x: 1896.4, y: -0.5),
        .init(line: "Phone by a socket", order: 146, x: 1909.5, y: -6.2),
        .init(line: "Phone by a socket", order: 147, x: 1922.6, y: -11.6),
        .init(line: "Phone by a socket", order: 148, x: 1936.5, y: -14.1),
        .init(line: "Phone by a socket", order: 149, x: 1950.4, y: -16.5),
        .init(line: "Phone by a socket", order: 150, x: 1964.3, y: -18.8),
        .init(line: "Phone by a socket", order: 151, x: 1978.3, y: -21.1),
        .init(line: "Phone by a socket", order: 152, x: 1992.3, y: -22.5),
        .init(line: "Phone by a socket", order: 153, x: 2006.4, y: -23.8),
        .init(line: "Phone by a socket", order: 154, x: 2020.4, y: -25.2),
        .init(line: "Phone by a socket", order: 155, x: 2034.5, y: -26.5),
        .init(line: "Phone by a socket", order: 156, x: 2048.5, y: -27.8),
        .init(line: "Phone by a socket", order: 157, x: 2062.6, y: -29.2),
        .init(line: "Phone by a socket", order: 158, x: 2076.6, y: -30.5),
        .init(line: "Phone by a socket", order: 159, x: 2090.7, y: -32.1),
        .init(line: "Phone by a socket", order: 160, x: 2104.6, y: -34.6),
        .init(line: "Phone by a socket", order: 161, x: 2118.6, y: -37.2),
        .init(line: "Phone by a socket", order: 162, x: 2132.5, y: -39.7),
        .init(line: "Phone by a socket", order: 163, x: 2146.5, y: -42.2),
        .init(line: "Phone by a socket", order: 164, x: 2160.4, y: -44.8),
        .init(line: "Phone by a socket", order: 165, x: 2174.4, y: -47.3),
        .init(line: "Phone by a socket", order: 166, x: 2188.3, y: -49.9),
        .init(line: "Phone by a socket", order: 167, x: 2202.3, y: -52.5),
        .init(line: "Phone by a socket", order: 168, x: 2216.2, y: -55.0),
        .init(line: "Phone by a socket", order: 169, x: 2230.2, y: -57.6),
        .init(line: "Phone by a socket", order: 170, x: 2244.2, y: -60.1),
        .init(line: "Phone by a socket", order: 171, x: 2258.2, y: -62.7),
        .init(line: "Phone by a socket", order: 172, x: 2272.1, y: -65.3),
        .init(line: "Phone by a socket", order: 173, x: 2286.1, y: -67.9),
        .init(line: "Phone by a socket", order: 174, x: 2300.1, y: -70.4),
        .init(line: "Phone by a socket", order: 175, x: 2314.1, y: -73.0),
        .init(line: "Phone by a socket", order: 176, x: 2328.1, y: -75.5),
        .init(line: "Phone by a socket", order: 177, x: 2342.1, y: -75.0),
        .init(line: "Phone by a socket", order: 178, x: 2356.2, y: -73.9),
        .init(line: "Phone by a socket", order: 179, x: 2370.2, y: -72.8),
        .init(line: "Phone by a socket", order: 180, x: 2384.2, y: -71.6),
        .init(line: "Phone by a socket", order: 181, x: 2398.3, y: -70.5),
        .init(line: "Phone by a socket", order: 182, x: 2412.3, y: -69.3),
        .init(line: "Phone by a socket", order: 183, x: 2426.4, y: -68.2),
        .init(line: "Phone by a socket", order: 184, x: 2440.4, y: -67.1),
        .init(line: "Phone by a socket", order: 185, x: 2454.5, y: -66.0),
        .init(line: "Phone by a socket", order: 186, x: 2468.5, y: -64.8),
        .init(line: "Phone by a socket", order: 187, x: 2482.6, y: -63.7),
        .init(line: "Phone by a socket", order: 188, x: 2496.6, y: -62.6),
        .init(line: "Phone by a socket", order: 189, x: 2510.7, y: -61.5),
        .init(line: "Phone by a socket", order: 190, x: 2524.8, y: -60.4),
        .init(line: "Phone by a socket", order: 191, x: 2538.8, y: -59.3),
        .init(line: "Phone by a socket", order: 192, x: 2552.9, y: -58.2),
        .init(line: "Phone by a socket", order: 193, x: 2567.0, y: -57.1),
        .init(line: "Phone by a socket", order: 194, x: 2581.1, y: -56.0),
        .init(line: "Phone by a socket", order: 195, x: 2595.1, y: -54.9),
        .init(line: "Phone by a socket", order: 196, x: 2609.2, y: -53.8),
        .init(line: "Phone by a socket", order: 197, x: 2623.3, y: -52.7),
        .init(line: "Phone by a socket", order: 198, x: 2637.4, y: -51.6),
        .init(line: "Phone by a socket", order: 199, x: 2651.5, y: -50.6),
        .init(line: "Phone by a socket", order: 200, x: 2665.6, y: -49.5),
        .init(line: "Phone by a socket", order: 201, x: 2679.7, y: -48.4),
        .init(line: "Phone by a socket", order: 202, x: 2693.8, y: -47.4),
        .init(line: "Phone by a socket", order: 203, x: 2707.1, y: -43.5),
        .init(line: "Phone by a socket", order: 204, x: 2717.6, y: -34.5),
        .init(line: "Phone by a socket", order: 205, x: 2728.2, y: -25.6),
        .init(line: "Phone by a socket", order: 206, x: 2738.8, y: -16.6),
        .init(line: "Phone by a socket", order: 207, x: 2749.3, y: -7.6),
        .init(line: "Phone by a socket", order: 208, x: 2759.9, y: 1.4),
        .init(line: "Phone by a socket", order: 209, x: 2770.5, y: 10.3),
        .init(line: "Phone by a socket", order: 210, x: 2781.1, y: 19.3),
        .init(line: "Phone by a socket", order: 211, x: 2791.6, y: 28.3),
        .init(line: "Phone by a socket", order: 212, x: 2802.2, y: 37.3),
        .init(line: "Phone by a socket", order: 213, x: 2812.8, y: 46.2),
        .init(line: "Phone by a socket", order: 214, x: 2823.3, y: 55.2),
        .init(line: "Phone by a socket", order: 215, x: 2833.9, y: 64.2),
        .init(line: "Phone by a socket", order: 216, x: 2844.5, y: 73.2),
        .init(line: "Phone by a socket", order: 217, x: 2854.8, y: 81.9),
        .init(line: "Phone by a socket", order: 218, x: 2864.7, y: 90.3),
        .init(line: "Phone by a socket", order: 219, x: 2874.3, y: 98.5),
        .init(line: "Phone by a socket", order: 220, x: 2883.8, y: 106.5),
        .init(line: "Phone by a socket", order: 221, x: 2890.6, y: 116.4),
        .init(line: "Phone by a socket", order: 222, x: 2894.0, y: 128.1),
        .init(line: "Phone by a socket", order: 223, x: 2900.3, y: 137.5),
        .init(line: "Phone by a socket", order: 224, x: 2911.3, y: 140.4),
        .init(line: "Phone by a socket", order: 225, x: 2922.5, y: 142.1),
        .init(line: "Phone by a socket", order: 226, x: 2933.3, y: 143.7),
        .init(line: "Phone by a socket", order: 227, x: 2943.8, y: 145.2),
        .init(line: "Phone by a socket", order: 228, x: 2953.8, y: 146.7),
        .init(line: "Phone by a socket", order: 229, x: 2963.5, y: 148.1),
        .init(line: "Phone by a socket", order: 230, x: 2972.8, y: 149.5),
        .init(line: "Phone by a socket", order: 231, x: 2981.8, y: 150.8),
        .init(line: "Phone by a socket", order: 232, x: 2990.6, y: 152.1),
        .init(line: "Phone by a socket", order: 233, x: 2999.1, y: 153.3),
        .init(line: "Phone by a socket", order: 234, x: 3007.3, y: 154.5),
        .init(line: "Phone by a socket", order: 235, x: 3022.8, y: 156.7),
        .init(line: "Phone by a socket", order: 236, x: 3036.8, y: 158.8),
        .init(line: "Phone by a socket", order: 237, x: 3049.8, y: 160.6),
        .init(line: "Phone by a socket", order: 238, x: 3061.9, y: 158.2),
        .init(line: "Phone by a socket", order: 239, x: 3073.2, y: 154.6),
        .init(line: "Phone by a socket", order: 240, x: 3082.4, y: 156.3),
        .init(line: "Phone by a socket", order: 241, x: 3074.2, y: 161.7),
        .init(line: "Phone by a socket", order: 242, x: 3071.3, y: 152.6),
        .init(line: "Phone by a socket", order: 243, x: 3079.7, y: 146.6),
        .init(line: "Phone by a socket", order: 244, x: 3088.6, y: 141.2),
        .init(line: "Phone by a socket", order: 245, x: 3097.5, y: 135.8),
        .init(line: "Phone by a socket", order: 246, x: 3106.6, y: 130.7),
        .init(line: "Phone by a socket", order: 247, x: 3109.4, y: 129.1)
    ]
    static let flightRouteStats = (realKm: 3506, appKm: 3295, inUseEndKm: 217, socketEndKm: 251, inUseEndOldKm: 889, socketEndOldKm: 2453)

    /// Speed through the flight back, km/h, every 2 minutes: ADS-B (the answer key; a gap is its chord's average), then the app.
    static let flightSpeed: [SpeedPoint] = [
        .init(minute: 0.0, line: "ADS-B", kmh: 0),
        .init(minute: 0.0, line: "The app", kmh: 0),
        .init(minute: 2.0, line: "ADS-B", kmh: 431),
        .init(minute: 2.0, line: "The app", kmh: 417),
        .init(minute: 4.0, line: "ADS-B", kmh: 537),
        .init(minute: 4.0, line: "The app", kmh: 534),
        .init(minute: 6.0, line: "ADS-B", kmh: 578),
        .init(minute: 6.0, line: "The app", kmh: 624),
        .init(minute: 8.0, line: "ADS-B", kmh: 722),
        .init(minute: 8.0, line: "The app", kmh: 684),
        .init(minute: 10.0, line: "ADS-B", kmh: 773),
        .init(minute: 10.0, line: "The app", kmh: 723),
        .init(minute: 12.0, line: "ADS-B", kmh: 835),
        .init(minute: 12.0, line: "The app", kmh: 756),
        .init(minute: 14.0, line: "ADS-B", kmh: 849),
        .init(minute: 14.0, line: "The app", kmh: 781),
        .init(minute: 16.0, line: "ADS-B", kmh: 933),
        .init(minute: 16.0, line: "The app", kmh: 799),
        .init(minute: 18.0, line: "ADS-B", kmh: 935),
        .init(minute: 18.0, line: "The app", kmh: 808),
        .init(minute: 20.0, line: "ADS-B", kmh: 936),
        .init(minute: 20.0, line: "The app", kmh: 811),
        .init(minute: 22.0, line: "ADS-B", kmh: 908),
        .init(minute: 22.0, line: "The app", kmh: 813),
        .init(minute: 24.0, line: "ADS-B", kmh: 926),
        .init(minute: 24.0, line: "The app", kmh: 816),
        .init(minute: 26.0, line: "ADS-B", kmh: 929),
        .init(minute: 26.0, line: "The app", kmh: 818),
        .init(minute: 28.0, line: "ADS-B", kmh: 924),
        .init(minute: 28.0, line: "The app", kmh: 820),
        .init(minute: 30.0, line: "ADS-B", kmh: 902),
        .init(minute: 30.0, line: "The app", kmh: 819),
        .init(minute: 32.0, line: "ADS-B", kmh: 893),
        .init(minute: 32.0, line: "The app", kmh: 821),
        .init(minute: 34.0, line: "ADS-B", kmh: 886),
        .init(minute: 34.0, line: "The app", kmh: 822),
        .init(minute: 36.0, line: "ADS-B", kmh: 886),
        .init(minute: 36.0, line: "The app", kmh: 823),
        .init(minute: 38.0, line: "ADS-B", kmh: 886),
        .init(minute: 38.0, line: "The app", kmh: 831),
        .init(minute: 40.0, line: "ADS-B", kmh: 886),
        .init(minute: 40.0, line: "The app", kmh: 831),
        .init(minute: 42.0, line: "ADS-B", kmh: 894),
        .init(minute: 42.0, line: "The app", kmh: 831),
        .init(minute: 44.0, line: "ADS-B", kmh: 894),
        .init(minute: 44.0, line: "The app", kmh: 831),
        .init(minute: 46.0, line: "ADS-B", kmh: 894),
        .init(minute: 46.0, line: "The app", kmh: 831),
        .init(minute: 48.0, line: "ADS-B", kmh: 894),
        .init(minute: 48.0, line: "The app", kmh: 831),
        .init(minute: 50.0, line: "ADS-B", kmh: 894),
        .init(minute: 50.0, line: "The app", kmh: 831),
        .init(minute: 52.0, line: "ADS-B", kmh: 894),
        .init(minute: 52.0, line: "The app", kmh: 831),
        .init(minute: 54.0, line: "ADS-B", kmh: 894),
        .init(minute: 54.0, line: "The app", kmh: 831),
        .init(minute: 56.0, line: "ADS-B", kmh: 894),
        .init(minute: 56.0, line: "The app", kmh: 831),
        .init(minute: 58.0, line: "ADS-B", kmh: 894),
        .init(minute: 58.0, line: "The app", kmh: 831),
        .init(minute: 60.0, line: "ADS-B", kmh: 894),
        .init(minute: 60.0, line: "The app", kmh: 831),
        .init(minute: 62.0, line: "ADS-B", kmh: 885),
        .init(minute: 62.0, line: "The app", kmh: 831),
        .init(minute: 64.0, line: "ADS-B", kmh: 882),
        .init(minute: 64.0, line: "The app", kmh: 831),
        .init(minute: 66.0, line: "ADS-B", kmh: 873),
        .init(minute: 66.0, line: "The app", kmh: 831),
        .init(minute: 68.0, line: "ADS-B", kmh: 873),
        .init(minute: 68.0, line: "The app", kmh: 831),
        .init(minute: 70.0, line: "ADS-B", kmh: 870),
        .init(minute: 70.0, line: "The app", kmh: 831),
        .init(minute: 72.0, line: "ADS-B", kmh: 872),
        .init(minute: 72.0, line: "The app", kmh: 831),
        .init(minute: 74.0, line: "ADS-B", kmh: 872),
        .init(minute: 74.0, line: "The app", kmh: 831),
        .init(minute: 76.0, line: "ADS-B", kmh: 869),
        .init(minute: 76.0, line: "The app", kmh: 831),
        .init(minute: 78.0, line: "ADS-B", kmh: 868),
        .init(minute: 78.0, line: "The app", kmh: 831),
        .init(minute: 80.0, line: "ADS-B", kmh: 867),
        .init(minute: 80.0, line: "The app", kmh: 831),
        .init(minute: 82.0, line: "ADS-B", kmh: 868),
        .init(minute: 82.0, line: "The app", kmh: 831),
        .init(minute: 84.0, line: "ADS-B", kmh: 872),
        .init(minute: 84.0, line: "The app", kmh: 831),
        .init(minute: 86.0, line: "ADS-B", kmh: 875),
        .init(minute: 86.0, line: "The app", kmh: 831),
        .init(minute: 88.0, line: "ADS-B", kmh: 880),
        .init(minute: 88.0, line: "The app", kmh: 831),
        .init(minute: 90.0, line: "ADS-B", kmh: 884),
        .init(minute: 90.0, line: "The app", kmh: 831),
        .init(minute: 92.0, line: "ADS-B", kmh: 883),
        .init(minute: 92.0, line: "The app", kmh: 831),
        .init(minute: 94.0, line: "ADS-B", kmh: 882),
        .init(minute: 94.0, line: "The app", kmh: 831),
        .init(minute: 96.0, line: "ADS-B", kmh: 880),
        .init(minute: 96.0, line: "The app", kmh: 831),
        .init(minute: 98.0, line: "ADS-B", kmh: 885),
        .init(minute: 98.0, line: "The app", kmh: 831),
        .init(minute: 100.0, line: "ADS-B", kmh: 884),
        .init(minute: 100.0, line: "The app", kmh: 831),
        .init(minute: 102.0, line: "ADS-B", kmh: 887),
        .init(minute: 102.0, line: "The app", kmh: 831),
        .init(minute: 104.0, line: "ADS-B", kmh: 880),
        .init(minute: 104.0, line: "The app", kmh: 831),
        .init(minute: 106.0, line: "ADS-B", kmh: 885),
        .init(minute: 106.0, line: "The app", kmh: 831),
        .init(minute: 108.0, line: "ADS-B", kmh: 886),
        .init(minute: 108.0, line: "The app", kmh: 831),
        .init(minute: 110.0, line: "ADS-B", kmh: 891),
        .init(minute: 110.0, line: "The app", kmh: 831),
        .init(minute: 112.0, line: "ADS-B", kmh: 887),
        .init(minute: 112.0, line: "The app", kmh: 831),
        .init(minute: 114.0, line: "ADS-B", kmh: 888),
        .init(minute: 114.0, line: "The app", kmh: 831),
        .init(minute: 116.0, line: "ADS-B", kmh: 886),
        .init(minute: 116.0, line: "The app", kmh: 831),
        .init(minute: 118.0, line: "ADS-B", kmh: 876),
        .init(minute: 118.0, line: "The app", kmh: 831),
        .init(minute: 120.0, line: "ADS-B", kmh: 888),
        .init(minute: 120.0, line: "The app", kmh: 831),
        .init(minute: 122.0, line: "ADS-B", kmh: 875),
        .init(minute: 122.0, line: "The app", kmh: 831),
        .init(minute: 124.0, line: "ADS-B", kmh: 875),
        .init(minute: 124.0, line: "The app", kmh: 831),
        .init(minute: 126.0, line: "ADS-B", kmh: 875),
        .init(minute: 126.0, line: "The app", kmh: 831),
        .init(minute: 128.0, line: "ADS-B", kmh: 875),
        .init(minute: 128.0, line: "The app", kmh: 831),
        .init(minute: 130.0, line: "ADS-B", kmh: 875),
        .init(minute: 130.0, line: "The app", kmh: 831),
        .init(minute: 132.0, line: "ADS-B", kmh: 875),
        .init(minute: 132.0, line: "The app", kmh: 831),
        .init(minute: 134.0, line: "ADS-B", kmh: 875),
        .init(minute: 134.0, line: "The app", kmh: 831),
        .init(minute: 136.0, line: "ADS-B", kmh: 875),
        .init(minute: 136.0, line: "The app", kmh: 831),
        .init(minute: 138.0, line: "ADS-B", kmh: 875),
        .init(minute: 138.0, line: "The app", kmh: 831),
        .init(minute: 140.0, line: "ADS-B", kmh: 875),
        .init(minute: 140.0, line: "The app", kmh: 831),
        .init(minute: 142.0, line: "ADS-B", kmh: 875),
        .init(minute: 142.0, line: "The app", kmh: 831),
        .init(minute: 144.0, line: "ADS-B", kmh: 875),
        .init(minute: 144.0, line: "The app", kmh: 831),
        .init(minute: 146.0, line: "ADS-B", kmh: 875),
        .init(minute: 146.0, line: "The app", kmh: 831),
        .init(minute: 148.0, line: "ADS-B", kmh: 875),
        .init(minute: 148.0, line: "The app", kmh: 831),
        .init(minute: 150.0, line: "ADS-B", kmh: 875),
        .init(minute: 150.0, line: "The app", kmh: 831),
        .init(minute: 152.0, line: "ADS-B", kmh: 875),
        .init(minute: 152.0, line: "The app", kmh: 831),
        .init(minute: 154.0, line: "ADS-B", kmh: 875),
        .init(minute: 154.0, line: "The app", kmh: 831),
        .init(minute: 156.0, line: "ADS-B", kmh: 875),
        .init(minute: 156.0, line: "The app", kmh: 831),
        .init(minute: 158.0, line: "ADS-B", kmh: 875),
        .init(minute: 158.0, line: "The app", kmh: 831),
        .init(minute: 160.0, line: "ADS-B", kmh: 875),
        .init(minute: 160.0, line: "The app", kmh: 831),
        .init(minute: 162.0, line: "ADS-B", kmh: 875),
        .init(minute: 162.0, line: "The app", kmh: 831),
        .init(minute: 164.0, line: "ADS-B", kmh: 875),
        .init(minute: 164.0, line: "The app", kmh: 831),
        .init(minute: 166.0, line: "ADS-B", kmh: 875),
        .init(minute: 166.0, line: "The app", kmh: 831),
        .init(minute: 168.0, line: "ADS-B", kmh: 875),
        .init(minute: 168.0, line: "The app", kmh: 831),
        .init(minute: 170.0, line: "ADS-B", kmh: 875),
        .init(minute: 170.0, line: "The app", kmh: 831),
        .init(minute: 172.0, line: "ADS-B", kmh: 875),
        .init(minute: 172.0, line: "The app", kmh: 831),
        .init(minute: 174.0, line: "ADS-B", kmh: 875),
        .init(minute: 174.0, line: "The app", kmh: 831),
        .init(minute: 176.0, line: "ADS-B", kmh: 875),
        .init(minute: 176.0, line: "The app", kmh: 831),
        .init(minute: 178.0, line: "ADS-B", kmh: 872),
        .init(minute: 178.0, line: "The app", kmh: 831),
        .init(minute: 180.0, line: "ADS-B", kmh: 862),
        .init(minute: 180.0, line: "The app", kmh: 831),
        .init(minute: 182.0, line: "ADS-B", kmh: 866),
        .init(minute: 182.0, line: "The app", kmh: 831),
        .init(minute: 184.0, line: "ADS-B", kmh: 867),
        .init(minute: 184.0, line: "The app", kmh: 831),
        .init(minute: 186.0, line: "ADS-B", kmh: 870),
        .init(minute: 186.0, line: "The app", kmh: 831),
        .init(minute: 188.0, line: "ADS-B", kmh: 869),
        .init(minute: 188.0, line: "The app", kmh: 831),
        .init(minute: 190.0, line: "ADS-B", kmh: 871),
        .init(minute: 190.0, line: "The app", kmh: 831),
        .init(minute: 192.0, line: "ADS-B", kmh: 873),
        .init(minute: 192.0, line: "The app", kmh: 831),
        .init(minute: 194.0, line: "ADS-B", kmh: 867),
        .init(minute: 194.0, line: "The app", kmh: 831),
        .init(minute: 196.0, line: "ADS-B", kmh: 866),
        .init(minute: 196.0, line: "The app", kmh: 831),
        .init(minute: 198.0, line: "ADS-B", kmh: 865),
        .init(minute: 198.0, line: "The app", kmh: 831),
        .init(minute: 200.0, line: "ADS-B", kmh: 860),
        .init(minute: 200.0, line: "The app", kmh: 831),
        .init(minute: 202.0, line: "ADS-B", kmh: 863),
        .init(minute: 202.0, line: "The app", kmh: 831),
        .init(minute: 204.0, line: "ADS-B", kmh: 865),
        .init(minute: 204.0, line: "The app", kmh: 831),
        .init(minute: 206.0, line: "ADS-B", kmh: 864),
        .init(minute: 206.0, line: "The app", kmh: 831),
        .init(minute: 208.0, line: "ADS-B", kmh: 828),
        .init(minute: 208.0, line: "The app", kmh: 831),
        .init(minute: 210.0, line: "ADS-B", kmh: 822),
        .init(minute: 210.0, line: "The app", kmh: 831),
        .init(minute: 212.0, line: "ADS-B", kmh: 809),
        .init(minute: 212.0, line: "The app", kmh: 831),
        .init(minute: 214.0, line: "ADS-B", kmh: 754),
        .init(minute: 214.0, line: "The app", kmh: 831),
        .init(minute: 216.0, line: "ADS-B", kmh: 721),
        .init(minute: 216.0, line: "The app", kmh: 831),
        .init(minute: 218.0, line: "ADS-B", kmh: 699),
        .init(minute: 218.0, line: "The app", kmh: 831),
        .init(minute: 220.0, line: "ADS-B", kmh: 702),
        .init(minute: 220.0, line: "The app", kmh: 768),
        .init(minute: 222.0, line: "ADS-B", kmh: 692),
        .init(minute: 222.0, line: "The app", kmh: 738),
        .init(minute: 224.0, line: "ADS-B", kmh: 679),
        .init(minute: 224.0, line: "The app", kmh: 706),
        .init(minute: 226.0, line: "ADS-B", kmh: 646),
        .init(minute: 226.0, line: "The app", kmh: 671),
        .init(minute: 228.0, line: "ADS-B", kmh: 641),
        .init(minute: 228.0, line: "The app", kmh: 635),
        .init(minute: 230.0, line: "ADS-B", kmh: 641),
        .init(minute: 230.0, line: "The app", kmh: 585),
        .init(minute: 232.0, line: "ADS-B", kmh: 642),
        .init(minute: 232.0, line: "The app", kmh: 543),
        .init(minute: 234.0, line: "ADS-B", kmh: 626),
        .init(minute: 234.0, line: "The app", kmh: 511),
        .init(minute: 236.0, line: "ADS-B", kmh: 612),
        .init(minute: 236.0, line: "The app", kmh: 479),
        .init(minute: 238.0, line: "ADS-B", kmh: 532),
        .init(minute: 238.0, line: "The app", kmh: 437),
        .init(minute: 240.0, line: "ADS-B", kmh: 517),
        .init(minute: 240.0, line: "The app", kmh: 397),
        .init(minute: 242.0, line: "ADS-B", kmh: 523),
        .init(minute: 242.0, line: "The app", kmh: 370),
        .init(minute: 244.0, line: "ADS-B", kmh: 517),
        .init(minute: 244.0, line: "The app", kmh: 344),
        .init(minute: 246.0, line: "ADS-B", kmh: 498),
        .init(minute: 246.0, line: "The app", kmh: 331),
        .init(minute: 248.0, line: "ADS-B", kmh: 461),
        .init(minute: 248.0, line: "The app", kmh: 306),
        .init(minute: 250.0, line: "ADS-B", kmh: 462),
        .init(minute: 250.0, line: "The app", kmh: 297),
        .init(minute: 252.0, line: "ADS-B", kmh: 427),
        .init(minute: 252.0, line: "The app", kmh: 290),
        .init(minute: 254.0, line: "ADS-B", kmh: 404),
        .init(minute: 254.0, line: "The app", kmh: 290),
        .init(minute: 256.0, line: "ADS-B", kmh: 357),
        .init(minute: 256.0, line: "The app", kmh: 290),
        .init(minute: 258.0, line: "ADS-B", kmh: 290),
        .init(minute: 258.0, line: "The app", kmh: 290),
        .init(minute: 260.0, line: "ADS-B", kmh: 258),
        .init(minute: 260.0, line: "The app", kmh: 290)
    ]
    static let flightPhases = (climbEndHour: 0.52, descentHour: 3.53, share: 94, climbErr: 80, cruiseErr: 44, descentErr: 102)

    /// Every data-dependent number the paper's text quotes (tables/numbers.tex), for the page's own text.
    enum Num {
        static let AblBigA = "9"
        static let AblBigC = "7"
        static let AblBigF = "5"
        static let AblBigG = "5"
        static let AblCarRtA = "68"
        static let AblCarRtC = "79"
        static let AblCarRtF = "83"
        static let AblCarRtG = "89"
        static let AblCarSecA = "67"
        static let AblCarSecB = "68"
        static let AblCarSecC = "69"
        static let AblCarSecD = "70"
        static let AblCarSecE = "65"
        static let AblCarSecF = "67"
        static let AblCarSecG = "78"
        static let AblFlA = "86"
        static let AblFlB = "99"
        static let AblGate = "+3"
        static let AblMag = "-5"
        static let AblMotoSpan = "1"
        static let AblPush = "+0"
        static let AblTurn = "+11"
        static let AppDownTxt = ", and the 47 seconds of one journey in which iOS had ended the app"
        static let BothAppKm = "781"
        static let BothGpsKm = "854"
        static let BothShort = "8.6"
        static let CarAppKm = "497"
        static let CarBandEightyApp = "59"
        static let CarBandEightyGps = "94"
        static let CarBandSixtyApp = "64"
        static let CarBandSixtyGps = "70"
        static let CarBandTenApp = "15"
        static let CarBandTenGps = "15"
        static let CarBandThirtyApp = "33"
        static let CarBandThirtyGps = "35"
        static let CarBandTwentyApp = "24"
        static let CarBandTwentyGps = "25"
        static let CarDirMed = "15"
        static let CarDirRec = "53"
        static let CarDist = "-9.0"
        static let CarDistTxt = "9.0% short"
        static let CarDrift = "17"
        static let CarGpsKm = "546"
        static let CarHalf = "1,955"
        static let CarHours = "23.6"
        static let CarMae = "7.8"
        static let CarMedJourneyTxt = "0.6% short"
        static let CarMidMax = "3"
        static let CarNinety = "56"
        static let CarParks = "17"
        static let CarRec = "62"
        static let CarRoutes = "53"
        static let CarRtBig = "1"
        static let CarRtBigShort = "0"
        static let CarRtMed = "12"
        static let CarRtWthirty = "89"
        static let CarSize = "0.98"
        static let CarWthirty = "78"
        static let CarWtwenty = "77"
        static let CleanSampFifteen = "62"
        static let CleanSampMed = "12"
        static let CleanSampN = "3268"
        static let CleanSampRecs = "33"
        static let CleanSampWorst = "171"
        static let EchoBetter = "26"
        static let EchoN = "143"
        static let EchoNow = "+9.1"
        static let EchoOldN = "49"
        static let EchoOver = "45"
        static let EchoPedLiveTxt = "0.5% more"
        static let EchoPedN = "84"
        static let EchoPedRec = "23"
        static let EchoPedWtwenty = "58"
        static let EchoScaled = "+0.3"
        static let EchoWorse = "4"
        static let EchoWorseTxt = "all of them already short"
        static let EchoWtwentyNow = "43"
        static let EchoWtwentyScaled = "53"
        static let FadeMoto = "60"
        static let FastDriveCarWithout = "81"
        static let FastDriveDist = "71"
        static let FastDriveDrift = "3.8"
        static let FastDriveFast = "55"
        static let FastDriveKm = "45"
        static let FastDriveStopped = "20"
        static let FastDriveW = "32"
        static let FifthMagD = "100"
        static let FifthMagG = "99"
        static let FifthMagTurn = "168"
        static let FirstMagF = "90"
        static let FirstMagG = "94"
        static let FlAir = "13"
        static let FlAirOld = "39"
        static let FlEnd = "17"
        static let FlEndNet = "19.2"
        static let FlEndShare = "26"
        static let FlEndStore = "18.8"
        static let FlGround = "8"
        static let FlMainShare = "102.8"
        static let FlMissPush = "1"
        static let FlMissRunway = "11"
        static let FlMisses = "12"
        static let FlNetShare = "102.9"
        static let FlOffset = "14"
        static let FlRouteMed = "1.0"
        static let FlSpeedDiff = "3.5"
        static let FlWithin = "3"
        static let ForgetDeclHi = "47"
        static let ForgetDeclLo = "44"
        static let ForgetLiveA = "36"
        static let ForgetLiveB = "58"
        static let ForgetNetA = "64"
        static let ForgetNetB = "88"
        static let GpsFlightKm = "74.1"
        static let GpsModeTxt = "One car journey was recorded with the app measuring by GPS, so the app made no walking decisions in it; it was replayed as a car and, from the first step after the car stopped, as walking, as described when recorded, with GPS from every fix the phone logged."
        static let GuardMin = "23"
        static let GuardN = "24"
        static let GuardSwitches = "37"
        static let HandDist = "77"
        static let HandFastApp = "31"
        static let HandFastGps = "65"
        static let HandFlagged = "83"
        static let HandMae = "13.7"
        static let HandSteady = "66"
        static let HoldAirErr = "196"
        static let HoldKm = "45.2"
        static let HoldShare = "61"
        static let Hours = "42"
        static let Journeys = "127"
        static let KmChecked = "854"
        static let LongDriftEarth = "92"
        static let LongDriftEvery = "44"
        static let LongDriftNone = "86"
        static let LongDriveF = "92"
        static let LongDriveG = "92"
        static let LongDriveTurn = "0"
        static let MagCars = "29"
        static let MagMotos = "26"
        static let MagOffD = "33"
        static let MagOffE = "21"
        static let MagOtherTxt = " and one other recording"
        static let MagPooledF = "69"
        static let MagPooledG = "79"
        static let MagRecs = "56"
        static let MagRecsTurn = "44"
        static let MagSafeClean = "51"
        static let MagSafeF = "53"
        static let MagSafeG = "100"
        static let MagSafeTurn = "27"
        static let MagSafeTxt = "and with them the seconds within 30° rose from 53% to 100%"
        static let MagWD = "35"
        static let MagWE = "91"
        static let MainCarMae = "7.8"
        static let MainCarShare = "91.0"
        static let MainMotoMae = "8.7"
        static let MainMotoShare = "92.3"
        static let MotoAppKm = "285"
        static let MotoBandEightyApp = "44"
        static let MotoBandEightyGps = "94"
        static let MotoBandSixtyApp = "41"
        static let MotoBandSixtyGps = "65"
        static let MotoBandTenApp = "19"
        static let MotoBandTenGps = "15"
        static let MotoBandThirtyApp = "33"
        static let MotoBandThirtyGps = "35"
        static let MotoBandTwentyApp = "28"
        static let MotoBandTwentyGps = "25"
        static let MotoDirMed = "14"
        static let MotoDirRec = "67"
        static let MotoDist = "-7.7"
        static let MotoDistTxt = "7.7% short"
        static let MotoDrift = "14"
        static let MotoFourClean = "13"
        static let MotoFourG = "90"
        static let MotoFourTurn = "0"
        static let MotoGpsKm = "308"
        static let MotoHalf = "1,406"
        static let MotoHours = "18.2"
        static let MotoMae = "8.7"
        static let MotoMagClean = "88"
        static let MotoMagD = "77"
        static let MotoMagF = "78"
        static let MotoMagG = "73"
        static let MotoMagN = "74"
        static let MotoMagTurn = "5"
        static let MotoMedJourneyTxt = "6.1% short"
        static let MotoMidMax = "14"
        static let MotoNinety = "50"
        static let MotoRec = "65"
        static let MotoRoutes = "68"
        static let MotoRtBig = "4"
        static let MotoRtBigShort = "3"
        static let MotoRtMed = "8"
        static let MotoRtWthirty = "88"
        static let MotoSize = "0.90"
        static let MotoThreeD = "81"
        static let MotoThreeG = "81"
        static let MotoTwoG = "24"
        static let MotoWthirty = "77"
        static let MotoWtwenty = "73"
        static let NetAirErr = "38"
        static let NetAll = "8.1"
        static let NetCarMae = "7.6"
        static let NetCarShare = "91.3"
        static let NetCloser = "47"
        static let NetKm = "76.2"
        static let NetMotoMae = "8.9"
        static let NetMotoShare = "93.5"
        static let NetShare = "103"
        static let NetVsStore = "a little less accurate than"
        static let PlaneDirMed = "13"
        static let PlaneDist = "+2.8"
        static let PlaneWthirty = "99"
        static let PocketCar = "0"
        static let PocketCarN = "63"
        static let PocketMoto = "60"
        static let PocketMotoN = "69"
        static let RecDiff = "7"
        static let RecN = "12"
        static let SixthMagD = "97"
        static let SixthMagG = "85"
        static let SixthMagTurn = "152"
        static let SlowAppPct = "100"
        static let SlowGraded = "87"
        static let SlowReplayHigh = "100"
        static let SlowReplayLow = "100"
        static let SlowReplayPct = "100"
        static let SlowReplayRuns = "2"
        static let SlowReplayTxt = "over the last 2 re-runs, which differed only in the journeys added, 100% of those seconds were within 30° each time"
        static let StepRideBig = "7"
        static let StepRideGps = "14.6"
        static let StepRideLive = "2.1"
        static let StepRideN = "29"
        static let StepRideNowGps = "8.9"
        static let StepRideNowN = "22"
        static let StepRideWorst = "79"
        static let StoreAirErr = "37"
        static let StoreCloser = "24"
        static let StoreFourK = "7.9"
        static let StoreKm = "73.6"
        static let StoreShare = "99"
        static let StoreSixty = "10.4"
        static let StoreSmallMotoHi = "24"
        static let StoreSmallMotoLo = "20"
        static let StoreThousand = "8.8"
        static let StoreVsNet = "a little ahead of"
        static let TaxiApp = "13"
        static let TaxiGps = "18"
        static let ThirdMagF = "79"
        static let ThirdMagG = "78"
        static let ThirdMagTurn = "3"
        static let ThreeHourCarWithout = "6.9% short"
        static let ThreeHourDist = "82"
        static let ThreeHourFastRead = "70"
        static let ThreeHourFastShare = "63"
        static let ThreeHourKm = "105"
        static let ThreeHourSlowRead = "103"
        static let ThreeHourW = "70"
        static let TurnBig = "40"
        static let TurnFixed = "85"
        static let TurnMedFixed = "9.3"
        static let TurnMedNow = "14.7"
        static let TurnN = "120"
        static let TurnNow = "78"
        static let TurnSampFifteen = "81"
        static let TurnSampMed = "7"
        static let TurnSampN = "1626"
        static let TurnSampRecs = "31"
        static let TurnSampWorst = "68"
        static let WalkAfterTxt = "4% more"
        static let WalkApp = "4.8"
        static let WalkDirMed = "10"
        static let WalkDist = "-0.3"
        static let WalkDistTxt = "about the same"
        static let WalkGps = "4.5"
        static let WalkOtherTxt = "9% less"
        static let WalkShare = "99.7"
        static let WalkStretches = "143"
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
                // Each cell is the app's middle reading over GPS's, so say so in the header.
                Text("motorcycle\napp / GPS").font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 84, alignment: .trailing)
                Text("car\napp / GPS").font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
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

/// Horizontal bars with the name and value inside the row, so nothing depends on where a chart
/// library puts its axis labels. Ticks sit centred under their grid lines; the dashed line marks
/// the reference (GPS = 100%).
private struct BarRows: View {
    struct Row: Identifiable {
        let id = UUID(); let name: String; let value: Double; let label: String; let color: Color
    }
    let rows: [Row]
    let domain: Double
    let ticks: [Double]
    let reference: Double?
    let axisLabel: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.name).font(.caption)
                        Spacer(minLength: 8)
                        Text(r.label).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    track { w in
                        Capsule().fill(r.color)
                            .frame(width: max(4, w * min(r.value, domain) / domain), height: 12)
                    }
                    .frame(height: 12)
                }
                .accessibilityElement(children: .combine)
            }
            if !typeSize.isAccessibilitySize {
                GeometryReader { g in
                    ForEach(ticks, id: \.self) { t in
                        Text(Int(t).formatted()).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            .fixedSize()
                            .position(x: g.size.width * t / domain, y: 7)
                    }
                }
                .frame(height: 14)
                .padding(.horizontal, 8)
                .accessibilityHidden(true)
            }
            Text(axisLabel).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// The grid and reference line behind one bar, inset so the end tick labels fit.
    private func track<Bar: View>(@ViewBuilder bar: @escaping (CGFloat) -> Bar) -> some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 12)
                ForEach(ticks.filter { $0 > 0 && $0 != reference }, id: \.self) { t in
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1, height: 12)
                        .offset(x: w * t / domain)
                }
                bar(w)
                if let ref = reference {
                    Path { p in
                        p.move(to: CGPoint(x: w * ref / domain, y: -3))
                        p.addLine(to: CGPoint(x: w * ref / domain, y: 15))
                    }
                    .stroke(Color.primary.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

/// X-axis numbers centred under their grid lines. Swift Charts on iOS 26 put them beside the line; the
/// real labels are kept, invisible, so the chart still leaves their room and the axis title stays below.
private extension View {
    func centeredXLabels(_ ticks: [Double]) -> some View {
        chartXAxis {
            AxisMarks(values: ticks) {
                AxisGridLine(); AxisTick()
                AxisValueLabel().foregroundStyle(Color.clear)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                if let anchor = proxy.plotFrame {
                    let plot = g[anchor]
                    ForEach(ticks, id: \.self) { t in
                        if let x = proxy.position(forX: t) {
                            Text(Int(t).formatted()).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                .fixedSize()
                                .position(x: plot.minX + x, y: plot.maxY + 12)
                        }
                    }
                }
            }
            .accessibilityHidden(true)
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
