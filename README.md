# TunturiRun

iPhone-app a Tunturi Competence T40 futópad (BLE-név: `SW5010CAI-2678`, 2019-es
FitShow-generációs konzol) Bluetooth-os kiolvasásához és vezérléséhez.

A protokoll-kutatás teljes riportja (FTMS és FitShow bájtszinten, modellenkénti
verdiktek, források): a projekthez tartozó „Tunturi BLE protokollkalauz” artifact.

## Felépítés

- `TunturiRun/FitShow/` — a FitShow-protokollréteg
  - `FitShowFrame.swift` — keretezés (`0x02 | CMD | DATA | XOR-FCS | 0x03`)
  - `FitShowProtocol.swift` — parancsépítők, válasz-parser, limitek
  - `TreadmillClient.swift` — CoreBluetooth-kliens: szkennelés (`0xE0FF` + `0x1826`),
    csatlakozás, notify a `0xFFE4`/`0xFFF1`-en, írás a `0xFFE1`/`0xFFF2`-n,
    200 ms-os státusz-poll, parancs-várólista visszhang-nyugtázással
- `TunturiRun/Model/` — edzésprogram-modell és -futtató
- `TunturiRun/UI/` — SwiftUI: keresés, dashboard, kézi vezérlés, programfuttatás
- `TunturiRunTests/` — a kutatásból ismert, ellenőrzött hex-keretekre írt unit tesztek

## Build

A projektfájlt XcodeGen generálja:

```bash
xcodegen generate
open TunturiRun.xcodeproj
```

Teszt: `⌘U` az Xcode-ban, vagy:

```bash
xcodebuild test -project TunturiRun.xcodeproj -scheme TunturiRun -destination 'platform=iOS Simulator,name=iPhone 17'
```

Valódi padhoz fizikai iPhone kell (a szimulátornak nincs Bluetooth-ja):
válaszd ki a saját csapatodat a Signing alatt, futtasd a telefonon, majd
a keresőben koppints az `SW5010CAI-2678` eszközre.

## Biztonság

- A szalag indítása csak megerősítő párbeszéd után történik; program csak már
  futó szalagon indítható.
- A sebesség/dőlés a pad limitjeire van szorítva (alapértelmezés a T40
  specifikációja: 16 km/h, 0–12% — ha a konzol válaszol a SYS_INFO-ra,
  a tényleges értékek felülírják).
- Kapcsolatvesztésnél az app riaszt: a FitShow-ban (és az FTMS-ben) nincs
  link-loss védelem, a szalag az utolsó sebességgel megy tovább — a végső
  védelem a pad biztonsági kulcsa.
- Első teszteknél: alacsony sebesség, biztonsági kulcs felcsíptetve, ne állj
  a szalagon.

## Ismert nyitott kérdés

A szünet-parancs a QZ szerint `0x06`, a gyártói doksi szerint `0x0A`
(`FitShowProtocol.swift`, `ControlSub`) — az elsőt küldjük, eszközön tesztelendő.
