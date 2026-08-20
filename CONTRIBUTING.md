# Contributing to TreadPilot

Thanks for looking. This project exists because working out a treadmill's
Bluetooth protocol from scratch is tedious, and nobody should have to do it
twice. Contributions that spare the next person that work are the most valuable
ones here.

## What would help most

**Protocol traces from other treadmills.** This is the big one. The code is
verified against exactly one machine — a Tunturi Competence T40 (2019). If you
have a FitShow-protocol treadmill, a capture of what your console actually
sends is worth more than any amount of speculative code. Open an issue with the
BLE advertised name, the model, and the raw frames.

**An FTMS backend.** Newer consoles speak the standard Fitness Machine Service
(`0x1826`) instead of the FitShow serial protocol. The app is structured so a
second backend can slot in behind the same client interface.

**Translations.** The app is English-first with a Hungarian translation. Adding
a language means adding one `hu`-shaped block per key in the String Catalogs —
see [Localisation](#localisation) below.

**Bug reports from real hardware.** Especially anything where the belt behaved
differently from what the app displayed.

## Before you write code

**Open an issue first** for anything beyond a small fix. Not bureaucracy — the
safety rules below constrain the design in ways that are not obvious from
reading the code, and it is better to find that out before you have written a
few hundred lines.

## Safety rules — these are not negotiable

This software drives a motorised belt that a person stands on. Any change
touching belt control is reviewed against these:

1. **The belt never starts without an explicit user action.** Programmed starts
   still require confirmation, and the countdown must remain cancellable.
2. **Speed and incline are clamped to the console's own limits**, and the
   app's target must reconcile with what the machine actually reports.
3. **Connection loss must be surfaced to the user.** The protocol has no
   link-loss protection — the belt keeps running at the last set speed.
4. **Safety-critical wording lives in exactly one place**
   (`TreadPilot/UI/SafetyText.swift`). Do not inline a second copy of a safety
   instruction; that is how four different versions of the same warning
   appeared once already.
5. **Never guess a vendor opcode on live hardware.** A wrong pause opcode
   (`0x06`, taken from another vendor's table) locked up the T40 and needed a
   power cycle. If you are unsure, say so in the pull request.

## Getting set up

Requirements: Xcode 16+ (Swift 6 toolchain) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/backloghu/treadpilot
cd treadpilot
brew install xcodegen
xcodegen generate
open TreadPilot.xcodeproj
```

`project.yml` is the source of truth — **the `.xcodeproj` is generated and not
checked in.** After adding, moving or removing a file, run `xcodegen generate`
again.

`project.yml` pins `DEVELOPMENT_TEAM` to the maintainer's Apple team so that
the released build signs without fuss. If you are building on your own device,
change that value to your own team id, or override it on the command line:

```bash
xcodebuild -project TreadPilot.xcodeproj -scheme TreadPilot \
  -destination 'id=<your-device>' DEVELOPMENT_TEAM=<your-team-id> build
```

The Simulator needs no signing at all, so most contributions never hit this.

Tests:

```bash
xcodebuild test -project TreadPilot.xcodeproj -scheme TreadPilot \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

No treadmill? Demo Mode simulates one and exercises the whole UI, including in
the simulator.

## House rules

- **Protocol tests are built on verified hex captures from real hardware.**
  If you change the parser, the existing frames must still decode correctly. Do
  not adjust a test's expected bytes to make a change pass — that test encodes
  what a physical machine actually sent.
- **Swift 6 strict concurrency** on the iOS target. The watchOS target stays in
  Swift 5 mode because of the HealthKit delegate patterns.
- Match the surrounding code style. Comments in the codebase are in Hungarian;
  new comments may be in English or Hungarian, whichever you are comfortable
  with — nobody will reject a patch over that.
- Keep pull requests focused. One concern per PR.

## Localisation

English is the development language: the English string in the source **is**
the lookup key. Translations live in String Catalogs — `Localizable.xcstrings`
and `InfoPlist.xcstrings`, one pair per target.

Two things that will bite you otherwise:

- **Every key needs an explicit `en` entry as well as the translated one.**
  Without it no `en.lproj` is produced, and a device set to a third language
  falls back to the wrong translation instead of English.
- **`^[…](inflect: true)` does not work in this project** — it renders the raw
  markup on screen. Use a String Catalog plural variation instead.

Strings in plain `String` context (model and service layers) need an explicit
`String(localized:)`; SwiftUI literals in `Text`, `Button`, `.alert` and
friends localise on their own.

## Submitting

1. Branch off `main`.
2. Make sure the build is clean and the tests pass.
3. **Sign off your commits:** `git commit -s`. This is how you accept the
   [Contributor Licence Agreement](CLA.md) — you keep the copyright to your
   work; the agreement exists so the App Store build remains legally possible.
   [NOTICE.md](NOTICE.md) explains why in more detail.
4. Open the pull request and describe what you changed, and — if it touches
   belt control — what you tested it on.

## Licence

By contributing you agree that your work is licensed under the
**GNU General Public License v3.0 or later**, and under the additional terms of
[CLA.md](CLA.md).

Note that the TreadPilot name, wordmark and app icon are **not** covered by the
GPL grant. Forks are welcome and encouraged; they just need their own name and
their own icon. See [NOTICE.md](NOTICE.md).

Questions: hello@backlog.hu
