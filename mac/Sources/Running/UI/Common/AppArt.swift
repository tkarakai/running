import AppKit
import SwiftUI

/// The app's artwork, drawn in code: the menu bar glyph at runtime, and the app icon, which the
/// build renders into AppIcon.icns (`Running --render-icon <dir>`).
enum AppArt {
    // ── menu bar ──────────────────────────────────────────────────────────
    /// Three process rows, the first one live: a dot and a bar. A template image, so it follows
    /// the menu bar's appearance (and tint).
    /// With a count, it sits in a badge on the glyph's bottom-right corner, cut out of the glyph,
    /// so the item stays about as narrow as the glyph alone.
    static func menuBarImage(count: Int?) -> NSImage {
        let label = count.map { $0 > 999 ? "999+" : "\($0)" } as NSString?
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        let textSize = label?.size(withAttributes: [.font: font]) ?? .zero
        let badgeH: CGFloat = 10.5
        let badgeW = max(badgeH, ceil(textSize.width) + 4)
        let width: CGFloat = label == nil ? 18 : max(18, 11 + badgeW)
        let img = NSImage(size: NSSize(width: width, height: 16), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.set()
            let rows: [(y: CGFloat, w: CGFloat, dot: Bool)] = [(2.5, 9.5, true), (7, 7.5, true), (11.5, 5, false)]
            for r in rows {
                let dot = NSBezierPath(ovalIn: NSRect(x: 1.5, y: r.y, width: 3, height: 3))
                if r.dot { dot.fill() } else { dot.lineWidth = 1; NSBezierPath(ovalIn: NSRect(x: 2, y: r.y + 0.5, width: 2, height: 2)).stroke() }
                NSBezierPath(roundedRect: NSRect(x: 6.5, y: r.y + 0.25, width: r.w, height: 2.5), xRadius: 1.25, yRadius: 1.25).fill()
            }
            if let label {
                let badge = NSRect(x: width - badgeW, y: 16 - badgeH, width: badgeW, height: badgeH)
                ctx.setBlendMode(.clear) // a gap around the badge
                NSBezierPath(roundedRect: badge.insetBy(dx: -1.5, dy: -1.5), xRadius: badgeH / 2 + 1.5, yRadius: badgeH / 2 + 1.5).fill()
                ctx.setBlendMode(.normal)
                NSBezierPath(roundedRect: badge, xRadius: badgeH / 2, yRadius: badgeH / 2).fill()
                ctx.setBlendMode(.clear) // the digits are see-through
                label.draw(at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2), withAttributes: [.font: font, .foregroundColor: NSColor.black])
                ctx.setBlendMode(.normal)
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    // ── app icon ──────────────────────────────────────────────────────────
    struct IconView: View {
        var body: some View {
            GeometryReader { g in
                let s = g.size.width / 1024
                ZStack {
                    // The macOS icon grid: an 824-pt continuous-corner square, centered.
                    let shape = RoundedRectangle(cornerRadius: 185 * s, style: .continuous)
                    shape
                        .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.30), Color(red: 0.05, green: 0.06, blue: 0.12)], startPoint: .top, endPoint: .bottom))
                        .overlay(
                            shape.fill(RadialGradient(colors: [Color(red: 0.35, green: 0.45, blue: 1.0).opacity(0.45), .clear], center: UnitPoint(x: 0.3, y: 0.15), startRadius: 0, endRadius: 620 * s))
                        )
                        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 5 * s))
                        .frame(width: 824 * s, height: 824 * s)
                        .shadow(color: .black.opacity(0.35), radius: 14 * s, y: 10 * s)

                    VStack(alignment: .leading, spacing: 74 * s) {
                        row(s, dot: Color(red: 0.24, green: 0.92, blue: 0.55), glow: true, width: 400, opacity: 0.95)
                        row(s, dot: Color(red: 0.24, green: 0.92, blue: 0.55), glow: true, width: 310, opacity: 0.72)
                        row(s, dot: nil, glow: false, width: 210, opacity: 0.38)
                    }
                    .offset(x: -6 * s, y: 4 * s)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }

        func row(_ s: CGFloat, dot: Color?, glow: Bool, width: CGFloat, opacity: Double) -> some View {
            HStack(spacing: 46 * s) {
                ZStack {
                    if let dot {
                        Circle().fill(dot).frame(width: 74 * s, height: 74 * s)
                            .shadow(color: dot.opacity(glow ? 0.9 : 0), radius: 26 * s)
                        Circle().fill(.white.opacity(0.55)).frame(width: 22 * s, height: 22 * s).offset(x: -12 * s, y: -12 * s).blur(radius: 6 * s)
                    } else {
                        Circle().strokeBorder(.white.opacity(0.4), lineWidth: 12 * s).frame(width: 74 * s, height: 74 * s)
                    }
                }
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(opacity), .white.opacity(opacity * 0.78)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * s, height: 60 * s)
            }
        }
    }

    /// Write AppIcon.iconset/*.png (then `iconutil -c icns`).
    @MainActor
    static func renderIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            let r = ImageRenderer(content: IconView().frame(width: CGFloat(px), height: CGFloat(px)))
            r.scale = 1
            guard let cg = r.cgImage else { throw NSError(domain: "icon", code: 1) }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "icon", code: 2) }
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
