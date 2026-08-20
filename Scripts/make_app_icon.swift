// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Backlog Fejlesztő Kft. — https://treadpilot.app

// App icon generator — Backlog brand: a Deep Space field, Space Grotesk Bold
// white "T" + a neon yellow dot, with a subtle grid-line texture.
// Run from the repository root: swift Scripts/make_app_icon.swift
import AppKit
import CoreText

let repoRoot = FileManager.default.currentDirectoryPath
let fontURL = URL(fileURLWithPath: repoRoot + "/TreadPilot/Resources/Fonts/SpaceGrotesk-Bold.ttf")
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        || NSFont(name: "SpaceGrotesk-Bold", size: 10) != nil else {
    fatalError("SpaceGrotesk-Bold.ttf not found — run this from the repository root.")
}

let pixels = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Failed to create a drawing surface.")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let cg = context.cgContext
let side = CGFloat(pixels)

// Deep Space background (#030303)
cg.setFillColor(CGColor(red: 0x03 / 255.0, green: 0x03 / 255.0, blue: 0x03 / 255.0, alpha: 1))
cg.fill(CGRect(x: 0, y: 0, width: side, height: side))

// Subtle grid lines at the thirds (the equivalent of the brand's 1px grid lines)
cg.setFillColor(CGColor(gray: 1, alpha: 0.06))
for third in [side / 3, side * 2 / 3] {
    cg.fill(CGRect(x: third - 1.5, y: 0, width: 3, height: side))
    cg.fill(CGRect(x: 0, y: third - 1.5, width: side, height: 3))
}

// "T." — a white letter with a neon yellow (#FFEB3B) dot
guard let font = NSFont(name: "SpaceGrotesk-Bold", size: 640) else {
    fatalError("The SpaceGrotesk-Bold font failed to load.")
}
let yellow = NSColor(calibratedRed: 1.0, green: 0xEB / 255.0, blue: 0x3B / 255.0, alpha: 1)
let text = NSMutableAttributedString(string: "T.", attributes: [
    .font: font,
    .foregroundColor: NSColor.white,
])
text.addAttribute(.foregroundColor, value: yellow, range: NSRange(location: 1, length: 1))

let line = CTLineCreateWithAttributedString(text)
let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
cg.textPosition = CGPoint(
    x: (side - glyphBounds.width) / 2 - glyphBounds.minX,
    y: (side - glyphBounds.height) / 2 - glyphBounds.minY
)
CTLineDraw(line, cg)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG encoding failed.")
}
let outputs = [
    repoRoot + "/TreadPilot/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    repoRoot + "/TreadPilotWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
]
for output in outputs {
    try? FileManager.default.createDirectory(atPath: (output as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    try! png.write(to: URL(fileURLWithPath: output))
    print("Icon written: \(output)")
}
