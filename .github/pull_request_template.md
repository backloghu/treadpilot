## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## How you tested it

<!-- Simulator? Demo Mode? A real treadmill? Which model? -->

## Checklist

- [ ] `xcodegen generate` run if files were added, moved or removed
- [ ] Build is clean and `xcodebuild test` passes
- [ ] Commits are signed off (`git commit -s`) — see [CLA.md](../CLA.md)
- [ ] Existing protocol tests still pass with their **original** expected bytes
      (those hex values came from real hardware — do not adjust them to make a
      change pass)

## If this touches belt control

- [ ] The belt still cannot start without an explicit user action
- [ ] Programmed starts still run a countdown the user can cancel
- [ ] Speed and incline are still clamped to the console's reported limits
- [ ] Tested on real hardware, and I said which machine above
