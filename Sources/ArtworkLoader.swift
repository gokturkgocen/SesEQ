import AppKit
import SwiftUI

/// Loads album-art image data and extracts a vibrant accent color from it — the
/// Apple-Music move where the whole UI tints to the artwork. Data download is off
/// the main actor (Data is Sendable); NSImage construction + color extraction run
/// on the main actor where AppKit imaging is happy.
enum ArtworkLoader {
    static func loadData(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        return try? await URLSession.shared.data(for: req).0
    }

    /// Extracts a vibrant, legible accent: scans a downscaled copy and picks the most
    /// saturated-yet-bright color; falls back to the average if the art is muted.
    @MainActor
    static func vibrantColor(from image: NSImage) -> Color? {
        guard let tiff = image.tiffRepresentation, let src = NSBitmapImageRep(data: tiff) else { return nil }
        let n = 28
        guard let small = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4 * n, bitsPerPixel: 32) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
        src.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()

        var bestScore: CGFloat = -1
        var bestColor: NSColor?
        var aR: CGFloat = 0, aG: CGFloat = 0, aB: CGFloat = 0, cnt: CGFloat = 0
        for y in 0..<n {
            for x in 0..<n {
                guard let c = small.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                aR += r; aG += g; aB += b; cnt += 1
                let mx = max(r, g, b), mn = min(r, g, b)
                let sat = mx > 0 ? (mx - mn) / mx : 0
                // Vibrancy score: saturated and bright, but not blown out.
                let score = sat * mx * (1 - abs(mx - 0.65))
                if score > bestScore { bestScore = score; bestColor = c }
            }
        }
        if bestScore > 0.08, let bc = bestColor {
            // Nudge toward a punchy, legible accent.
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
            bc.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
            let punchy = NSColor(hue: hue, saturation: min(1, sat * 1.15 + 0.1),
                                 brightness: min(1, max(bri, 0.62)), alpha: 1)
            return Color(nsColor: punchy)
        }
        if cnt > 0 { return Color(.sRGB, red: Double(aR / cnt), green: Double(aG / cnt), blue: Double(aB / cnt)) }
        return nil
    }
}
