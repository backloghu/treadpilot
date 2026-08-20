# Changelog

All notable changes to TreadPilot are documented in this file.

## 1.0.0 — 2026-08-20

The first release of TreadPilot. The app controls FitShow-based treadmills (for example
the Tunturi Competence series) from an iPhone, and turns a run into a complete, reviewable
workout.

Every workout is recorded automatically: a summary appears when you finish, and the History
screen keeps detailed statistics along with speed and heart-rate charts. Workouts are written
to Apple Health — and if a save was missed, it can be completed afterwards. Heart rate comes
from the new Apple Watch companion app and is mirrored live on the phone, while calories are
computed by the app from your body data instead of the treadmill's own unreliable estimate.
Total elevation gain is measured as well.

Workout programs are now complete: you can build your own in the editor (duration, speed and
incline per segment), start a program from a standing belt with a confirmation and a countdown,
and while running, the top of the screen always shows the segment countdown, the next segment
and the time remaining. After connecting, a new home screen lets you choose between a manual
and a program-driven start.

Bugs found on a real treadmill were fixed too: elapsed time, calories and step count are now
accurate, a workout can be resumed after a pause, and workouts run with heart-rate monitoring
on the Watch reliably reach the Health app.

The app is available in English and Hungarian, has its own icon, and has been submitted to the
App Store. The project has also become open source: the code is available on GitHub under the
GPL v3 license (the TreadPilot name and logo are reserved), and treadpilot.app presents how the
app works. Some additional technical groundwork for the release is not itemised here.

### Features

#### Workout recording and history

**Need:** Workouts vanished without a trace — there was no history and no summary.

**Solution:** Every workout is now recorded automatically: a summary appears when it ends, and
the History screen lets you review every past workout with detailed statistics and speed and
heart-rate charts.

_Verified:_

- Every workout is recorded automatically (both manual and program-driven starts)
- Time-series samples are stored (speed, incline, heart rate, distance) at roughly 1 s resolution
- Data collected so far is not lost if the app is terminated mid-workout
- History list: date, duration, distance, average speed and kcal per row
- Detail view: summary plus speed and heart-rate charts
- Paused time is kept separate from moving time
- A session can be deleted from the history

#### Workout program editor

**Need:** There were only two factory-built workout programs — you could not put together your
own training plan.

**Solution:** A new program editor: you can assemble your own programs from any number of
segments (duration, speed, incline), reorder and duplicate segments, and copy the built-in
programs as a starting point. Your own programs are stored on the device and can be started at
any time.

_Verified:_

- A custom program can be created: name plus any number of segments (name, duration, speed, incline)
- Segments can be reordered, duplicated and deleted
- Speed and incline values are clamped to the treadmill's limits in the editor too
- A saved program survives an app restart (SwiftData)
- Custom programs appear in the dashboard's program picker and can be started
- Built-in programs cannot be edited, but can be duplicated into custom ones

#### Program start with a countdown

**Need:** A workout program could only be started on an already moving belt — having to start
the treadmill by hand first was inconvenient.

**Solution:** A program can now be started from a standing belt: after a confirmation the app
counts down, then starts the treadmill itself with the first segment's settings. The countdown
can be cancelled at any time.

_Verified:_

- On a standing belt the "Start program" button is enabled and shows a confirmation dialog
- After confirming, an app-side countdown appears that can be cancelled (in which case the belt does not start)
- The belt only receives a start command after the confirmation and the countdown
- The first segment's targets are only sent once the treadmill is actually running (RUNNING status)
- Starting a program on a moving belt works as before
- During the console's own 3–5 s countdown the app does not flood the treadmill with commands

#### Remaining time and next segment while a program runs

**Need:** While a workout program was running, there was no way to see how much of the whole
program was left or what the next segment would be.

**Solution:** The program panel now shows the total time remaining, a progress bar, and the name
and settings of the next segment — so you always know what is coming during a workout.

_Verified:_

- While a program runs, the time remaining from the whole program is visible
- A progress bar shows the program's progress
- The next segment's name and targets are visible; the last segment is marked accordingly
- Correct values are shown for a suspended program as well
- Unit tests cover the remaining-time and next-segment calculations

#### Program totals in the editor (distance, elevation, average speed)

**Need:** The program editor only showed total duration — not the program's expected distance,
elevation gain or average speed.

**Solution:** A new totals row at the top of the editor shows all four values, and updates
immediately while you edit.

_Verified:_

- The editor shows the program's total duration, expected distance, elevation gain and average speed
- The values update immediately when a segment is modified
- A unit test covers the calculations (e.g. 600 s @ 6 km/h @ 5% + 300 s @ 12 km/h = 2.0 km, 50 m, 8.0 km/h)

#### Workout screen: running program moved to the top, single-screen layout

**Need:** While a workout program was running, the segment information sat at the bottom of the
screen and was not visible during a workout.

**Solution:** The program now lives in a compact bar at the top of the screen: a large segment
countdown, the next segment and a progress bar — and every other reading fits on one screen,
without scrolling.

_Verified:_

- While a program runs, the segment information appears at the top of the screen, always visible
- The segment countdown is shown at an emphasised size
- The whole screen (header + program + speed + statistics + controls) fits without scrolling
- The next segment and the total time remaining are visible in the bar
- The layout is unchanged for a manual workout
- The program can be stopped from the bar

#### Home screen after connecting: program or manual start

**Need:** After connecting, everything was on one crowded screen — start, programs, history,
disconnect.

**Solution:** A new home screen greets you after connecting: you can choose a manual or a
program-driven start, and reach program management, history, your profile and disconnect from
here. The workout screen is decluttered: only live data and the controls remain.

_Verified:_

- After connecting, a home screen appears with a manual start / workout program choice
- Program management, history, profile and disconnect are reachable from the home screen
- The workout screen has no program starter — only live data, controls and the active program's state
- At the end of a workout (standing belt, no active program) the app returns to the home screen
- After a pause, the run can be resumed from the workout screen
- The safety confirmations (manual and program start) are unchanged

#### Apple Watch heart rate — watchOS companion app with live mirroring

**Need:** Heart rate could only be measured by the treadmill's handlebar sensor, which is
unusable while running.

**Solution:** A new Apple Watch companion app measures heart rate during a workout and mirrors
it live on the iPhone app's dashboard. The Watch app starts by itself when a workout begins, and
the data also feeds the calorie calculation and the workout log.

_Verified:_

- The watchOS companion app target builds and installs onto the Watch
- A workout started from the iPhone app starts the Watch workout session
- The dashboard's heart-rate field shows the Watch's live heart rate (< 5 s latency)
- Without a Watch the app behaves as before (fallback: treadmill HR or "–")
- The Watch session closes cleanly at the end of a workout
- HealthKit permissions are requested correctly, and their absence does not cause a crash

#### Calorie calculation from body data (HealthKit profile + override)

**Need:** The calorie figure was the treadmill's unreliable estimate, which did not take body
data into account.

**Solution:** The app now computes its own, more accurate calorie figure from body weight, age
and sex — and with heart rate available, using a heart-rate-based formula. Body data is loaded
automatically from the Health app, and can also be entered by hand on the Profile screen.

_Verified:_

- The app reads weight, height, date of birth and biological sex from HealthKit (with permission)
- The values are visible and can be overridden on the Profile screen; an override survives an app restart
- With heart rate available, an HR-based calorie estimate runs
- Without heart rate, a MET-based estimate (speed + incline) runs
- The dashboard shows the app's own computed calories
- Missing body data falls back to a sensible default plus a warning, with no crash

#### Total elevation gain

**Need:** Alongside distance, the total elevation gained during a workout (e.g. "80 m of
climbing") should also be visible.

**Solution:** The app continuously computes elevation gain from speed and incline: it is visible
live on the dashboard, and appears in the workout summary, in the history, and in the workout
saved to the Health app.

_Verified:_

- The dashboard shows total elevation gain live during a workout
- The elevation gain value appears in the end-of-workout summary and in the history detail view
- Only distance covered at a positive incline counts as elevation gain
- The value is also written into the metadata of the workout saved to Health
- A unit test covers the calculation (e.g. 10 km/h @ 10% ≈ 0.278 m/s)

#### Saving workouts to Apple Health

**Need:** Finished workouts did not reach Apple Health, so other apps (training logs, Strava
bridges) could not see them.

**Solution:** Workouts are written to the Health app when they end, automatically or via a manual
button — with the correct type, distance, calories and heart-rate data, and without duplication.

_Verified:_

- At the end of a workout it appears in the Apple Health app (type, duration, distance, energy)
- Heart-rate samples are included when heart-rate data was available
- The indoor flag is set correctly
- If Health permission is denied, the app gives a clear message and does not crash
- No duplicate workout is created when the Watch session also saved one
- Automatic saving can be turned on and off

#### Retroactive Health sync from the workout detail view

**Need:** If saving a workout to Apple Health failed at the end, it should not be lost — there
should be a way to complete it afterwards.

**Solution:** A "Save to Health" button now appears in the workout history detail view, so any
earlier workout can be synced afterwards. An indicator in the list shows which workouts are
already in Health.

_Verified:_

- The Health section appears in the history detail view
- For an unsynced workout the "Save to Health" button works, and the indicator changes after a successful save
- For an already saved workout the "Saved" indicator is shown, and a double save is not possible
- For a demo workout the demo indicator is shown, without a button
- A failed save shows an error message with a retry

#### English localization — English as the base language, Hungarian as a translation

**Need:** The app was only available in Hungarian; an App Store release and an international
audience need English as well.

**Solution:** The app can now be used in English and Hungarian — the device language decides,
and on phones set to any other language it appears in English. The translation covers the whole
interface, down to the permission prompts and the Apple Watch app.

_Verified:_

- With the device language set to English, every screen appears in English (home, workout, history, programs, editor, profile, summary, disclaimer, scan, Watch)
- With the device language set to Hungarian everything stays in Hungarian, with no missing translations
- On a device set to any other language, English is the fallback
- The permission prompts (Bluetooth, Health) are correct in both languages
- Built-in program names and segment names are localized too
- The build and all unit tests pass

#### treadpilot.app landing page (HTML/CSS/JS, Vercel)

**Need:** The treadpilot.app domain needed an introductory page explaining what the app does and
that it is open source.

**Solution:** treadpilot.app is built and live: real screenshots, a step-by-step walkthrough, a
developer section, and a proper preview when shared. The site updates automatically from the
repository.

_Verified:_

- A static page in the /landing directory, without a framework (HTML + CSS + JS)
- Responsive: looks right on mobile and on desktop
- iPhone and Watch screenshots are included
- How it works, the open-source status and Backlog Fejlesztő Kft. as the developer are described
- Developer section: build, protocol, contributing
- A safety warning is visible
- Ready for Vercel deployment (vercel.json / root directory setting documented)
- Readable under both dark and light system themes

### Bug fixes

#### Elapsed time and calories misread — FitShow AnyRun variant

**Need:** On a real treadmill, workout time showed nonsensical numbers and calories were
unrealistically high (e.g. 1536 kcal after 10 seconds).

**Solution:** The app now detects the treadmill console's data format variant automatically, and
correctly shows elapsed time, calories, distance and step count. The detection is remembered per
treadmill, so the values are accurate immediately on reconnect.

_Verified:_

- The Time field shows the actual elapsed time on the T40
- The Calories field shows a realistic value (matching the treadmill's display)
- Distance and step count are also correct (fields likewise affected by the byte swap)
- Behaviour on standard FitShow consoles is unchanged
- Variant detection is remembered per device (correct immediately on reconnect)
- Unit tests cover both variants and the detector

#### Step count shows a huge value on the T40

**Need:** The step count showed an unrealistically large value on the treadmill.

**Solution:** The app detects and corrects the treadmill console's byte-swapped step-count data —
the displayed value is now realistic.

_Verified:_

- The Steps field shows a realistic value on the T40
- The plausibility choice works for both variants (self-healing LE↔BE swap)
- For an implausible value, 0 / "–" is shown instead of garbage
- Unit tests cover the byte-swap case

#### A workout could not be resumed after a pause

**Need:** A workout could not be resumed after a pause — the treadmill stopped, but the app
offered no way to continue, and the program's counter kept running down.

**Solution:** The pause is sent using the treadmill's official pause command, the Resume button
is always available on a standing belt, and the program waits while paused and continues from
where it left off.

_Verified:_

- After a pause there is always a RESUME option in the app
- Resuming actually restarts the belt
- The program segment's counter stops while paused, and the segment's targets are re-sent on resume
- STOP is also available on a standing belt (in any status)
- The pause frame's unit test covers opcode 0x0A

#### Workouts did not reach Apple Health when the Watch was used

**Need:** Workouts run with heart-rate monitoring on the Watch did not reach the Health app.

**Solution:** The phone now always saves the workout to the Health app with the complete data set
(distance, calories, heart rate, elevation gain), while the Watch acts purely as a heart-rate
sensor — so every workout is recorded exactly once.

_Verified:_

- The workout reaches Health even when the Watch is used (once)
- A workout without the Watch is recorded as before
- No duplicate workout
- A demo workout is still not recorded
- On a failed save the summary shows an error message with a manual retry button

### Project and release

#### App icon

**Need:** The app had no icon of its own.

**Solution:** An app icon matching the brand was created (black field, white T, yellow dot), on
both the iPhone and the Watch app.

_Verified:_

- The app appears with its own icon on the iPhone home screen
- The Watch app gets the same icon
- The icon follows the Backlog brand and works with the TreadPilot name
- The icon generator script is in the repository (reproducible)

#### Open-source groundwork: internal rename to TreadPilot + licenses

**Need:** The project is becoming open source — the brand name should disappear from the code's
internal naming.

**Solution:** The whole codebase now runs under the TreadPilot name (directories, targets,
project file), with license files, a font license and English documentation — ready for
publication. The factual device-name references needed to recognise treadmills were lawfully
left in place. (The license itself was moved to GPL-3.0 later in this same release; see below.)

_Verified:_

- The code's internal names (directories, targets, module, structures) contain no Tunturi
- Functional BLE name detection and the factual protocol documentation work unchanged
- LICENSE and the fonts' OFL license are in the repository
- An English README with build instructions and a safety warning
- The build and all 44 tests pass after the rename

#### Preparing the repository for the first public GitHub push

**Need:** The project had to be made open source so that others can use it and build on it.

**Solution:** The code is publicly available on GitHub, together with contribution guidelines and
license terms.

_Verified:_

- .gitignore covers derived and user-specific files
- CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md and issue/PR templates are in place
- The README is enough on its own for an external developer to get a build going
- The git history contains no secrets and no unintended personal data
- CI passes (build + tests)
- The main branch is pushed to the github.com/backloghu organization

#### License change to GPL-3.0, CLA and trademark reservation

**Need:** The original license would have allowed anyone to take the code, replace the branding,
and ship it as a closed product.

**Solution:** The project moved to the GPL v3 license: anyone who develops and distributes it is
obliged to publish their own version openly as well. The TreadPilot name and logo received
separate protection, and contributions arrive under a defined agreement.

_Verified:_

- LICENSE contains the authentic GPL-3.0 text, and GitHub recognises it
- The name, the wordmark and the app icon are explicitly excluded from the license's scope
- A CLA exists, and CONTRIBUTING.md describes the process
- Source files received a license header
- No MIT references remain (README, landing page, App Store copy)
- The build and tests pass

#### Preparing the App Store release (rename + publication)

**Need:** The app should reach the App Store rather than only running on the developer's phone —
and under a neutral name, because of the "Tunturi" trademark.

**Solution:** The app was submitted to the App Store as TreadPilot, with its own branding and a
bilingual listing. A demo mode was built for review, which demonstrates the whole app without a
treadmill.

_Verified:_

- The new name was decided, a trademark search was done, and the app was renamed (display name + wordmark + App Store name)
- The word "Tunturi" appears only in the description, as a compatibility note
- Demo mode is available on device for App Review, and Review Notes were written
- The App Store listing is ready (screenshots, description in HU + EN, privacy labels)
- A disclaimer was added to the app
- A TestFlight build was shipped and tried
- The app was submitted to App Review
