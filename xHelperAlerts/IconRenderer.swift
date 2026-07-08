import AppKit
import SwiftUI

/// Applies the active account's tint to the dock icon. When the active
/// account has no `glyphColor`, the icon falls back to the bundled
/// AppIcon asset (set `NSApp.applicationIconImage = nil`).
///
/// We tint by drawing a rounded coloured square and compositing the
/// "DockGlyph" image on top — keeping the design simple and always
/// readable regardless of the user's colour choice.
@MainActor
enum IconRenderer {
    /// Recompute and apply the dock icon for the currently active account.
    static func apply(activeColor: ColorRGBA?) {
        guard let rgba = activeColor else {
            NSApp.applicationIconImage = nil
            return
        }
        NSApp.applicationIconImage = render(tint: NSColor(
            srgbRed: CGFloat(rgba.r),
            green: CGFloat(rgba.g),
            blue: CGFloat(rgba.b),
            alpha: CGFloat(rgba.a)
        ))
    }

    private static func render(tint: NSColor) -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        // macOS-style squircle. Apple's icon grid leaves transparent
        // padding around the shape — the coloured squircle occupies the
        // inner ~824 px of the 1024 canvas, NOT the full bleed. Without
        // this margin the icon looks oversized next to system icons.
        let canvas = NSRect(origin: .zero, size: size)
        let iconMargin: CGFloat = 100
        let squircle = canvas.insetBy(dx: iconMargin, dy: iconMargin)
        let cornerRadius: CGFloat = 180
        let path = NSBezierPath(roundedRect: squircle, xRadius: cornerRadius, yRadius: cornerRadius)
        path.addClip()
        tint.setFill()
        path.fill()

        if let glyph = NSImage(named: "DockGlyph") {
            // Draw the glyph large inside the squircle (the shape itself is
            // now correctly sized). A modest inset from the squircle edges
            // keeps the spark + stars prominent without touching the corners.
            let glyphInset: CGFloat = 70
            let glyphRect = squircle.insetBy(dx: glyphInset, dy: glyphInset)
            glyph.draw(in: glyphRect,
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1.0)
        }
        return image
    }
}

extension Color {
    /// Per-appearance tint: in dark mode, darken slightly so the chosen
    /// colour reads as a "deeper" version of itself, matching the brief.
    func adjustedForAppearance(_ scheme: ColorScheme) -> Color {
        guard scheme == .dark else { return self }
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 1
        ns.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        // Push brightness down ~20 % and saturation up a touch so the
        // colour stays vivid but reads "darker".
        v = max(0, v - 0.20)
        s = min(1, s + 0.10)
        return Color(NSColor(hue: h, saturation: s, brightness: v, alpha: a))
    }
}
