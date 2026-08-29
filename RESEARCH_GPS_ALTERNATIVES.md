# Comprehensive Research: Location/Distance Tracking Without GPS

## When GPS is unavailable (tunnels, underground, MRT/subway, indoor environments)

> **Status — August 2026.** This document is the literature survey that preceded the work,
> written in May 2026. One of its options was built, shipped and measured over 23 instrumented
> journeys; see **[paper/velocity_mode.pdf](paper/velocity_mode.pdf)** for what actually
> happened. The survey is kept as written, with a results section below recording which of its
> predictions held.

---

## What was built, and what the survey got right

**Built:** §12's vibration-based speed estimation, using the whole log-spectrum rather than any
single feature, with nearest-neighbour regression over GPS-labelled examples. Shipped as
*Velocity Mode*. Measured: **+3.8% distance over 15 km** of open road, degrading to **+60%** in
slow stop-start traffic, with heading to **5–15°**.

**The survey was right about:**

- *"Pure INS/Dead Reckoning — drift makes unusable after seconds."* Confirmed emphatically.
  Replaying a real 22.8-minute flight with GPS removed gave **−82% to −87%** distance; the
  along-track integral recovered roughly 60 km/h of a 679 km/h climb.
- *"Vibration frequency analysis distinguishes vehicle types."* Confirmed and measured: a
  motorcycle vibrates ~3.5× harder than a car (vertical RMS 1.302 vs 0.374 m/s²), and whole-session
  spectral fingerprints separate vehicles cleanly (0.54–1.70 within a regime, 4.30–6.97 across).
- *"Barometric altitude is reliable and permission-free."* Used to identify car-park ramps, where
  the speed estimate runs 2–7× fast. Detection needs barometer **and** sustained same-direction
  rotation together; either alone flags ordinary hills or junctions.

**The survey did not anticipate:**

- **Core Motion's attitude filter absorbs sustained linear acceleration as a change in the gravity
  direction.** This single behaviour defeated three separate approaches — aircraft speed
  integration, deriving the phone's carry angle from acceleration, and inertial takeoff detection.
  It is not mentioned in any of the sources surveyed here, and it is the most important thing on
  this page.
- **Regime separation does not transfer.** Fingerprints identify vehicles cleanly in aggregate and
  still make per-query prediction *worse* (+2.2 → +3.4 km/h). For one car journey the nearest
  stored session was a hand-held one, ahead of the same car driven that morning.
- **Platform semantics dominate modelling error.** The three largest sources of bad data were a
  heading datum frozen at one value for 4790 of 4832 seconds (CLHeading is suspended outside the
  foreground and its cached value never cleared), a 371-second process suspension from a
  permission gate, and instrumentation that could not express whether the mode was even running.
- **Carry position matters more than vehicle.** A phone held in the hand loses the speed signal
  entirely — the signature stops varying with speed, measured flat from 10 to 65 km/h.

**Not pursued:** transit-schedule interpolation (§7), beacons (§3), UWB (§8) and Apple Indoor Maps
(§6) all need infrastructure or enrollment the app cannot assume. Magnetometer fingerprinting (§9)
needs per-venue training data.

---

## 1. Dead Reckoning / Inertial Navigation (INS)

### How It Works
Dead reckoning estimates position by double-integrating accelerometer data for displacement and integrating gyroscope data for heading changes. On iOS, the IMU (Inertial Measurement Unit) provides 3-axis accelerometer and 3-axis gyroscope data.

### iOS Frameworks and APIs
- **CMMotionManager** -- raw accelerometer, gyroscope, magnetometer data
- **CMDeviceMotion** -- sensor-fused data providing:
  - `userAcceleration` (gravity removed)
  - `attitude` (pitch, roll, yaw via CMAttitude)
  - `rotationRate` (processed gyroscope)
  - `gravity` (isolated gravity vector)
- **CMPedometer** -- step counting with estimated distance (uses calibrated stride length)
- **CMMotionActivity** -- detects walking, running, cycling, automotive

### Accuracy on iPhone/Apple Watch
- **Pedestrian Dead Reckoning (PDR)**: Step detection + heading works reasonably for walking. CMPedometer provides distance estimates based on calibrated stride length.
- **Raw double integration**: Position from double-integrating accelerometer data drifts catastrophically within seconds. Consumer MEMS sensors have bias errors that cause second-order position drift (accelerometer) and third-order drift (gyroscope). Practical limit is a few seconds of useful integration.
- **Apple Watch**: Calibrates accelerometer against GPS when outdoors, then uses that calibration for distance estimation when GPS is lost. This is why Apple recommends outdoor calibration walks.

### Key Limitations
- Gyro bias introduces third-order error in position
- Accelerometer bias introduces second-order error
- Consumer MEMS IMUs have large biases causing rapid position error accumulation
- Without external corrections (GPS, WiFi, etc.), drift makes pure INS unusable after ~10 seconds

### Improvement Techniques
- Kalman filter for sensor fusion
- Zero-velocity updates (ZUPT) when stationary periods are detected
- Step-and-heading approach (PDR) instead of raw integration
- Map matching to constrain drift to known paths

### Open Source References
- [reckonMe](https://github.com/reckonMe/reckonMe) -- iOS live inertial navigation with collaborative localization via Bluetooth
- Academic paper: "Inertial Odometry on Handheld Smartphones" (Solin et al., 2017) -- [arXiv:1703.00154](https://arxiv.org/pdf/1703.00154)
- Academic paper: "Robust Pedestrian Dead Reckoning Based on MEMS-IMU for Smartphones" -- [MDPI Sensors 2018](https://www.mdpi.com/1424-8220/18/5/1391)

---

## 2. WiFi Fingerprinting / WiFi RTT

### Technology Overview
WiFi fingerprinting maps WiFi signal patterns (RSSI from multiple access points) to physical locations. WiFi RTT (Round Trip Time, IEEE 802.11mc) measures time-of-flight of WiFi signals for more precise ranging.

### iOS Restrictions -- CRITICAL LIMITATION
- **iOS does NOT have a general-purpose API for WiFi scanning.** There is no public API to scan for WiFi networks or read RSSI values from within an app.
- **NEHotspotHelper** is the closest API but explicitly cannot be used for WiFi-based positioning. It requires a special entitlement from Apple, and Apple enforces both technical and business restrictions preventing location use.
- **WiFi RTT (802.11mc)**: No public iOS API. Android has WiFi RTT APIs (WifiRttManager), but Apple has not exposed equivalent functionality.
- **Apple's own indoor positioning** uses WiFi fingerprinting internally but this is not exposed to third-party developers.

### What IS Available
- Apple's Indoor Maps Program uses WiFi fingerprinting under the hood (venue must be enrolled)
- CLLocationManager automatically uses WiFi for positioning when available, but developers cannot access raw WiFi data
- Apple Technical Note TN3111 documents the full WiFi API surface on iOS -- it confirms scanning is not available

### WiFi RTT Accuracy (on platforms that support it)
- 0.6m accuracy in ideal indoor conditions (107% better than RSS fingerprinting alone)
- Sub-metre-level accuracy using trilateration under ideal conditions
- Performance degrades significantly in non-line-of-sight (NLOS) environments like underground tunnels
- Combining RTT + RSSI fingerprinting: 62cm RMSE, 93% accuracy

### Sources
- [WiFi RTT Fingerprinting Analysis](https://www.tandfonline.com/doi/full/10.1080/17489725.2023.2239748)
- [IEEE 802.11mc/az/bk Survey](https://arxiv.org/html/2509.03901v1)
- [Apple TN3111: iOS Wi-Fi API Overview](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview)

---

## 3. Bluetooth Beacons (iBeacon, BLE)

### Technology Overview
BLE beacons (iBeacon protocol, introduced by Apple in 2013) broadcast signals that smartphones can detect for proximity estimation. Typical accuracy: 1-5 meters depending on density of deployment.

### iOS APIs
- **CLLocationManager** `startRangingBeacons(satisfying:)` -- provides proximity (immediate/near/far) and RSSI
- **CLBeaconRegion** / **CLBeaconIdentityConstraint** -- monitor for beacon regions
- **Core Bluetooth** -- direct BLE scanning for custom beacon protocols

### Transit/Subway Deployments
- **Airports**: Many major airports have iBeacon installations for indoor navigation
- **Shopping malls**: Common deployment scenario
- **Subway/MRT**: Limited deployments. Some transit systems have experimented with beacons but widespread subway beacon infrastructure is rare.
- Beacons cost 3-30 EUR each and are easy to install but require maintenance (battery replacement)

### Accuracy
- Typical indoor wayfinding: within 5 meters
- Better accuracy than GPS and WiFi in indoor environments
- Accuracy degrades with multipath effects in metal-heavy environments (subway cars, tunnels)

### Limitation for Your Use Case
- Requires pre-installed beacon infrastructure -- you cannot deploy beacons in subway tunnels you don't control
- Beacon density must be sufficient for continuous tracking
- Battery-powered beacons need periodic replacement

### Sources
- [Infsoft: BLE Beacon Positioning](https://www.infsoft.com/basics/positioning-technologies/bluetooth-low-energy-beacons/)
- [Indoor Pedestrian Localization Using iBeacon and Improved Kalman Filter](https://pmc.ncbi.nlm.nih.gov/articles/PMC6021914/)

---

## 4. Barometric Altitude (CMAltimeter)

### iOS API
- **CMAltimeter** (CoreMotion framework) -- available since iPhone 6 (2014)
- Provides **relative pressure** (kPa) and **relative altitude** change (meters)
- Does NOT provide absolute altitude -- only changes from a reference point
- No special permissions required for pressure data

### Underground/Tunnel Applications

#### Station Counting via Pressure (Snips Research)
A groundbreaking finding by Snips AI researchers: **barometric pressure can count subway stations with >90% accuracy**.

**The Venturi Effect**: When a train accelerates in a closed tunnel, it creates pressure drops. Each trip between stations generates a distinct downward peak in barometric pressure. An off-the-shelf peak detection algorithm identifies these peaks.

**Key findings**:
- Station counting accuracy: >90%
- Direction identification: >90% accuracy after only 2 stations
- Line identification: Possible using Bayesian probabilistic model comparing trip durations between stations against known timetable data
- The pressure systematically drops when the metro accelerates and returns to original level when it decelerates

#### Depth/Floor Detection
- CLFloor provides floor-level information (ordinal: 0 = ground, negative = below ground)
- Requires venue enrollment in Apple's Indoor Maps Program
- Pressure changes of ~12 Pa per meter of altitude change
- Can detect entry into underground areas via sustained pressure increase

### Practical Implementation
```
// CMAltimeter usage
let altimeter = CMAltimeter()
if CMAltimeter.isRelativeAltitudeAvailable() {
    altimeter.startRelativeAltitudeUpdates(to: .main) { data, error in
        if let data = data {
            let pressureKPa = data.pressure.doubleValue
            let altitudeChangeMeters = data.relativeAltitude.doubleValue
        }
    }
}
```

### App Implementation Status
The app now records CMAltimeter relative altitude during workouts on iPhone and Apple Watch when available.

- Stores barometric relative altitude history, barometric climb/descent, current vertical speed, max climb rate, max descent rate, and average vertical speed.
- Shows barometric climb/descent and climb-rate metrics in live workout screens and workout details.
- Keeps GPS altitude metrics separate from barometer-derived relative altitude so GPS route altitude and pressure-based climb can be compared.

### Sources
- [CMAltimeter Apple Docs](https://developer.apple.com/documentation/coremotion/cmaltimeter)
- [Snips: Underground Location Tracking](https://medium.com/snips-ai/underground-location-tracking-3ea56803dddc)

---

## 5. Cell Tower Triangulation

### iOS API
- **CLLocationManager** handles cell tower positioning automatically and transparently
- When GPS is unavailable, the system falls back to cell tower triangulation
- Developers cannot directly access cell tower IDs, signal strengths, or perform manual triangulation
- The `desiredAccuracy` property influences which positioning method is used

### Accuracy
- Cell tower positioning: typically 100m - several kilometers depending on tower density
- Very fast to obtain (seconds)
- Works whenever cellular service is available

### Underground Limitation
- Cell towers have limited or no signal in deep underground tunnels
- Some subway stations have cellular repeaters (especially newer systems)
- Between stations in tunnels: typically no cell signal at all
- Some cities are installing 4G/5G in subway tunnels (NYC MTA has been expanding coverage)

### What CLLocationManager Reports Underground
- `horizontalAccuracy` will be very large (1000m+) or location updates will stop entirely
- The system may report the last known location with a stale timestamp
- No explicit "GPS unavailable" notification -- you must infer from accuracy values and timestamps

---

## 6. Apple Indoor Maps / Indoor Positioning

### How It Works (WWDC 2014 Session 708 + WWDC 2019 Session 245)

Apple's indoor positioning uses a multi-stage approach:

1. **Approach detection**: Cell + GPS + WiFi detect when user approaches an indoor-enabled venue
2. **WiFi fingerprinting**: Device passively scans WiFi and performs on-device pattern matching against stored RF fingerprints
3. **Motion sensors**: M-series coprocessor provides direction of travel and speed
4. **Sensor fusion**: Combines WiFi fingerprint position with motion sensor dead reckoning to maintain smooth position updates

**Key technical details from WWDC 2014**:
- Uses existing WiFi infrastructure (no beacons needed)
- Requires an RF survey using Apple's Indoor Survey app
- When app requests `.best` accuracy, device automatically starts indoor fixes in enabled venues
- GPS is deactivated indoors to save battery
- Same CLLocationManager API -- no code changes needed
- Floor detection via CLFloor property on CLLocation

### Venue Requirements
- Must register at [register.apple.com/indoor](https://register.apple.com/indoor)
- Create maps using IMDF (Indoor Mapping Data Format)
- Perform RF survey with Apple's Indoor Survey app
- Free program -- Apple charges no fees
- Limited to organizations with large public/private spaces

### Subway Station Coverage
- Some major subway stations in NYC and other cities have indoor maps
- Coverage is venue-by-venue and requires the transit authority to enroll
- Does NOT work in tunnels between stations -- only in mapped station areas

### Accuracy
- GPS-level accuracy (a few meters) inside enrolled venues
- Uses no additional hardware beyond existing WiFi
- Works in any iOS app and Safari websites

### Sources
- [Apple Indoor Maps Program](https://register.apple.com/indoor)
- [WWDC 2014: Taking Core Location Indoors](https://asciiwwdc.com/2014/sessions/708)
- [WWDC 2019: Introducing the Indoor Maps Program](https://developer.apple.com/videos/play/wwdc2019/245/)
- [Mappedin: Indoor Positioning with Apple Core Location](https://www.mappedin.com/resources/blog/indoor-positioning-made-easy-with-apples-core-location/)

---

## 7. Train/Transit Schedule APIs (GTFS Real-Time)

### GTFS Real-Time Overview
GTFS Realtime extends the static GTFS feed with three real-time data types:
1. **Trip Updates** -- delays, cancellations, changed routes
2. **Vehicle Positions** -- latitude, longitude, bearing, speed, odometer
3. **Service Alerts** -- detours, station closures

### How to Use for Underground Positioning
Even without GPS, if you know:
- Which train the user boarded (from last GPS fix or user selection)
- The GTFS schedule for that train
- The current time

You can **estimate position along the known route** by interpolating between scheduled station arrival times. This is essentially "virtual GPS" using timetable data.

### Implementation Strategy
1. Detect user boarding a train (last GPS fix at station + CMMotionActivity = automotive)
2. Identify the train/line from GTFS data
3. Use GTFS shape data (route geometry) to know the exact path
4. Interpolate position along the path based on elapsed time since last station
5. Snap to nearest station when barometric pressure peak detected (station counting)

### Available SDKs for iOS
- **TripKit** (SkedGo) -- Swift library for transit data access
- **OneBusAway** -- open source transit app with GTFS-RT support
- Direct Protocol Buffer parsing of GTFS-RT feeds
- Many transit agencies provide public GTFS-RT feeds

### Data Format
- Protocol Buffers (protobuf) format
- VehiclePosition includes: lat/lon, bearing, odometer, speed, trip descriptor
- Available for hundreds of transit agencies worldwide

### Sources
- [GTFS Realtime Overview (Google)](https://developers.google.com/transit/gtfs-realtime)
- [GTFS.org Resources](https://gtfs.org/resources/using-data/)
- [Malaysia GTFS RT API](https://developer.data.gov.my/realtime-api/gtfs-realtime)

---

## 8. Ultra-Wideband (UWB)

### Apple's UWB Hardware
- **U1 chip**: iPhone 11 and later, Apple Watch Series 6 and later, AirTag
- **U2 chip**: iPhone 15 and later, AirPods Pro 2
- Accuracy: centimeter-level precision (within 10cm for ranging, +/-5 degrees angular)

### iOS Framework: Nearby Interaction
- **NINearbyInteractionSession** -- ranging between UWB devices
- Provides distance AND direction to other UWB devices
- Works with Apple-to-Apple devices and third-party UWB accessories (iOS 15+)
- Background ranging supported with BLE-paired devices, and with Live Activity in iOS 18.4+

### Limitation for Underground Positioning
- **Requires UWB infrastructure**: You need fixed UWB anchors installed in the environment
- No subway systems currently have UWB anchor infrastructure
- UWB is device-to-device or device-to-anchor -- it cannot determine absolute position alone
- Range: typically 10-30 meters indoors
- Could theoretically work if transit systems installed UWB anchors at stations

### What UWB CAN Do
- Precise ranging between two iPhones or iPhone + AirTag
- If you had a friend at a known location, you could range to them
- Third-party accessories with known positions could serve as anchors
- Some buildings are beginning to install UWB infrastructure for indoor navigation

### Sources
- [Nearby Interaction Framework](https://developer.apple.com/nearby-interaction/)
- [WWDC 2021: Explore Nearby Interaction with Third-Party Accessories](https://developer.apple.com/videos/play/wwdc2021/10165/)
- [WWDC 2022: What's New in Nearby Interaction](https://developer.apple.com/videos/play/wwdc2022/10008/)
- [Qorvo UWB Solutions for Apple U1/U2](https://www.qorvo.com/innovation/ultra-wideband/products/uwb-solutions-compatible-with-apple-u1)

---

## 9. Magnetometer-Based Navigation

### How Magnetic Fingerprinting Works
Buildings have unique magnetic signatures caused by steel structures, electrical wiring, and other ferromagnetic materials. These create distortions in Earth's magnetic field that are location-specific and relatively stable over time.

**Two phases**:
1. **Cartography/Training**: Walk through spaces recording 3-axis magnetometer readings to create a magnetic map
2. **Recognition/Localization**: Compare real-time readings against the map to determine position

### iOS Implementation -- NO PERMISSIONS REQUIRED
**Critical finding**: iOS accelerometer and magnetometer data can be accessed without any user permission. The magnetometer can be read by apps running in the background without user notification. This makes magnetic localization a uniquely accessible approach on iOS.

- Sample rate: 10-20 Hz is sufficient
- Uses CMMotionManager for raw magnetometer data
- Magnetic magnitude (sqrt(x^2 + y^2 + z^2)) creates location fingerprints

### Accuracy
- **Magnetic Particle Filtering**: 3-5 meters accuracy
- **Room identification**: >95% accuracy across 7 rooms using <2 minutes of sampling
- Accuracy varies with building construction (more metal = more distinct signatures)

### Production SDK: IndoorAtlas
- **IndoorAtlas** is the leading commercial platform for magnetic positioning
- iOS SDK available (also Android, React Native, Flutter, Unity, etc.)
- Uses a 6-layer sensor fusion stack combining magnetic positioning with inertial sensors
- Requires venue fingerprinting (mapping phase)
- Free tier available for development; commercial plans for production

### Challenges
- Magnetic signatures can change if building structure changes
- Magnetometer requires frequent calibration
- Interference from nearby electronics (other phones, headphones)
- Less reliable in open outdoor spaces with fewer magnetic distortions
- Subways have very strong and distinctive magnetic signatures from rails and electrical systems, which could be advantageous

### Sources
- [Greg Foster: Magnetic Localization on iOS](https://gregmfoster.medium.com/how-any-app-could-track-the-indoor-location-of-everyone-magnetic-localization-acf3707716de)
- [IndoorAtlas Platform](https://www.indooratlas.com/platform/)
- [IndoorAtlas iOS SDK](https://docs.indooratlas.com/ios/latest/)
- [Survey of Magnetic-Field-Based Indoor Localization (MDPI)](https://www.mdpi.com/2079-9292/11/6/864)

---

## 10. Sensor Fusion Approaches

### The State of the Art: Transit App (2024)
The Transit app achieved production-quality underground train tracking by combining:
1. **Accelerometer vibration analysis** -- Fourier transform converts acceleration data to frequency domain; trains vibrate at ~5 Hz vs ~2 Hz for walking
2. **Motion classifier ML model** -- distinguishes "moving train" from stationary/walking
3. **"The Mixer" ML model** -- weighs motion predictions, last-known location, location recency, and train schedules
4. **All on-device** -- compressed ML models run locally, no server communication needed
5. **90% accuracy** in predicting underground location
6. **1.5 million stations detected** across 400,000 trips in initial testing

### Academic Paper: London Underground Tracking (2019)
"Realtime Tracking of Passengers on the London Underground Transport by Matching Smartphone Accelerometer Footprints" (Nguyen et al., Sensors 2019)

**Key findings**:
- London Underground trains are self-driving with predictable acceleration/deceleration patterns
- Each rail line has distinctive vibration signatures (bumps, curves, junctions)
- Pattern-matching algorithm identifies line and station in real-time
- **90% accuracy** from first station, **100% accuracy** after 4 continuous stops
- Tested across entire London Underground: 940 km, 381 stations, 11 lines

### Snips AI: Barometric Sensor Fusion
Combined barometric pressure with schedule data:
- Pressure peaks count stations (>90% accuracy)
- Trip durations identify line and direction (Bayesian model)
- >90% direction identification after 2 stations

### Multi-Sensor Fusion Architecture for Underground
A practical sensor fusion stack for underground tracking would combine:

```
Layer 1: Motion Activity Detection (CMMotionActivity)
  -> Detect boarding/alighting (walking -> automotive transition)

Layer 2: Barometric Station Counting (CMAltimeter)
  -> Count pressure peaks = count stations passed

Layer 3: Accelerometer Vibration Analysis
  -> Train movement detection via frequency analysis
  -> Pattern matching for line/direction identification

Layer 4: GTFS Schedule Integration
  -> Interpolate position along known route geometry
  -> Cross-reference with station count for validation

Layer 5: Map Matching
  -> Snap estimated position to known transit routes
  -> Constrain position to valid track geometry

Layer 6: Last-Known GPS + Time Integration
  -> Use last GPS fix as anchor point
  -> Time-based interpolation along route
```

### Academic References
- [Multi-sensor integrated navigation using data fusion (ScienceDirect)](https://www.sciencedirect.com/science/article/pii/S1566253523000398)
- [London Underground Tracking Paper (MDPI)](https://www.mdpi.com/1424-8220/19/19/4184)
- [GPS-IMU Sensor Fusion for Vehicle Position (arXiv)](https://arxiv.org/html/2405.08119v1)
- [UWB + IMU Sensor Fusion for Localization (PMC)](https://pmc.ncbi.nlm.nih.gov/articles/PMC9659066/)

---

## 11. Apple's CLLocationManager Indoor Positioning

### Documented Capabilities
- **CLLocation.floor** (CLFloor) -- provides floor level in enrolled venues
- `.horizontalAccuracy` reports positioning accuracy; very large values indicate poor fix
- Indoor positioning activates automatically when requesting `.best` accuracy in enrolled venues
- Uses WiFi fingerprinting + motion sensors internally
- Works in any iOS app without code changes

### Undocumented / Lesser-Known Behaviors
- CLLocationManager continues to report location updates underground using cell towers when available, but with degraded accuracy (1000m+)
- The system caches the last known location and may report it with a stale timestamp
- In iOS 18+, CLLocationUpdate and CLMonitor provide alternative APIs with implicit permission handling via CLServiceSession
- Apple's indoor positioning uses data that is not exposed to developers: internal WiFi scan results, venue-specific RF maps, and M-series coprocessor data

### What Developers Cannot Access
- Raw WiFi RSSI values from nearby access points
- Cell tower identifiers or signal strengths
- The internal RF fingerprint database
- Indoor Survey app data or IMDF maps
- The sensor fusion algorithm Apple uses internally

### Practical Implications
- You cannot build your own WiFi fingerprinting on iOS
- You must rely on Apple's indoor positioning for WiFi-based fixes
- For custom positioning, you must use other sensors (accelerometer, gyroscope, magnetometer, barometer) which ARE fully accessible

### Sources
- [CLLocationManager Docs](https://developer.apple.com/documentation/corelocation/cllocationmanager)
- [CLFloor Docs](https://developer.apple.com/documentation/corelocation/clfloor)
- [Core Location Modern API Tips](https://twocentstudios.com/2024/12/02/core-location-modern-api-tips/)

---

## 12. Speed Estimation from Accelerometer

### The Challenge
Direct speed estimation by integrating accelerometer data is NOT feasible due to:
- White noise in sensor readings
- Phone sensor bias
- Vibration contamination
- Gravity component errors
- Drift accumulates within seconds

### What IS Possible

#### Vehicle Movement Detection
- **CMMotionActivity** detects automotive vs walking vs stationary
- Accelerometer can detect start/stop events (acceleration/deceleration)
- Vibration frequency analysis distinguishes vehicle types (~5 Hz for trains vs ~2 Hz for walking)

#### Train Speed from Vibration Patterns
- Train vibrations create distinctive frequency signatures
- Speed correlates with vibration intensity and frequency characteristics
- Track joints create periodic impulses whose frequency is proportional to speed
- Academic research has used wavelet transform and short-time Fourier transform for train speed estimation from vibration data

#### Station Detection Without Step Counting
The Transit app approach:
1. Convert accelerometer data to frequency domain (FFT/Fourier transform)
2. Train ML classifier to detect "moving train" vs "stopped at station"
3. Count station stops to track progress along route
4. No step counting needed -- works entirely from vibration analysis

#### iOS API: No Permission Needed
- Accelerometer data is accessible without user permission on iOS
- CMMotionManager provides raw accelerometer data at up to 100 Hz
- CMDeviceMotion provides processed (gravity-removed) acceleration

### Practical Accuracy
- Movement/stop detection: very reliable
- Station counting from vibration: ~90% accuracy (Transit app)
- Absolute speed estimation: not reliable from accelerometer alone
- Relative speed changes (acceleration/deceleration): detectable

### App Implementation Status
The app now records GPS-derived acceleration for each accepted route segment. This is not raw IMU dead reckoning; it is calculated from filtered GPS speed deltas so it stays tied to accepted route data.

Current behavior:
- Stores current acceleration, peak acceleration, peak deceleration, average absolute acceleration, and acceleration history.
- Shows max acceleration and an acceleration chart in workout details when data is available.
- Applies activity-specific acceleration spike filtering during workout tracking to reject sudden GPS speed changes that are likely location glitches.
- Persists acceleration values in local workout metrics and HealthKit metadata.

The app also records gravity-removed Core Motion acceleration from `CMDeviceMotion.userAcceleration` on iPhone. Watch workouts do not start Watch device-motion tracking; they receive a lightweight iPhone motion assist payload over WatchConnectivity instead.

- This does not control movement detection, so off-wrist or charging Watch sessions can still be tracked.
- Stores current, max, average, and history values for iPhone motion acceleration.
- Relays scalar acceleration, horizontal acceleration, forward acceleration, lateral acceleration, and movement direction to the Watch.
- Uses iPhone forward/horizontal acceleration only as a GPS filtering hint: when a GPS acceleration spike points in the same direction as recent iPhone motion, the Watch can allow a slightly higher acceleration threshold; when direction disagrees, the normal GPS filter still rejects the point.
- Displays the metric live and in workout details so iPhone 16 Pro acceleration data can be compared with GPS-derived acceleration.
- During GPS gaps, the app can add explicit estimated route points. iPhone estimated points are projected from the last real fix using compass/motion direction and conservative acceleration/speed integration. Apple Watch estimated points use CMPedometer distance plus iPhone-relayed direction, so Watch Core Motion remains disabled to avoid the memory crash path.
- Estimated points are saved with `isEstimated = true` and lower signal confidence. They preserve route continuity for tunnels/MRT-style gaps, but they are still dead-reckoned estimates and should be corrected by the next real GPS fix.

GPS quality is now stored as a 0-100 score per accepted location fix.

- The score is based on horizontal accuracy, validity, and filtering state.
- Stores current, average, best, worst, and history values.
- Shows GPS quality live and in workout details to make poor-signal tracks easier to diagnose.

This complements, but does not replace, future accelerometer/IMU vibration analysis for tunnels or underground movement.

### Sources
- [Speed Estimation using Smartphone Accelerometer Data (ResearchGate)](https://www.researchgate.net/publication/331739573_Speed_Estimation_using_Smartphone_Accelerometer_Data)
- [Train Speed Estimation from Track Structure Vibration (MDPI)](https://www.mdpi.com/2076-3417/10/14/4742)
- [Transit App: Go Underground](https://blog.transitapp.com/go-underground/)

---

## 13. Map Matching

### What It Is
Map matching aligns noisy/estimated position data to a known road or transit network. It converts "I think I'm somewhere around here" into "I'm on this specific track/road segment."

### Key Algorithms
1. **Hidden Markov Model (HMM)** -- most common modern approach. Treats road segments as hidden states, noisy position estimates as observations, and uses the Viterbi algorithm to find the most likely path.
2. **Fuzzy Logic** -- handles uncertainty in position estimates
3. **Kalman Filter** -- combines position estimates with road network constraints
4. **Topological** -- considers road connectivity and turn restrictions

### Transit-Specific Map Matching
- Transit routes are MUCH more constrained than road networks
- A subway train can only be on one of a few possible lines
- Once you know the line, position is 1-dimensional (distance along track)
- Station counting + schedule data can resolve ambiguity between lines

### Implementation Tools
- **Valhalla Meili** -- open source map matching engine using HMM
- **GraphHopper** -- open source routing engine with map matching
- **Geoapify** -- commercial map matching API
- **OSRM** -- Open Source Routing Machine with map matching
- Custom implementation using GTFS shape data for transit routes

### For Your App: Transit Route Map Matching
```
Given:
  - Known GTFS route shapes (polylines of track geometry)
  - Last known GPS position (station where user boarded)
  - Number of stations passed (from barometer/accelerometer)
  - Elapsed time since boarding

Algorithm:
  1. Identify candidate routes passing through boarding station
  2. For each route, calculate expected position based on:
     - Station count from barometric peaks
     - Elapsed time vs scheduled travel times
     - Direction from initial GPS heading
  3. Score each candidate using probability model
  4. Select highest-probability route and position
  5. Output: lat/lon on the route polyline + confidence
```

### Sources
- [Map Matching (Wikipedia)](https://en.wikipedia.org/wiki/Map_matching)
- [Valhalla Meili Map Matching](https://towardsdatascience.com/map-matching-done-right-using-valhallas-meili-f635ebd17053/)
- [Sparse Map Matching in Transit Networks (ResearchGate)](https://www.researchgate.net/publication/328946808_Sparse_map-matching_in_public_transit_networks_with_turn_restrictions)

---

## Summary: Recommended Approach for Underground GPS-Free Tracking

### Tier 1 -- Immediately Implementable (No Infrastructure Needed)

| Technology | iOS API | Permission Required | Accuracy |
|---|---|---|---|
| Motion Activity Detection | CMMotionActivity | Motion & Fitness | Detect boarding/alighting |
| Barometric Station Counting | CMAltimeter | None | >90% station counting |
| Accelerometer Vibration Analysis | CMMotionManager | None | ~90% movement detection |
| GTFS Schedule Interpolation | URLSession + protobuf | Internet | Depends on schedule accuracy |
| Last GPS + Time Extrapolation | CLLocationManager | Location | Degrades over time |
| Magnetometer Fingerprinting | CMMotionManager | None | 3-5m (requires training data) |

### Tier 2 -- Requires Infrastructure or Enrollment

| Technology | Requirement | Accuracy |
|---|---|---|
| Apple Indoor Maps | Venue enrollment + RF survey | ~3m |
| BLE Beacons | Beacon installation | 1-5m |
| UWB Anchors | UWB hardware installation | ~10cm |
| WiFi Fingerprinting | Apple Indoor Maps enrollment (cannot DIY on iOS) | ~3m |

### Tier 3 -- Theoretically Possible but Limited

| Technology | Limitation |
|---|---|
| Cell Tower Positioning | No signal in deep tunnels |
| Pure INS/Dead Reckoning | Drift makes unusable after seconds |
| WiFi RTT | No iOS API available |

### Recommended Architecture for Your App
The most promising approach combines Tier 1 technologies in a sensor fusion pipeline:

1. **Pre-boarding**: Record last GPS fix at station
2. **Boarding detection**: CMMotionActivity transition to automotive
3. **Underground tracking**: Barometric pressure peaks count stations + accelerometer vibration confirms movement
4. **Position estimation**: GTFS route geometry + station count + elapsed time
5. **Map matching**: Snap estimated position to known transit route
6. **Station arrival**: Barometric peak + deceleration pattern confirms station
7. **Resurfacing**: GPS lock reacquired, correct any accumulated error

This is essentially what the Transit app and Snips AI demonstrated in production with 90%+ accuracy.
