# Changelog

All notable changes to TreadPilot are documented in this file.

## 1.1.0 — 2026-08-21

Two things a runner asks for that 1.0 could not answer. A program segment can now be given a
distance instead of a duration — "5 km at 8 km/h" is finally something the app can be told — and,
switched on deliberately, the app can hold a heart-rate zone by adjusting the belt itself.

The distance half is straightforward and changes one assumption: for a distance segment the
distance is exact and the time is a projection, where every segment in 1.0 was the other way
round. Estimated times are marked as estimates everywhere they appear.

The heart-rate half is the reason this release took the work it did. Telling a treadmill to hold
a zone means the app writes speed to a machine moving under someone's feet, on its own, and the
belt has to do the right thing when the heart-rate feed drops out, when the Bluetooth link goes
quiet, when the user reaches for the console, and when the number the whole thing is computed
from is simply wrong. Most of this release is those cases. The feature is off by default, asks
once before its first run, needs an Apple Watch, and will not steer anyone into their top zone.

Between them sits a smaller piece that exists to make the third one honest: heart-rate zones
computed from your own body data, and a measurement of how reliable your Watch's heart rate
actually is, recorded per workout. The zones shipped before the control did, deliberately, so
the feed's reliability could be judged before it was allowed to steer.

The test suite grew from 46 tests to 487.

### Features

#### Distance goals for program segments

**Need:** The editor could only say "run for five minutes". Every runner thinks in kilometres.

**Solution:** A segment now carries a goal — a duration or a distance — chosen with a picker in
the segment editor. A distance segment ends when the distance is covered, however long that
takes, so slowing down lengthens the segment instead of shortening it.

_Verified:_

- A segment can be given a distance from 0.1 to 42.2 km, and it survives an app restart
- The workout screen shows progress against the goal (3.2 / 5.0 km) with the remaining time as an estimate below it
- Pace in min/km is shown alongside km/h wherever a distance segment is edited or run
- Program totals: the distance is exact, the time carries a "~" in the editor, the program list, the home screen and the workout screen
- Distance does not accumulate while the program is suspended, while the belt is standing, or while the Bluetooth data has gone stale
- Distance is measured by the app rather than read from the console, whose own counter is quantised to 100 m and resets when a console workout restarts
- A distance segment cannot run unbounded if the console under-reports its speed
- Existing duration-based programs behave as before

#### Heart-rate zones from your own body data

**Need:** "Zone 3" means nothing without knowing the person. A percentage of an age-based maximum
puts a trained runner in the wrong zone all season.

**Solution:** Five zones computed on heart-rate reserve (Karvonen), from a maximum and a resting
heart rate that resolve from your own override, then Apple Health, then an age formula. The
profile screen shows the resulting boundaries in bpm, and the workout screen shows which zone
you are in.

_Verified:_

- Maximum and resting heart rate are editable in the profile, with the Health value shown when there is no override
- Resting heart rate is read from Health; the maximum may be raised by what Health has observed, but never lowered by it
- A single Health sample cannot move a zone boundary, and the app's own exported samples are excluded from the evidence
- When Health holds a maximum lower than the age formula, the profile says so, so the estimate can be corrected
- A profile with no usable reserve produces no zones rather than nonsense
- The zone appears only while a live heart rate is available, and disappears when the reading goes stale
- The last known Health values are kept, so a cold launch does not zone against a fallback
- The basis is frozen when a workout starts and cannot move mid-workout

#### Watch heart-rate coverage per workout

**Need:** Before a heart rate is allowed to steer a belt, it is worth knowing how often the feed
actually delivers — and after the fact, nobody can remember.

**Solution:** Every workout records what share of its moving time had a live heart rate from the
Watch, and the summary and history show it.

_Verified:_

- The number measures the Watch feed specifically, because that is the feed heart-rate control uses
- 100% means the feed never dropped; a workout with no Watch reads 0%, not "no data"
- Workouts recorded before this version report the figure as unmeasured rather than inventing one
- The handlebar sensor is not counted as coverage

#### Heart-rate driven segments

**Need:** Holding a zone by hand means reaching for the console every couple of minutes, which is
the opposite of a steady effort.

**Solution:** A segment can be given a heart-rate band instead of a fixed speed. The app adjusts
the belt — speed or incline, your choice per segment — to hold you in that band, inside speed and
incline limits you set. It is off by default and asks once before its first run.

_Verified:_

- The loop evaluates every 10 s and moves at most 0.2 km/h or one incline level at a time, because heart rate lags load by 20 to 40 seconds
- The band-following loop never commands outside the segment's own limits intersected with the treadmill's; the two ceilings and the feed-loss fallback are bounded by the treadmill's limits alone, so a segment's floor cannot hold a brake up
- It never adds load while the heart rate is above the band, or while there is no fresh reading
- Only the Apple Watch feed may steer; the handlebar sensor remains display and recording only
- With the setting off, a heart-rate segment runs at its start speed as an ordinary fixed segment, and nothing about heart rate touches the belt
- A missing reading freezes the belt, then falls back to the segment's declared fallback speed after 30 s
- Above 92% of the frozen maximum the app reduces the load regardless of the band; above 97% it stops the belt
- A stop the app asked for is re-issued until the belt is observed stopped, and if it is not, the user is told to stop it at the console
- A band above the force-down ceiling is refused rather than chased, so the app will not hold anyone in their top zone
- If the band cannot be reached at the segment's upper limit, the app stops pushing and says so
- Every command is one step from where the belt actually is, so a speed you set by hand persists; a decisive change hands control back for the rest of the segment
- Nothing is written while the Bluetooth link is stale, because every number describing the belt is then a memory
- The band, the limits and the ceilings are those of the workout in progress and cannot be changed underneath it
- The workout screen shows what the loop is doing: holding, adjusting, frozen, on fallback, at the ceiling, target not reached, or handed back
- The history detail draws the target band behind the heart-rate curve, so a workout shows whether the app held what it promised
- A workout the app stopped on heart rate says so in its summary and in its history, not only while it is running
- A saved band the profile's basis can no longer hold is not rewritten when the editor opens: the editor says so, says the segment would run fixed, and offers the holdable band as a single tap that names both values

#### Active recovery segments

**Need:** An interval program wants "jog easy until the pulse comes down", not a fixed guess.

**Solution:** A segment can end when the heart rate drops below a value you choose. It always
carries a walking speed rather than a stop, and a mandatory time cap so a failing sensor cannot
stall the program.

_Verified:_

- The segment holds its walking speed until the heart rate falls below the threshold or the cap elapses, whichever comes first
- The walking speed cannot be zero
- With no heart-rate reading at all, the segment behaves as an ordinary timed segment of its cap

#### Demo mode drives the heart-rate loop

**Need:** A feature that moves a belt by itself cannot be developed, screenshotted or reviewed
only on a real treadmill.

**Solution:** The simulated treadmill now produces a heart rate that lags load the way a real one
does, and a seeded demo program exercises a governed segment and a recovery segment.

_Verified:_

- In demo mode the loop receives the synthetic heart rate and visibly steers
- The trace is deterministic, and nothing outside demo mode is affected
- Demo mode cannot be entered over a live treadmill link, and entering it consumes a deferred scan request, so a cold launch cannot pull a running demo back to the scan screen

#### A diagnostic log for the hardware test

**Need:** The governor's tests cover the logic; the real belt, console and Watch are where the
unknowns live — and a tester's account of a run cannot be replayed.

**Solution:** A developer toggle in the profile, off by default. Switched on, every program
workout writes a structured event log: each governor evaluation with its full input and
decision, every write with its requested and clamped values and who asked for it, manual
interventions, staleness and feed gaps, and the stop lifecycle. The log stays on the device
and leaves it only through the share sheet.

_Verified:_

- With the toggle off nothing is written, and the cost at every call site is a single flag read
- The pure governor contains no logging at all; every number in the log comes from the caller or from the governor's own helpers, so log and law cannot disagree
- A governed demo workout produces every key event kind; files rotate at ten

### Bug fixes

#### The handlebar heart rate was an unfiltered byte

**Need:** The heart rate from the console's handlebar sensor was passed through exactly as
received — a single byte, anything from 0 to 255 — and believed by the calorie estimate, the
saved samples and the Apple Health export.

**Solution:** The value is now checked for plausibility where the frame is parsed, so one garbled
frame cannot become a 250 bpm reading.

_Verified:_

- An implausible value is discarded rather than recorded
- The app's own exported samples are no longer treated as evidence about the user's maximum heart rate

#### The handlebar heart rate never went stale

**Need:** The Watch's reading expires after 10 seconds, but the console's held its last value
indefinitely. A minute of Bluetooth silence left a minute-old heart rate on screen under the
"not updating" warning, and counted it as recorded.

**Solution:** The reading now expires from its own arrival, not from the arrival of any frame —
because a frame that carries no heart rate cannot vouch for one.

_Verified:_

- After the freshness horizon the heart rate reads as absent everywhere, including the calorie calculation and the recording

### Project and release

#### Version 1.1.0

**Need:** The version lives in the generated Info.plist files, which are written from project.yml.

**Solution:** Both the iOS and the watchOS target declare 1.1.0 (build 2) in project.yml, and the
plists are regenerated from it.

_Verified:_

- Both targets report 1.1.0 (2)
- The Health permission text covers heart rate, which the app now reads for training zones
- The safety disclaimer states that heart-rate control is a fitness feature and not a medical device, and is shown once to users upgrading from 1.0

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
