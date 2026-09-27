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
add(f'        .init(name: "Plane", recorded: {q(f"{P["flights"]} flight, {P["gps_km"]:.0f} km; the takeoff measured, then the flight network")},')
add(f'              distance: {q(signed(P["total_pct"]))}, speed: {q(f"{P["air_error"]} km/h")}, speedLabel: "speed error in the air",')
add(f'              direction: {q(f"{P["dir_within30"]}%")})')
add('    ]')
add('')
add('    static let distance: [Distance] = [')
add(f'        .init(name: "Motorcycle", detail: {q(f"{M["recordings"]} journeys, {M["within20"]}% within 20%")},')
add(f'              appKm: {M["app_km"]}, gpsKm: {M["gps_km"]}, errorPercent: {M["total_pct"]}),')
add(f'        .init(name: "Car", detail: {q(f"{C["recordings"]} journeys, {C["within20"]}% within 20%")},')
add(f'              appKm: {C["app_km"]}, gpsKm: {C["gps_km"]}, errorPercent: {C["total_pct"]}),')
add(f'        .init(name: "Walking", detail: {q(f"{W["stretches"]} straight stretches, counted by steps")},')
add(f'              appKm: {W["app_km"]}, gpsKm: {W["gps_km"]}, errorPercent: {W["total_pct"]}),')
add(f'        .init(name: "Plane", detail: "1 flight: takeoff, then the flight network",')
add(f'              appKm: {P["app_km"]}, gpsKm: {P["gps_km"]}, errorPercent: {P["total_pct"]})')
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
add(f'        .init(name: "Plane", graded: "1 flight", medianDegrees: {P["dir_median"]}, within30: {P["dir_within30"]})')
add('    ]')
add('')
add('    /// The recorded flight replayed with no GPS through the app\'s own code.')
add('    static let flight: [FlightPoint] = [')
add(',\n'.join(f'        .init(point: {q(f["label"])}, errorPercent: {f["error_pct"]})' for f in J['flight']))
add('    ]')

src = open(SWIFT).read()
a, b = src.index(BEGIN) + len(BEGIN), src.index(END)
open(SWIFT, 'w').write(src[:a] + '\n'.join(lines) + '\n' + src[b:])
print('wrote', len(lines), 'lines into', os.path.relpath(SWIFT, os.path.join(HERE, '..')))
