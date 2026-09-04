# GPS Location App

<p align="center">
  <img src="GPS-location-app.png" alt="GPS Location App" width="180">
</p>

<p align="center">
  A precision workout tracker for iPhone and Apple Watch — Kalman-filtered GPS, HealthKit sync,
  Live Activities, CarPlay, full route analytics, and <b>Velocity Mode</b>: route recording with
  the satellites switched off.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS%2018.5+-blue" alt="iOS 18.5+">
  <img src="https://img.shields.io/badge/platform-watchOS%2011.5+-green" alt="watchOS 11.5+">
  <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">
  <img src="https://img.shields.io/badge/UI-SwiftUI-purple" alt="SwiftUI">
  <img src="https://img.shields.io/badge/paper-PDF-red" alt="Paper">
</p>

---

## Features

### Velocity Mode — recording a route without satellites

Satellite positioning fails where routes are most often wanted: tunnels, underground car parks,
urban canyons, aircraft cabins. Velocity Mode records the journey anyway — **speed from how the
vehicle shakes**, direction from the motion sensors, and position projected forward from a single
starting fix. Only the first point of the route comes from GPS.

It engages on its own. Velocity Mode takes over whenever satellite positioning drops out **or
degrades** — a long tunnel with vents, a covered ramp, a street between tall buildings, where
fixes keep arriving but are worth ±100 m — and it carries on from the last speed GPS actually
measured, so the track stays joined up rather than restarting from zero. There is nothing to
switch on mid-workout; the manual toggle exists to force it for testing.

It does not integrate acceleration. Double integration diverges within seconds because
accelerometer bias is indistinguishable from real acceleration. Instead a 4-second window of
vertical acceleration is turned into an 11-dimensional spectral signature, and speed is read off
by nearest-neighbour lookup against every signature GPS has previously labelled. The model is
allowed to refuse: if nothing it has stored resembles the present signature, it says so rather
than guessing.

**Measured accuracy** — 23 instrumented journeys, each recorded with GPS running alongside purely
as ground truth:

| Journey | Distance error | Heading |
|---|---|---|
| Open road, 15 km | **+3.8%** | 5° median |
| Motorcycle, mounted | +6% | — |
| City driving, 12–19 min | +20% to +25% | 8–15° median |
| Car park, 4–8 min | +58% to +62% | — |
| **Motorcycle, phone in a pocket** | **no relationship to real speed** | — |

The spread is a property of the signal, not a defect. Absolute speed error is a few km/h at any
speed — 1% of a motorway pace and 140% of a walking one — so the same estimator looks excellent
on an open road and poor in traffic.

The last row is different in kind from the rest. Over a 19-minute ride with the phone in a
trouser pocket the reported speed and the real speed were statistically unrelated (R = +0.13),
and the vibration signature and the real speed more so (R = −0.02). The estimate reads roughly
50 km/h whatever the motorcycle is doing, including standing still at a light. A car rests the
phone on a rigid surface and delivers road noise that scales with speed; a motorcycle delivers
engine vibration, which follows engine speed rather than road speed and is undiminished at a
standstill in gear. There is no speed in the input, so nothing can recover one — and the model's
own confidence signal failed to notice, which is the part worth fixing.

**What it cannot do.** A phone held in the hand loses the speed signal entirely (the signature
stops varying with speed: measured flat from 10 to 65 km/h), and a phone in a pocket on a
motorcycle loses it completely — see the table above. Aircraft speed cannot be measured without
GPS, because Core Motion's attitude filter absorbs a takeoff roll as a change in the gravity
direction. A vehicle the model has never learned reads wrong until it has.

📄 **[Read the paper](https://github.com/yu314-coder/GPS-location-app/releases/tag/v1.0-paper)**
— method, results, and nine approaches that were implemented, measured and rejected.
[LaTeX source](paper/). The paper also ships inside the app: **Settings → Velocity Mode → Read the
paper**, alongside an interactive version with the equations and error charts.

The in-app copy updates itself. A revision uploaded to that release reaches readers without an
App Store submission — the app fetches it in the background and only replaces what it has once
the download parses as a PDF. A full copy still ships in the binary, so the paper opens instantly,
offline, and if every fetch fails forever.

### Live GPS Tracking

- Start, pause, resume, and stop workout sessions with a single tap
- Choose activity type: **Walking, Running, Cycling, Hiking, Flight, or General**
- Real-time metrics: distance, speed, GPS-derived acceleration, device-motion acceleration with X/Y/Z components, pitch/roll/yaw attitude, rotation rate, compass heading, GPS quality, altitude, barometric climb/descent, pressure, calories, heart rate
- Scrollable live data log showing raw GPS coordinates, accuracy, and Kalman filter state
- Live signal quality indicator (0-4 bars) with horizontal accuracy readout
- GPS quality score (0-100) saved with each workout so weak tracks are easier to diagnose; the score now considers accuracy, stale timestamps, long update gaps, filtered fixes, and estimated fallback points

### Kalman-Filtered GPS

- Built-in Kalman filter reduces GPS noise for smoother, more accurate routes
- Three sensitivity levels: **Low, Medium, High** (configurable in Settings)
- Raw GPS mode available for unfiltered data
- Activity-specific speed and acceleration thresholds reject impossible readings
- iPhone Core Motion records gravity-removed acceleration, attitude, rotation, compass heading, and movement-direction acceleration; Watch workouts receive lightweight iPhone motion assist data without starting Watch device-motion tracking
- iPhone motion assist can relax GPS acceleration-spike filtering when GPS direction and iPhone forward/horizontal acceleration agree, improving tolerance for real starts/stops
- Estimated-location fallback marks low-confidence route points during GPS gaps: iPhone projects from the last real GPS fix using heading and conservative acceleration/speed integration; Apple Watch uses pedometer distance plus iPhone-relayed direction, without starting Watch Core Motion
- Automatic WiFi/cellular fallback when GPS signal is lost
- GPS reconnection logic with 5-second timeout detection

### Real-Time Graphs

- **Speed graph** with 10-second rolling average
- **Acceleration graph** with peak acceleration/deceleration detection
- **Device motion graphs** from gravity-removed iPhone Core Motion data, with live values and separate saved charts for `$a$`, `$a_x$`, `$a_y$`, `$a_z$`, pitch, roll, yaw, rotation rate, and compass heading
- **Altitude graph** tracking elevation changes
- **Barometric climb graph** with climb/descent rate from CMAltimeter
- **Pressure graph** from the device barometer (when available)
- **GPS quality graph** showing confidence over time

### Route Replay

- Animated playback of any recorded route on a map
- Variable speed: **1x, 2x, 4x, 8x**
- Timeline scrubber with elapsed time and progress
- Start and end markers on the map

### Workout Summary

After stopping a session, a full summary is presented:

- Route plotted on a static map
- Total distance, duration, average/max speed, max acceleration, motion acceleration, GPS quality, max altitude, barometric climb/descent, calories
- Heart rate stats (average and max, when tracked)
- **Kilometer splits** with pace and heart rate per split
- **Route quality report**: total points, valid points, signal coverage %, average accuracy
- **Sensor report**: motion acceleration, GPS quality score, barometric climb/descent, and max climb/descent rate when supported
- **Effort rating (RPE)**: 1-10 slider saved to HealthKit

### Workout History

- Browse all saved workouts with route maps
- Filter by activity type
- Sort by date, distance, or duration
- Resync individual or all workouts back to HealthKit
- Tap any workout for full details

### Full Workout Map

- Dedicated Map tab with a full Apple Map view
- Shows all saved workout tracks for the selected time period
- Time filters: **All, 3 Months, Week, or Custom date range**
- **Load** refreshes local saved workout tracks without touching the Flights tab
- **Download All** imports HealthKit workout routes into local storage for the Map tab
- Select an individual track to highlight it and zoom to that route, or tap near a route line on the map to show that workout's date
- Visual-only **Align Roads** button redraws workouts with rate-limited Apple Maps route segments without changing saved workout data; route segments are accepted only when they stay close to the recorded GPS path, and unsupported or low-confidence segments stay on raw GPS

### Monthly, Yearly & All-Time Analytics

- Daily distance chart for any selected month
- Yearly distance chart showing monthly totals
- All Time mode uses a Plotly-style monthly/cumulative chart from the first workout month through the current month, with optional year filters such as 2026, 2025, and 2024 that switch the graph to day-by-day values with a cumulative toggle
- Filter by workout type
- Month-over-month and year-over-year comparisons

### HealthKit Integration

- Auto-save workouts, routes, distance, energy, cadence, steps, and sensor summary metadata to Apple Health
- Heart rate recording during sessions
- Full route export as HealthKit workout routes
- Manual resync with effort rating updates
- Read back workout history from HealthKit

### GPX Export

- Export any workout route as a standard GPX file
- Share via AirDrop, email, or cloud services
- Accessible through the iOS Files app

### Apple Watch Companion

- Full standalone watch app with live tracking
- Real-time metrics, maps, signal quality, iPhone-assisted scalar motion acceleration, GPS quality, and climb rate on-wrist
- Syncs sessions and data with iPhone via WatchConnectivity
- Workout history and replay available on watch

### Live Activity & Dynamic Island

- Lock screen workout status with live timer, distance, and speed
- Dynamic Island compact and expanded views
- Heart rate display when available
- Persists even when the app is backgrounded

### Home Screen Widget

- At-a-glance workout status and metrics
- Monthly distance chart
- Year-over-year analytics
- Tap to jump into the app

### Siri Shortcuts

- "Start Walking Workout", "Start Running Workout", etc.
- "Stop Workout", "Pause Workout", "Resume Workout"
- Natural language feedback with current stats

### CarPlay (Pending Apple Approval)

- Full-screen live route map on the car display
- Auto-tracking camera follows the route
- Stop workout button
- See [CARPLAY_README.md](CARPLAY_README.md) for setup details

### Settings & Preferences

- **Units**: km/mi, km/h/mph/knots, meters/feet
- **Map style**: Standard, Satellite, Hybrid
- **GPS filtering**: Kalman sensitivity, raw GPS toggle
- **HealthKit**: auto-save toggle, export type, heart rate toggle
- **How Velocity Mode works**: the algorithm, its equations, and charts of its measured error
- **Velocity Mode → Keep going in the background**: off limits the automatic takeover to when the
  workout is on screen, for battery. Forcing the mode by hand still records everywhere
- **Velocity Mode → Diagnostics logs**: off skips the per-workout 50 Hz raw and per-tick CSVs.
  Storage only — routes record identically either way
- Permission status cards with quick access to iOS Settings
- Tap the version number five times for the developer screen: learned-model state, session logs,
  and diagnostics

---

## Getting Started

### Requirements

- macOS with Xcode 16.4+ (built and shipped with Xcode 26.5)
- iPhone running iOS 18.5+ (physical device recommended)
- Apple Watch running watchOS 11.5+ (optional)

### Build & Run

1. Open `GPS location app.xcodeproj` in Xcode.
2. Set your Development Team in **Signing & Capabilities**.
3. Select the **GPS location app** scheme and your device.
4. Build and run.
5. Grant Location, HealthKit, and Motion permissions on first launch.

> GPS and HealthKit features require a physical device. Simulator support is limited.

---

## Project Structure

```
GPS location app/           # iOS app
  Models/                   # Flight, FlightLocation, FlightMetrics
  Services/                 # LocationManager, WorkoutSession, HealthKit, WatchConnectivity
  Views/                    # Graphs, maps, signal quality, metrics
  ViewControllers/          # Live session, summary, history, replay, analysis, settings
  LiveActivity/             # Lock screen Live Activity
  CarPlay/                  # CarPlay scene delegate
  Shortcuts/                # Siri Shortcuts intents

GPS location app Watch App/ # watchOS companion
  Models/
  Services/
  Views/
  ViewControllers/

WorkoutWidget/              # Widget + Live Activity extension

paper/                      # LaTeX source, figures and PDF for the Velocity Mode paper
scripts/                    # release.sh — archive, export and upload in one command
docs/icon-history/          # the icons the current one replaced, and why
```

## Documentation

| Document | What it covers |
|---|---|
| [paper/velocity_mode.pdf](paper/velocity_mode.pdf) | The Velocity Mode method, its measured accuracy, and its failure modes |
| [RESEARCH_GPS_ALTERNATIVES.md](RESEARCH_GPS_ALTERNATIVES.md) | Survey of GPS-free positioning approaches, with notes on which survived contact with measurement |
| [CARPLAY_README.md](CARPLAY_README.md) | CarPlay entitlement and setup |
| [scripts/release.sh](scripts/release.sh) | Archive, export and upload to App Store Connect in one command |
| [docs/icon-history/](docs/icon-history/) | Previous app icons and the reasoning behind each change |

---

## Releasing

```bash
scripts/release.sh --bump     # bump the build number, archive, export, upload
```

Credentials are already on the machine and are not in this repo: the `.p8` sits in one of the
directories `altool` searches by itself, and the key and issuer IDs are in
`~/.config/appstoreconnect/gps-location-app.env`.

The script also strips the build machine's OS stamp before exporting. Xcode records the host's
build number in `BuildMachineOSBuild`, and on a macOS beta that is a beta seed — which Apple reads
as "built against a beta SDK" and answers with ITMS-90111, by email, *after* the upload has
succeeded and the build has validated. Nothing at upload time reveals it, so the fix belongs in
the script rather than in someone's memory.

---

## Deep Link

```
gpslocationapp://live
```

Opens the live tracking session directly.

---

## License

This project is provided as-is for personal and educational use.
