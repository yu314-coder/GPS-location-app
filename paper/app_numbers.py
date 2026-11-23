"""Write the paper's numbers into the app's "How Velocity Mode works" page.

The table generator writes tables/numbers.json next to the LaTeX tables, from the same re-run. This
script turns it into the Swift data between the GENERATED markers in
GPS location app/ViewControllers/VelocityMethodView.swift, so the page shows exactly what the paper
does. Run it after the tables change:

    python3 paper/app_numbers.py
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT = os.path.join(HERE, '..', 'GPS location app', 'ViewControllers', 'VelocityMethodView.swift')
BEGIN, END = '    // BEGIN GENERATED (paper/app_numbers.py)\n', '    // END GENERATED\n'

J = json.load(open(os.path.join(HERE, 'tables', 'numbers.json')))
M, C, W, P = (J['categories'][k] for k in ('motorcycle', 'car', 'walking', 'plane'))
# The plane since build 118: three flights, two graded by their ADS-B tracks (tables/numbers_flight.tex).
import re as _re0
F = {k: v.replace('{,}', ',') for k, v in
     _re0.findall(r"\\newcommand\{\\n(\w+)\}\{((?:[^{}]|\{[^{}]*\})*)\}", open(os.path.join(HERE, 'tables', 'numbers_flight.tex')).read())}
_short_pct = (float(F['AirShortPooledKm']) / float(F['AirShortKm']) - 1) * 100
# The two four-hour flights graded by ADS-B (paper7_flight.py writes tables/app_flight.json from the same replay).
AF = json.load(open(os.path.join(HERE, 'tables', 'app_flight.json')))
LG = AF['long']
_out_pct = (LG['out_app_km'] / LG['out_km'] - 1) * 100
_ret_pct = (LG['ret_app_km'] / LG['ret_km'] - 1) * 100
_nasa_pct = (LG['out_nasa_km'] / LG['out_km'] - 1) * 100
_long_app, _long_real = LG['out_app_km'] + LG['ret_app_km'], LG['out_km'] + LG['ret_km']


def signed(x, digits=1):
    s = f"{abs(x):.{digits}f}%"
    return ('+' if x >= 0 else '−') + s


def q(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def km(x):
    return f"{x:,.1f}" if x >= 10 else f"{x:.2f}"


lines = []
add = lines.append

add('    static let overview: [Overview] = [')
add(f'        .init(name: "Motorcycle", recorded: {q(f"{M["recordings"]} recordings, {M["hours"]:.1f} hours, {M["gps_km_whole"]} km checked by GPS; phone in a trouser pocket")},')
add(f'              distance: {q(signed(M["total_pct"]))}, speed: {q(f"{M["speed_mae"]:.1f} km/h")}, speedLabel: "average speed error",')
add(f'              direction: {q(f"{M["dir_within30"]}%")}),')
add(f'        .init(name: "Car", recorded: {q(f"{C["recordings"]} recordings, {C["hours"]:.1f} hours, {C["gps_km_whole"]} km checked by GPS; phone in a pocket, flat or in a mount")},')
add(f'              distance: {q(signed(C["total_pct"]))}, speed: {q(f"{C["speed_mae"]:.1f} km/h")}, speedLabel: "average speed error",')
add(f'              direction: {q(f"{C["dir_within30"]}%")}),')
add(f'        .init(name: "Walking", recorded: {q(f"{W["stretches"]} straight stretches and {W["walks"]} walks; phone in a pocket, distance counted by steps")},')
add(f'              distance: {q(signed(W["total_pct"]))}, speed: {q(f"{W["speed_app"]:.1f} km/h")}, speedLabel: {q(f"where GPS measured {W["speed_gps"]:.1f}")},')
add(f'              direction: {q(f"{W["dir_within30"]}%")}),')
add(f'        .init(name: "Plane", recorded: {q(f"3 flights: two of four hours graded by their ADS-B tracks ({F["AirLongKm"]} and {F["AirRetKm"]} km), one short one by GPS; the takeoff measured, then the typical flight")},')
add(f'              distance: {q(signed(int(F["AirLongShare"]) - 100, 0) + " / " + signed(int(F["AirRetShare"]) - 100, 0))}, speed: {q(F["AirLongCruise"] + " km/h")}, speedLabel: "typical error in the cruise",')
add(f'              direction: {q(F["AirDirAllW"] + "%")})')
add('    ]')
add('')
add('    static let distance: [Distance] = [')
add(f'        .init(name: "Motorcycle", detail: {q(f"{M["recordings"]} journeys, {M["within20"]}% within 20%")},')
add(f'              appKm: {M["app_km"]}, gpsKm: {M["gps_km"]}, errorPercent: {M["total_pct"]}),')
add(f'        .init(name: "Car", detail: {q(f"{C["recordings"]} journeys, {C["within20"]}% within 20%")},')
add(f'              appKm: {C["app_km"]}, gpsKm: {C["gps_km"]}, errorPercent: {C["total_pct"]}),')
add(f'        .init(name: "Walking", detail: {q(f"{W["stretches"]} straight stretches, counted by steps")},')
add(f'              appKm: {W["app_km"]}, gpsKm: {W["gps_km"]}, errorPercent: {W["total_pct"]}),')
add(f'        .init(name: "Plane", detail: "two four-hour flights against their ADS-B tracks",')
add(f'              appKm: {_long_app:.0f}, gpsKm: {_long_real:.0f}, errorPercent: {(_long_app / _long_real - 1) * 100:.1f})')
add('    ]')
add('')
add('    static let speedBands: [SpeedBand] = [')
rows = []
for b in J['speed_bands']:
    m, c = b['motorcycle'], b['car']
    plotted = b['band'] != '80+'
    rows.append(f'        .init(band: {q(b["band"])}, motorcycleGPS: {m["gps"]}, motorcycleApp: {m["app"]}, '
                f'carGPS: {c["gps"]}, carApp: {c["app"]}' + ('' if plotted else ', plotted: false') + ')')
add(',\n'.join(rows))
add('    ]')
add('')
add('    static let direction: [Direction] = [')
add(f'        .init(name: "Motorcycle", graded: "{M["dir_recordings"]} recordings", medianDegrees: {M["dir_median"]}, within30: {M["dir_within30"]}),')
add(f'        .init(name: "Car", graded: "{C["dir_recordings"]} recordings", medianDegrees: {C["dir_median"]}, within30: {C["dir_within30"]}),')
add(f'        .init(name: "Walking", graded: "{W["walks"]} walks", medianDegrees: {W["dir_median"]}, within30: {W["dir_within30"]}),')
add(f'        .init(name: "Plane", graded: "6 recordings, 3 flights", medianDegrees: {F["AirDirAll"]}, within30: {F["AirDirAllW"]})')
add('    ]')
add('')
add('    /// Distance in the air, replayed with no GPS through the app\'s own code: the way it reads speed now on')
add('    /// all three flights, then the ways it replaced, on the four-hour flight out.')
add('    static let flight: [FlightPoint] = [')
_fl = [('Four hours out, against ADS-B', _out_pct, True), ('Four hours back, against ADS-B', _ret_pct, True),
       ('Short flight, against GPS', _short_pct, True),
       ('Out: NASA medians alone', _nasa_pct, False),
       ('Out: tilt engines, phone in a hand', int(F['AirTiltHand']) - 100, False),
       ('Out: tilt engines, phone in a bag', int(F['AirTiltBag']) - 100, False)]
add(',\n'.join(f'        .init(point: {q(n)}, errorPercent: {e:.1f}' + (', current: true)' if c else ')') for n, e, c in _fl))
add('    ]')
add('')
add('    /// The four-hour flight back drawn with no GPS from the takeoff roll on, in the paper\'s km frame turned by an')
add('    /// arbitrary angle: the ADS-B track (a coverage gap is its straight chord) and the app on two phones. Every ~8 km.')
add('    static let flightRoute: [RoutePoint] = [')
rows = []
for name, pts in AF['ret_route'].items():
    for i, (x, y) in enumerate(pts):
        rows.append(f'        .init(line: {q(name)}, order: {i}, x: {x}, y: {y})')
add(',\n'.join(rows))
add('    ]')
add(f'    static let flightRouteStats = (realKm: {LG["ret_km"]:.0f}, appKm: {LG["ret_app_km"]:.0f}, '
    f'inUseEndKm: {F["AirEndRetPro"].replace(",", "")}, socketEndKm: {F["AirEndRetPhone"].replace(",", "")}, '
    f'inUseEndOldKm: {F["AirEndRetProOld"].replace(",", "")}, socketEndOldKm: {F["AirEndRetPhoneOld"].replace(",", "")})')
add('')
add('    /// Speed through the flight back, km/h, every 2 minutes: ADS-B (the answer key; a gap is its chord\'s average), then the app.')
add('    static let flightSpeed: [SpeedPoint] = [')
rows = []
for h, r, a_ in AF['ret_speed']:
    rows.append(f'        .init(minute: {round(h * 60, 1)}, line: "ADS-B", kmh: {r})')
    rows.append(f'        .init(minute: {round(h * 60, 1)}, line: "The app", kmh: {a_})')
add(',\n'.join(rows))
add('    ]')
add(f'    static let flightPhases = (climbEndHour: {AF["ret_phases"]["toc_h"]}, descentHour: {AF["ret_phases"]["tod_h"]}, '
    f'share: {F["AirRetShare"]}, climbErr: {F["AirRetClimb"]}, cruiseErr: {F["AirRetCruise"]}, descentErr: {F["AirRetDescent"]})')
add('')
add('    /// Every data-dependent number the paper\'s text quotes (tables/numbers.tex), for the page\'s own text.')
add('    enum Num {')
import re as _re
for name, val in _re.findall(r"\\newcommand\{\\n(\w+)\}\{(.*)\}", open(os.path.join(HERE, 'tables', 'numbers.tex')).read()):
    v = val.replace('{,}', ',').replace('\\%', '%').replace('\\dg', '°').replace('$', '')
    add(f'        static let {name} = {q(v)}')
add('    }')

src = open(SWIFT).read()
a, b = src.index(BEGIN) + len(BEGIN), src.index(END)
open(SWIFT, 'w').write(src[:a] + '\n'.join(lines) + '\n' + src[b:])
print('wrote', len(lines), 'lines into', os.path.relpath(SWIFT, os.path.join(HERE, '..')))
