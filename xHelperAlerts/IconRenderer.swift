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

        // macOS-style squircle. Pure rounded-rect is close enough at
        // dock sizes that the difference isn't visible.
        let rect = NSRect(origin: .zero, size: size)
        let cornerRadius: CGFloat = 220
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.addClip()
        tint.setFill()
        path.fill()

        if let glyph = NSImage(named: "DockGlyph") {
            // Centered with generous padding so the glyph reads at
            // small dock sizes too.
            let inset: CGFloat = 200
            let glyphRect = rect.insetBy(dx: inset, dy: inset)
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
