//
//  NotchAmbientBackground.swift
//  Gradia
//
//  Album-art gradient that fills the opened notch. Layered blooms rather than
//  one flat gradient, so the light reads as coming *from* the artwork.
//

import Defaults
import SwiftUI

struct NotchAmbientBackground: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @EnvironmentObject var vm: BoringViewModel

    @Default(.albumAmbientBackground) private var enabled

    /// Drives a slow drift so the light never sits perfectly still. Deliberately
    /// not tied to tempo — beat detection would need an audio tap, and a fake
    /// pulse that drifts out of time looks worse than none.
    @State private var phase: CGFloat = 0

    private var palette: AlbumPalette { musicManager.palette }

    var body: some View {
        ZStack {
            // Real AppKit vibrancy rather than a flat fill, so the panel picks
            // up whatever is behind it the way system surfaces do.
            VisualEffectBackground(material: .hudWindow, blending: .behindWindow)

            // Under the glass, not instead of it: without a dark floor the
            // white text loses its contrast guarantee over a bright wallpaper,
            // and on a notched Mac the closed panel would show the desktop
            // through what is meant to read as the hardware cutout.
            Color.black.opacity(vm.notchState == .open ? 0.55 : 0.92)

            if enabled && vm.notchState == .open {
                gradient
                    .opacity(0.9)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: vm.notchState)
        .animation(.easeInOut(duration: 0.8), value: palette)
    }

    private var gradient: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let drift = sin(phase) * 0.04

            ZStack {
                palette.base

                // Main bloom, anchored where the album art sits.
                bloom(palette.accent, opacity: 0.95)
                    .frame(width: w * 1.1, height: h * 2.2)
                    .position(x: w * (0.17 + drift), y: h * 0.30)

                // Counterweight on the right so the panel doesn't fall off
                // into flat darkness.
                bloom(palette.mid, opacity: 0.8)
                    .frame(width: w * 0.95, height: h * 1.9)
                    .position(x: w * (0.86 - drift), y: h * (0.72 + drift))

                // Cool wash across the top edge, mirroring how the reference
                // keeps its brightest band up near the header.
                LinearGradient(
                    colors: [palette.mid.opacity(0.55), .clear],
                    startPoint: .top, endPoint: .center
                )

                // Weight the bottom so controls always sit on something dark.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.45)],
                    startPoint: .center, endPoint: .bottom
                )
            }
            .compositingGroup()
            // Softens the seams between blooms into one continuous field.
            .blur(radius: 26)
            .scaleEffect(1.25)  // hides the blur's transparent edges
        }
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                phase = .pi
            }
        }
    }

    private func bloom(_ color: Color, opacity: Double) -> some View {
        RadialGradient(
            colors: [color.opacity(opacity), color.opacity(opacity * 0.35), .clear],
            center: .center,
            startRadius: 0,
            endRadius: 150
        )
    }
}


/// Thin wrapper over `NSVisualEffectView` — SwiftUI's `.ultraThinMaterial` and
/// friends only blur what is inside the same window, which for a transparent
/// overlay panel means blurring nothing at all. `.behindWindow` blending is
/// what actually samples the desktop underneath.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        // Keeps the blur live even when the panel isn't the key window, which
        // it almost never is.
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
