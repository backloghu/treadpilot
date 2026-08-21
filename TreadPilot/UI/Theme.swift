// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

import SwiftUI

/// Backlog.hu brand tokens — source: backlog_landing/docs/brand/tokens.json.
/// Principle: "Engineering Minimalism / Future Industrial" — a dark default, a
/// neon yellow accent, Space Grotesk for display, content arranged in boxes.
enum Brand {
    // Colours (tokens.json → color)
    static let bgDeep = Color(hex: 0x030303)
    static let bgElev1 = Color(hex: 0x0A0A0A)
    static let bgElev2 = Color(hex: 0x111111)
    static let ink = Color(hex: 0x1A1A1A)
    static let fgMid = Color(hex: 0xD6D6D6)
    static let fgDim = Color(hex: 0xB3B3B3)
    static let grey = Color(hex: 0x888888)
    static let accent = Color(hex: 0xFFEB3B)   // Neon Yellow — on a dark background
    static let gold = Color(hex: 0xC7A008)     // Industrial Gold — on a light background
    static let gridLine = Color.white.opacity(0.10)
    static let danger = Color(hex: 0xFF5347)

    // Radii (tokens.json → radius; 6 on a dense surface)
    static let radius: CGFloat = 6

    // Display typography: Space Grotesk (bundled TTFs)
    enum DisplayWeight: String {
        case light = "SpaceGrotesk-Light"
        case regular = "SpaceGrotesk-Regular"
        case medium = "SpaceGrotesk-Medium"
        case semibold = "SpaceGrotesk-SemiBold"
        case bold = "SpaceGrotesk-Bold"
    }

    static func display(_ size: CGFloat, _ weight: DisplayWeight = .medium) -> Font {
        .custom(weight.rawValue, size: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Reusable brand elements

/// "Box logo": a black, rounded box with white lettering + a yellow dot.
/// Per the brand rule the box stays black even on a light background.
struct BrandWordmark: View {
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 0) {
            Text("TREADPILOT")
                .font(Brand.display(size, .semibold))
                .tracking(1.5)
                .foregroundStyle(.white)
            Text(".")
                .font(Brand.display(size, .bold))
                .foregroundStyle(Brand.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Brand.ink, in: RoundedRectangle(cornerRadius: Brand.radius))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.gridLine))
        .fixedSize() // keep a crowded toolbar from truncating the wordmark
    }
}

/// Section label ("eyebrow"): uppercase, letter-spaced, grey.
struct BrandEyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Brand.display(11, .medium))
            .tracking(1.8)
            .foregroundStyle(Brand.grey)
    }
}

/// Finding 88: the unmissable banner for `client.stopNotObeyed`. One view
/// rather than two copies in `HomeView` and `DashboardView` — both need it,
/// because it has to survive an ordinary navigation between the two screens,
/// not just live on the screen the stop was requested from.
struct SafetyStopBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(Safety.stopNotObeyed)
        }
        .font(Brand.display(12, .semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.danger, in: RoundedRectangle(cornerRadius: Brand.radius))
    }
}

/// Content box: a slightly raised background with a 1px grid-line border.
struct BrandBox: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.bgElev1, in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.gridLine))
    }
}

extension View {
    func brandBox(padding: CGFloat = 16) -> some View {
        modifier(BrandBox(padding: padding))
    }
}

/// Primary CTA: a neon yellow box with black, uppercase Space Grotesk lettering.
struct BrandCTAStyle: ButtonStyle {
    var fill: Color = Brand.accent
    var textColor: Color = Brand.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.display(14, .semibold))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(fill, in: RoundedRectangle(cornerRadius: Brand.radius))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Secondary button: an outlined ("stroke") style.
struct BrandStrokeStyle: ButtonStyle {
    var color: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.display(14, .semibold))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Brand.bgElev1, in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius)
                .stroke(color.opacity(0.35), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
