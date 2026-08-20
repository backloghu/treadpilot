# Security Policy

## Reporting a vulnerability

Email **hello@backlog.hu**. Please do not open a public issue for anything you
believe is exploitable — write privately first and give us a chance to fix it.

You can also use GitHub's private reporting: **Security → Report a
vulnerability** on this repository.

Include whatever you have: what you did, what happened, the treadmill model and
console if it is relevant, and any log output. A rough report sent early is more
useful than a polished one sent late.

We will acknowledge within a few working days. This is a small project — there
is no bug bounty, but you will be credited in the release notes unless you
prefer otherwise.

## Supported versions

Only the latest release on `main` is supported. There are no long-term support
branches.

## What we consider a security issue here

This app is unusual: **it drives a real motorised belt that a person stands
on.** That shapes what matters.

**Please report:**

- Anything that could start the belt, or change its speed or incline, without
  the explicit user action the app requires.
- Anything that lets the belt exceed the limits the console reports.
- A way to bypass or suppress the safety disclaimer, the start confirmation, or
  the cancellable countdown before a programmed start.
- A crash or hang in the Bluetooth layer that leaves the belt running while the
  app stops responding — the user loses their software stop button.
- A path that sends malformed frames the console mishandles. We already know one
  real case of this class: a pause opcode taken from another vendor's table
  (`0x06`) locked up a Tunturi T40 until it was power-cycled.
- Health data leaving the device by any route. The app is supposed to make no
  network requests at all.

**Not security issues, but still worth an ordinary bug report:**

- Wrong numbers on screen (distance, calories, step count) with no safety
  consequence.
- Failure to connect to a treadmill we have not verified — open a
  [compatibility report](.github/ISSUE_TEMPLATE/compatibility.yml) instead.
- Anything requiring physical access to an unlocked, paired iPhone. Bluetooth
  pairing is inherently local and proximity-bound; that is the threat model.

## Safety, stated plainly

No software stop is a substitute for the machine's own. The treadmill's stop
button and the safety key remain the primary protection, and the app says so on
first launch. If the Bluetooth link drops mid-workout, the belt keeps running at
the last set speed — this is a property of the protocol, not a bug we can fix in
the app. Report it if the app fails to *warn* about it.
