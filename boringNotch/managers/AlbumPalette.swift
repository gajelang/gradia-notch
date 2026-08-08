//
//  AlbumPalette.swift
//  Gradia
//
//  Pulls a small set of dominant colours out of album art and tones them down
//  until white text is guaranteed to stay readable on top.
//
//  The guarantee is arithmetic, not eyeballed. WCAG contrast against white is
//  (1.0 + 0.05) / (L + 0.05); for the 4.5:1 body-text threshold that means the
//  background's relative luminance must not exceed 0.183. Every colour here is
//  scaled until it satisfies that, so a bright yellow sleeve darkens into a
//  deep gold rather than washing the text out.
//

import AppKit
import SwiftUI

struct AlbumPalette: Equatable {
    /// Three dominant hues, darkened to stay behind white text.
    var base: Color
    var mid: Color
    var accent: Color
    /// A brighter version of the dominant hue, for secondary text that should
    /// read as tinted rather than grey.
    var highlight: Color

    static let neutral = AlbumPalette(
        base: Color(white: 0.06),
        mid: Color(white: 0.10),
        accent: Color(white: 0.14),
        highlight: Color(white: 0.72)
    )
}

enum PaletteExtractor {
    /// Luminance ceiling that keeps white body text at 4.5:1.
    static let maximumBackgroundLuminance: Double = 0.18
    /// Floor for secondary text so it reads as colour, not mud.
    static let minimumHighlightLuminance: Double = 0.45

    static func palette(from image: NSImage, completion: @escaping (AlbumPalette) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = extract(from: image) ?? .neutral
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func extract(from image: NSImage) -> AlbumPalette? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        // 32×32 is plenty: we want the broad strokes of the sleeve, and this
        // keeps the whole pass well under a millisecond.
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Bucket by hue, weighting by saturation so a mostly-grey sleeve doesn't
        // drown out the one colour that actually identifies it.
        let bucketCount = 12
        var weights = [Double](repeating: 0, count: bucketCount)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: bucketCount)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }

            let color = NSColor(red: r, green: g, blue: b, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, a: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &a)

            // Near-black and near-white pixels carry no hue information.
            guard brightness > 0.08, brightness < 0.97 else { continue }

            let bucket = min(bucketCount - 1, Int(hue * CGFloat(bucketCount)))
            let weight = Double(saturation) * Double(saturation) + 0.05
            weights[bucket] += weight
            sums[bucket].r += r * weight
            sums[bucket].g += g * weight
            sums[bucket].b += b * weight
        }

        let ranked = weights.enumerated()
            .filter { $0.element > 0 }
            .sorted { $0.element > $1.element }
            .map(\.offset)

        guard let first = ranked.first else { return nil }

        func mean(_ bucket: Int) -> (Double, Double, Double) {
            let w = weights[bucket]
            guard w > 0 else { return (0.1, 0.1, 0.1) }
            return (sums[bucket].r / w, sums[bucket].g / w, sums[bucket].b / w)
        }

        let dominant = mean(first)
        let second = ranked.count > 1 ? mean(ranked[1]) : dominant
        let third = ranked.count > 2 ? mean(ranked[2]) : second

        return AlbumPalette(
            base: color(dominant, cappedAt: maximumBackgroundLuminance * 0.55),
            mid: color(second, cappedAt: maximumBackgroundLuminance * 0.85),
            accent: color(third, cappedAt: maximumBackgroundLuminance),
            highlight: brightened(dominant, toAtLeast: minimumHighlightLuminance)
        )
    }

    // MARK: - Luminance shaping

    /// sRGB relative luminance, per WCAG. Needs the gamma expansion — the naive
    /// weighted-average-of-channels version is wrong by enough to matter here.
    static func relativeLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Scales a colour toward black until it sits at or below `cap`, keeping
    /// its hue. Binary search because luminance is non-linear in the scale.
    private static func color(_ rgb: (Double, Double, Double), cappedAt cap: Double) -> Color {
        let (r, g, b) = rgb
        guard relativeLuminance(r, g, b) > cap else {
            return Color(red: r, green: g, blue: b)
        }

        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if relativeLuminance(r * mid, g * mid, b * mid) > cap {
                high = mid
            } else {
                low = mid
            }
        }
        return Color(red: r * low, green: g * low, blue: b * low)
    }

    /// Lifts a colour until it is bright enough to read against the darkened
    /// background, without letting it blow out to white.
    private static func brightened(_ rgb: (Double, Double, Double), toAtLeast target: Double) -> Color {
        var (r, g, b) = rgb
        let nsColor = NSColor(red: r, green: g, blue: b, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, a: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &a)

        // Cap saturation so the lift doesn't produce a neon that vibrates
        // against the background.
        let toned = NSColor(hue: hue, saturation: min(saturation, 0.55), brightness: 1, alpha: 1)
        r = Double(toned.redComponent); g = Double(toned.greenComponent); b = Double(toned.blueComponent)

        guard relativeLuminance(r, g, b) < target else {
            return Color(red: r, green: g, blue: b)
        }
        // Already at full brightness for this hue — mix toward white instead.
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let mr = r + (1 - r) * mid
            let mg = g + (1 - g) * mid
            let mb = b + (1 - b) * mid
            if relativeLuminance(mr, mg, mb) < target { low = mid } else { high = mid }
        }
        return Color(red: r + (1 - r) * high,
                     green: g + (1 - g) * high,
                     blue: b + (1 - b) * high)
    }
}
