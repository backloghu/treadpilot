# TreadPilot ▸

[![CI](https://github.com/backloghu/treadpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/backloghu/treadpilot/actions/workflows/ci.yml)
[![Licence: GPL v3](https://img.shields.io/badge/licence-GPL--3.0-FFE500)](LICENSE)
[![treadpilot.app](https://img.shields.io/badge/web-treadpilot.app-0E0E0C)](https://treadpilot.app)

**Your treadmill has Bluetooth. You should be able to use it.**

TreadPilot is a free and open-source iPhone app that controls FitShow-protocol
treadmills over Bluetooth LE — start and stop the belt, set speed and incline,
run interval programs that drive the machine for you, watch live metrics, and
send the finished workout to Apple Health. A watchOS companion streams live
heart rate.

It started with a simple frustration: a Bluetooth-enabled treadmill that could
technically talk to a phone, but was effectively locked into a small set of
compatible apps. So we worked out how it talks.

TreadPilot implements the FitShow BLE protocol directly and hands you the
machine — no account, no cloud service, no tracking, no subscription. The app
contains no networking code at all; nothing leaves your phone because there is
nothing to leave through.

Version 1.0 has been submitted to the App Store and is awaiting review. Until
it lands there, [build it from source](#building). iOS 17+, watchOS 10+.

> ⚠️ **Safety first.** This app drives a real motorised belt. The belt only
> starts after an explicit in-app confirmation, but you are responsible for
> safe use: always attach the treadmill's safety key, stand on the side
> rails when starting, and remember that on a Bluetooth disconnect the belt
> keeps running at the last set speed — the machine's own Stop button and
> safety key are the primary protection. Changes that touch belt control are
> held to stricter contribution rules; see
> [CONTRIBUTING.md](CONTRIBUTING.md#safety-rules--these-are-not-negotiable).

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

## Why open source?

Reverse-engineering a treadmill protocol is the kind of work that is annoying
once and pointless twice. So the FitShow implementation lives here in the open,
with the frame format, the commands and the parsing behaviour documented in the
source — read it, change it, or lift it for your own project.

It is verified against exactly one machine: a Tunturi Competence T40. Other
FitShow consoles may speak a compatible dialect, a slightly different one, or
something else entirely — which makes traces and reports from other models the
most valuable thing anyone can send. If your treadmill behaves differently from
what the app displays, we want to know.

This is our first public open-source project. Contributions, bug reports,
protocol traces, translations and constructive criticism are all welcome.

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

## Links

- **Website:** <https://treadpilot.app>
- **Press kit:** <https://treadpilot.app/press>
- **Facebook:** <https://www.facebook.com/treadpilot>
- **Issues and discussion:** <https://github.com/backloghu/treadpilot/issues>

## Contributing

Contributions are welcome — especially protocol traces from treadmills other
than the Tunturi Competence T40, an FTMS backend, and translations. Start with
[CONTRIBUTING.md](CONTRIBUTING.md).

Commits need a `Signed-off-by` line (`git commit -s`), which is how you accept
the [Contributor Licence Agreement](CLA.md). You keep the copyright to your
work; the agreement exists so the App Store build stays legally possible.

Also worth reading: the [code of conduct](CODE_OF_CONDUCT.md), and
[SECURITY.md](SECURITY.md) — which matters more than usual here, because this
app drives a real motorised belt.

If you own a FitShow treadmill, try it and tell us what happens.

## Licence

**GNU General Public License v3.0 or later** — see [LICENSE](LICENSE).

In short: use it, study it, run it on your own treadmill, change it however you
like. If you **distribute** a modified version, you have to publish your full
source under the GPL as well. Using it privately carries no obligation at all.

Two things the licence does not cover, both spelled out in [NOTICE.md](NOTICE.md):

- **The TreadPilot name, wordmark and app icon are not licensed.** Fork freely,
  but give your fork its own name and icon.
- **The bundled Space Grotesk fonts** stay under the SIL Open Font License 1.1
  ([OFL.txt](TreadPilot/Resources/Fonts/OFL.txt)).

Tunturi is a trademark of Tunturi New Fitness B.V.; FitShow and Apple product
names belong to their respective owners. This is an independent project, not
affiliated with or endorsed by any of them.

Built by [Backlog Fejlesztő Kft.](https://backlog.hu) in Budapest.
