//
//  GestureOverlayView.swift
//  Gradia
//
//  Visual feedback for hand-gesture control. Two jobs: show the user the
//  camera can see them (otherwise waving at a Mac feels absurd), and confirm
//  loudly when a gesture lands.
//

import Defaults
import SwiftUI

struct GestureOverlayView: View {
    @ObservedObject private var gestures = GestureManager.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @EnvironmentObject var vm: BoringViewModel

    @Default(.playerColorTinting) private var colorTinting

    private var accent: Color {
        colorTinting
            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.9)
            : .white
    }

    /// Track the notch's own width so the indicator lines up with the cutout
    /// rather than the whole window.
    private var width: CGFloat {
        max(vm.closedNotchSize.width, 120)
    }

    var body: some View {
        ZStack {
            // Only meaningful over the closed notch — with the notch open the
            // user is already looking at real controls.
            if vm.notchState != .closed {
                EmptyView()
            } else if let fired = gestures.firedGesture {
                confirmation(for: fired)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if gestures.handDetected {
                tracker
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: vm.effectiveClosedNotchHeight)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: gestures.firedGesture)
        .animation(.easeInOut(duration: 0.2), value: gestures.handDetected)
    }

    // MARK: - Aiming state

    /// A dot that follows the hand, plus a ring that fills while a pose is held.
    private var tracker: some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.55))

            GeometryReader { geo in
                let inset: CGFloat = 10
                let travel = max(geo.size.width - inset * 2, 1)
                let x = inset + travel * gestures.handPosition

                ZStack {
                    if gestures.holdProgress > 0 {
                        Circle()
                            .trim(from: 0, to: gestures.holdProgress)
                            .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 16, height: 16)
                    }

                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                        .shadow(color: accent.opacity(0.9), radius: 6)
                }
                .position(x: x, y: geo.size.height / 2)
                .animation(.interpolatingSpring(stiffness: 220, damping: 22),
                           value: gestures.handPosition)
            }
            .padding(.horizontal, 2)
        }
        .clipShape(Capsule())
    }

    // MARK: - Fired state

    private func confirmation(for gesture: HandGesture) -> some View {
        ZStack {
            Capsule()
                .fill(.black)
                .overlay(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.35), .clear],
                                startPoint: gesture == .previous ? .trailing : .leading,
                                endPoint: gesture == .previous ? .leading : .trailing
                            )
                        )
                )

            HStack(spacing: 6) {
                Image(systemName: gesture.symbolName)
                    .font(.system(size: 12, weight: .bold))
                Text(gesture.label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(accent)
            .shadow(color: accent.opacity(0.7), radius: 8)
            // Track changes slide in from the direction they move; pause pops.
            .modifier(EntrySlide(gesture: gesture))
        }
        .clipShape(Capsule())
    }
}

/// Gives track-change confirmations a directional entrance so the motion reads
/// as "next" or "previous" without the user having to read the label.
private struct EntrySlide: ViewModifier, Animatable {
    let gesture: HandGesture
    @State private var arrived = false

    func body(content: Content) -> some View {
        content
            .offset(x: arrived ? 0 : offscreen)
            .opacity(arrived ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) {
                    arrived = true
                }
            }
    }

    private var offscreen: CGFloat {
        switch gesture {
        case .previous: return 40
        case .next: return -40
        case .playPause: return 0
        }
    }
}
