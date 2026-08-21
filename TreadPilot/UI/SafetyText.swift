// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import Foundation

/// Safety-critical user-facing strings in one place.
///
/// These instructions protect physical safety, so they must be word-for-word
/// identical at EVERY occurrence — kept as separate literals per screen they
/// would drift apart sooner or later (which is exactly what happened during
/// localization: the same sentence appeared in four different English variants).
/// A computed property rather than a `let`, so it is re-evaluated after a
/// language change.
enum Safety {

    /// The baseline instruction before a start. The "not on the belt" clause is
    /// deliberate: the belt starts on its own, so mentioning the side rails is
    /// not enough.
    static var standClear: String {
        String(localized: "Stand on the side rails, not on the belt, and clip on the safety key.")
    }

    /// A stop the app requested (a user tap, or the 97% heart-rate ceiling) that
    /// the belt has not obeyed within `FitShowTreadmillClient.stopFailureSeconds`
    /// (spec section 4, "A stop the app asked for outlives the program that
    /// asked"). The one visible failure in this feature: a safety rule that did
    /// not fire must not look like one that did, so this has to be unmissable
    /// wherever `client.stopNotObeyed` is set — and it must survive an ordinary
    /// navigation, not just the screen the stop was requested from.
    static var stopNotObeyed: String {
        String(localized: "The belt did not stop. Stop it now at the console.")
    }

    /// The one-time confirmation before heart-rate control may be switched on
    /// (spec section 4, "Opt-in and disclosure"; finding 120). Shown once, gated
    /// by an "asked once" flag on the toggle itself in `ProfileView` — gating
    /// the capability rather than a start path, so a program start can trust
    /// the setting without asking again, and switching the toggle on mid-workout
    /// cannot reach a governed segment without ever having asked. States plainly
    /// that the belt's speed changes on its own, and that a console change
    /// always wins.
    static var heartRateControlConfirmation: String {
        String(localized: "With heart-rate control on, the app changes the belt's speed or incline by itself to hold your target zone — without you touching anything. Changing speed or incline at the console always takes control back for the rest of that segment.")
    }

    /// The 97% stop ceiling's own reason, shown next to `ProgramRunner
    /// .governorStopReason == .heartRateCeiling` for as long as the finished
    /// workout is on screen (finding 122). A belt stopping on its own, with no
    /// console error and nobody having pressed stop, is not self-explanatory
    /// without it.
    static var heartRateCeilingStoppedTheBelt: String {
        String(localized: "The belt was stopped because your heart rate reached its limit.")
    }
}
