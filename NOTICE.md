# Notices

TreadPilot is copyright © 2026 Backlog Fejlesztő Kft. (Budapest, Hungary) and is
distributed under the **GNU General Public License, version 3 or later**.
The full licence text is in [LICENSE](LICENSE).

This file records the things the GPL does *not* cover, and the third-party
material the project depends on.

---

## Name, logo and app icon are not licensed

The GPL grants rights to the **software**. It does not grant rights to
trademarks or branding, and this project does not grant them either.

Specifically, the following are **excluded** from the GPL grant and remain the
property of Backlog Fejlesztő Kft.:

- the name **TreadPilot**;
- the **TREADPILOT.** wordmark, in any typeface or arrangement;
- the app icon and any derivative of it;
- the treadpilot.app visual identity as a whole.

You may fork this project and you may distribute your fork — the GPL says so
and we mean it. What you may **not** do is present your fork as TreadPilot, or
use the TreadPilot name, wordmark or icon to identify it. Give your fork its
own name and its own icon. Referring to the origin factually
("a fork of TreadPilot") is fine and always will be.

If you want to use the name or the logo for something else — an article, a
compatibility list, a shop listing — just ask: hello@backlog.hu

---

## Contributions

Contributions are accepted under a Contributor Licence Agreement — see
[CLA.md](CLA.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

The reason is practical rather than defensive. Apple's App Store terms and the
GPL are in conflict (this is why VLC was once pulled from the App Store). As
the copyright holder, Backlog Fejlesztő Kft. is not bound by the GPL when distributing
its own build, which is what makes the App Store release possible. If
third-party code arrived under the bare GPL, the combined work could no longer
be shipped there — and the released app would be the casualty. The CLA keeps
that door open, for everyone's build.

---

## Third-party material

### Space Grotesk

The bundled font files in `TreadPilot/Resources/Fonts/` are **not** part of the
GPL-licensed work. Space Grotesk is copyright © Florian Karsten and is licensed
under the **SIL Open Font License 1.1**. The full text is in
[`TreadPilot/Resources/Fonts/OFL.txt`](TreadPilot/Resources/Fonts/OFL.txt).

### Protocol research

The FitShow protocol implementation was developed from public research,
primarily the [qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift)
project and its issue tracker, plus direct observation of a Tunturi
Competence T40. No vendor code is included in this repository.

---

## Trademarks of others

**Tunturi** is a trademark of Tunturi New Fitness BV. **FitShow** is a
trademark of its respective owner. **Apple**, **iPhone**, **Apple Watch**,
**App Store**, **HealthKit** and **Apple Health** are trademarks of Apple Inc.
**Strava** is a trademark of Strava, Inc.

This project is not affiliated with, endorsed by, sponsored by, or supported by
any of them. Those names appear here and in the source code only to state
factually which hardware and which protocol the software works with — nominative
use, and nothing more.

---

## Safety

This software starts and drives real fitness equipment. It is provided
**without any warranty**, as stated in sections 15 and 16 of the GPL. Use it at
your own risk, always attach the treadmill's safety key, and never rely on
software as your only means of stopping the belt.
