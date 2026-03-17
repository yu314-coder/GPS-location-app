# GPS Location App

<p align="center">
  <img src="GPS-location-app.png" alt="GPS Location App" width="180">
</p>

<p align="center">
  A precision GPS workout tracker for iPhone and Apple Watch with Kalman-filtered location, HealthKit sync, Live Activities, CarPlay, and full route analytics.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS%2018.5+-blue" alt="iOS 18.5+">
  <img src="https://img.shields.io/badge/platform-watchOS%2011.5+-green" alt="watchOS 11.5+">
  <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">
  <img src="https://img.shields.io/badge/UI-SwiftUI-purple" alt="SwiftUI">
</p>

---

## Features

### Live GPS Tracking

- Start, pause, resume, and stop workout sessions with a single tap
- Choose activity type: **Walking, Running, Cycling, Hiking, Flight, or General**
- Real-time metrics: distance, speed, altitude, pressure, calories, heart rate
- Scrollable live data log showing raw GPS coordinates, accuracy, and Kalman filter state
- Live signal quality indicator (0-4 bars) with horizontal accuracy readout

### Kalman-Filtered GPS

- Built-in Kalman filter reduces GPS noise for smoother, more accurate routes
- Three sensitivity levels: **Low, Medium, High** (configurable in Settings)
- Raw GPS mode available for unfiltered data
- Activity-specific speed thresholds reject impossible readings
- Automatic WiFi/cellular fallback when GPS signal is lost
- GPS reconnection logic with 5-second timeout detection

### Real-Time Graphs

- **Speed graph** with 10-second rolling average
- **Altitude graph** tracking elevation changes
- **Pressure graph** from the device barometer (when available)

### Route Replay

- Animated playback of any recorded route on a map
- Variable speed: **1x, 2x, 4x, 8x**
- Timeline scrubber with elapsed time and progress
- Start and end markers on the map

### Workout Summary

After stopping a session, a full summary is presented:

- Route plotted on a static map
- Total distance, duration, average/max speed, max altitude, calories
- Heart rate stats (average and max, when tracked)
- **Kilometer splits** with pace and heart rate per split
- **Route quality report**: total points, valid points, signal coverage %, average accuracy
- **Effort rating (RPE)**: 1-10 slider saved to HealthKit

### Workout History

- Browse all saved workouts with route maps
- Filter by activity type
- Sort by date, distance, or duration
- Resync individual or all workouts back to HealthKit
- Tap any workout for full details

### Monthly & Yearly Analytics

- Daily distance chart for any selected month
- Yearly distance chart showing monthly totals
- Filter by workout type
- Month-over-month and year-over-year comparisons

### HealthKit Integration

- Auto-save workouts, routes, distance, energy, cadence, and steps to Apple Health
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
- Real-time metrics, maps, and signal quality on-wrist
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
- Permission status cards with quick access to iOS Settings

---

## Getting Started

### Requirements

- macOS with Xcode 16.4+
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
```

---

## Deep Link

```
gpslocationapp://live
```

Opens the live tracking session directly.

---

## License

This project is provided as-is for personal and educational use.
