# Contributor Licence Agreement

**TreadPilot — Backlog Kft., Budapest, Hungary**
Version 1.0, 2026-08-20

> **Not legal advice.** This document is written in plain language on purpose.
> If you are contributing on behalf of an employer, or anything here matters to
> you legally, please have someone qualified read it first.

By submitting a contribution to this project — a pull request, a patch, a
protocol trace, documentation, a translation — you agree to the terms below.

## 1. What you are giving us

You grant Backlog Kft. a perpetual, worldwide, non-exclusive, royalty-free,
irrevocable licence to use, reproduce, modify, adapt, publish, sublicense and
distribute your contribution, **including the right to distribute it under
licences other than the GPL**.

You also grant every recipient of the software a patent licence covering any
patent claims you own that your contribution necessarily infringes.

## 2. What you keep

**You keep the copyright to your contribution.** This is a licence, not an
assignment. You can use your own code anywhere else, for anything, forever. You
are not signing anything away.

## 3. Why we ask for this

Two reasons, both concrete:

1. **The App Store.** Apple's terms and the GPL are in conflict. Backlog Kft.
   can ship a build to the App Store because, as the copyright holder, it is not
   bound by its own GPL grant. If contributions arrived under the bare GPL, the
   combined work could no longer be distributed there and the released app would
   have to be withdrawn. Clause 1 prevents that.

2. **Keeping the licence maintainable.** If the project ever needs to move to a
   different licence — because a court reads GPLv3 differently, or a platform
   changes its rules — that has to be possible without tracking down every past
   contributor.

What this is **not** for: the project stays GPL-3.0-or-later publicly. This
agreement does not let us take your work private and it does not stop you doing
anything with your own code.

## 4. What you are confirming

By contributing, you confirm that:

- the contribution is your own work, or you have the right to submit it;
- if your employer has rights to work you produce, they have approved this
  contribution, or they have waived those rights;
- to the best of your knowledge, your contribution does not knowingly infringe
  anyone's copyright, patent, trademark or trade secret;
- you have not copied code from a vendor SDK, a decompiled binary, or any
  source you are not permitted to copy from. **This matters especially for
  protocol work** — traces captured from your own hardware are welcome;
  reverse-engineered vendor source code is not.

## 5. No warranty, no obligation

Your contribution is provided as-is, with no warranty. Nobody is obliged to
merge anything, and nobody owes you compensation.

## 6. How you sign it

You do not need to send a form. Add a `Signed-off-by` line to your commits:

```
git commit -s -m "Your commit message"
```

which appends:

```
Signed-off-by: Your Name <your@email.example>
```

That sign-off means you have read this file and agree to it. Use your real name
and a real email address.

---

Questions: hello@backlog.hu
