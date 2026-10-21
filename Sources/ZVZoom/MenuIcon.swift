import AppKit

/// Menubar glyphs, drawn in code as template images (alpha only; the system tints them).
/// Geometry is in a 22 x 18 point box with y down, matching the SVG mockups.
enum MenuIcon {
    static let size = NSSize(width: 22, height: 18)

    /// Filled compact camera with a windscreen on top: camera connected.
    static let connected: NSImage = filled(lensRadius: 4.7)

    /// Frames for the "adjusting zoom" animation: the lens breathes in and out,
    /// which reads as the barrel zooming.
    static let workingFrameCount = 8
    static let working: [NSImage] = (0..<workingFrameCount).map { i in
        let t = Double(i) / Double(workingFrameCount)           // 0 ..< 1
        let r = 4.7 - 1.3 * (1 - cos(2 * .pi * t)) / 2           // 4.7 -> 3.4 -> 4.7
        return filled(lensRadius: r)
    }

    private static func filled(lensRadius: Double) -> NSImage {
        make { _ in
            NSColor.black.setFill()

            // windscreen
            NSBezierPath(roundedRect: NSRect(x: 7, y: 0.5, width: 9, height: 4.5), xRadius: 2.25, yRadius: 2.25).fill()

            // body with the lens cut out
            let body = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 4.5, width: 21, height: 13), xRadius: 2, yRadius: 2)
            body.appendOval(in: NSRect(x: 13 - lensRadius, y: 11 - lensRadius, width: 2 * lensRadius, height: 2 * lensRadius))
            body.windingRule = .evenOdd
            body.fill()

            // lens element, kept in proportion to the ring
            let e = lensRadius * (2.6 / 4.7)
            NSBezierPath(ovalIn: NSRect(x: 13 - e, y: 11 - e, width: 2 * e, height: 2 * e)).fill()

            // tally / AF lamp on the grip side
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 6.5, width: 3, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
        }
    }

    /// Outline version: no camera connected.
    static let disconnected: NSImage = make { _ in
        NSColor.black.setFill()
        NSColor.black.setStroke()

        NSBezierPath(roundedRect: NSRect(x: 7.75, y: 1.25, width: 7.5, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let body = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 5.25, width: 19.5, height: 11.5), xRadius: 2, yRadius: 2)
        body.lineWidth = 1.5
        body.lineJoinStyle = .round
        body.stroke()

        let ring = NSBezierPath(ovalIn: NSRect(x: 13 - 3.9, y: 11 - 3.9, width: 7.8, height: 7.8))
        ring.lineWidth = 1.5
        ring.stroke()

        NSBezierPath(ovalIn: NSRect(x: 13 - 1.4, y: 11 - 1.4, width: 2.8, height: 2.8)).fill()
        NSBezierPath(roundedRect: NSRect(x: 3.2, y: 7.2, width: 2.6, height: 1), xRadius: 0.5, yRadius: 0.5).fill()
    }

    private static func make(_ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}
