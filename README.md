# TreadPilot ▸

**Control your Bluetooth treadmill from iPhone — structured workouts, live
metrics, Apple Watch heart rate, Apple Health sync.**

TreadPilot connects to FitShow-protocol treadmills over Bluetooth LE
(including many Tunturi models such as the Competence/Performance/Endurance
series) and gives you full control: start/stop, speed and incline, interval
programs that run like an autopilot, per-second workout recording with
charts, personalized calorie estimation, and automatic Apple Health export.
A watchOS companion app streams live heart rate via HKWorkoutSession
mirroring.

> ⚠️ **Safety first.** This app drives a real motorized belt. The belt only
> starts after an explicit in-app confirmation, but you are responsible for
> safe use: always attach the treadmill's safety key, stand on the side
> rails when starting, and remember that on a Bluetooth disconnect the belt
> keeps running at the last set speed — the machine's own Stop button and
> safety key are the primary protection.

## Features

- **Manual control** — speed (0.1 km/h steps) and incline from the phone,
  with confirmation dialogs and device-limit clamping
- **Workout programs** — segment editor (duration/speed/incline), countdown
  start from a standing belt, live segment banner with next-segment preview
- **Live metrics** — speed, distance, time, elevation gain, steps, and
  HR-based (Keytel) / MET-based (ACSM) calorie estimation from HealthKit
  body data
- **Apple Watch** — auto-started mirrored workout session with live HR
- **History** — every workout stored on device (SwiftData) with charts
- **Apple Health** — automatic workout export (deduplicated with the Watch)
- **Demo mode** — full UI with a simulated treadmill, no hardware needed

## Protocol

The FitShow BLE serial protocol implementation lives in
`TreadPilot/FitShow/`: frame codec (`0x02 | CMD | DATA | XOR | 0x03`),
command builders, a two-variant run-data parser (standard little-endian and
the "AnyRun" big-endian/minute-second variant, auto-detected at runtime),
and a CoreBluetooth client with a serialized, echo-acknowledged command
queue. Byte-level details are documented in the source comments; reference
implementations that informed this work include
[qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift) and the FitShow
vendor protocol documentation.

## Building

Requirements: Xcode 16+ (Swift 6 toolchain), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open TreadPilot.xcodeproj
```

Run the `TreadPilot` scheme. Tests: `⌘U`, or:

```bash
xcodebuild test -project TreadPilot.xcodeproj -scheme TreadPilot -destination 'platform=iOS Simulator,name=iPhone 17'
```

A physical iPhone is required for Bluetooth; the simulator offers Demo Mode.
For the Watch app, select your team on both targets and enable Developer
Mode on the watch.

## License

MIT — see [LICENSE](LICENSE). Bundled Space Grotesk fonts are under the SIL
Open Font License 1.1 ([OFL.txt](TreadPilot/Resources/Fonts/OFL.txt)).
Tunturi is a trademark of Tunturi New Fitness B.V.; this is an independent
project not affiliated with any treadmill manufacturer.
