#!/usr/bin/env swift
// Stitches DesignLab screenshots into one contact sheet per variant.
// Usage: swift scripts/design-contact-sheet.swift docs/design/variants
// Reads <V>-<screen>-<state>-<appearance>.png and writes <V>-sheet.png.

import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/design/variants")

/// Display order and caption for each screen-state-appearance suffix.
let order: [(suffix: String, caption: String)] = [
    ("now-wifi-light", "Now · Wi‑Fi · light"),
    ("nowscrolled-wifi-light", "Now, scrolled · Wi‑Fi"),
    ("now-wifi-dark", "Now · Wi‑Fi · dark"),
    ("now-cellular-dark", "Now · Tailscale relay on 5G"),
    ("now-idle-light", "Now · no Mac connected"),
    ("sources-wifi-light", "Sources tab"),
    ("details-wifi-light", "Details tab · Wi‑Fi"),
    ("details-cellular-dark", "Details tab · cellular · dark"),
    ("settings-wifi-light", "Settings tab"),
]

let titles = [
    "A": "A · Now Playing first — calm, player-led",
    "B": "B · Control panel — dense, glanceable tiles",
    "C": "C · Glance — one screen, one number",
]

let thumbWidth: CGFloat = 402
let thumbHeight: CGFloat = 874
let gap: CGFloat = 36
let captionHeight: CGFloat = 44
let titleHeight: CGFloat = 110
let columns = 5

for variant in ["A", "B", "C"] {
    let shots: [(NSImage, String)] = order.compactMap { item in
        let url = directory.appendingPathComponent("\(variant)-\(item.suffix).png")
        guard let image = NSImage(contentsOf: url) else { return nil }
        return (image, item.caption)
    }
    guard !shots.isEmpty else { continue }
    let rows = (shots.count + columns - 1) / columns
    let width = gap + CGFloat(columns) * (thumbWidth + gap)
    let height = titleHeight + CGFloat(rows) * (thumbHeight + captionHeight + gap) + gap
    let size = NSSize(width: width, height: height)

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    let title = titles[variant] ?? variant
    title.draw(
        at: NSPoint(x: gap, y: height - titleHeight + 34),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 44, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1),
        ])

    for (index, shot) in shots.enumerated() {
        let column = index % columns
        let row = index / columns
        let x = gap + CGFloat(column) * (thumbWidth + gap)
        let top = height - titleHeight - CGFloat(row) * (thumbHeight + captionHeight + gap)
        let frame = NSRect(x: x, y: top - thumbHeight, width: thumbWidth, height: thumbHeight)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.18)
        shadow.set()
        let clip = NSBezierPath(roundedRect: frame, xRadius: 44, yRadius: 44)
        NSColor.white.setFill()
        clip.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: 44, yRadius: 44).addClip()
        shot.0.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()

        shot.1.draw(
            at: NSPoint(x: x + 6, y: frame.minY - 32),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.3, alpha: 1),
            ])
    }

    NSGraphicsContext.restoreGraphicsState()
    let output = directory.appendingPathComponent("\(variant)-sheet.png")
    try rep.representation(using: .png, properties: [:])!.write(to: output)
    print("wrote \(output.path) (\(shots.count) shots)")
}
