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
}
