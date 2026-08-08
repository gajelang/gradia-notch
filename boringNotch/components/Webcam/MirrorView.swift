//
//  MirrorView.swift
//  Gradia
//
//  Full-size mirror tab.
//
//  The inline mirror on the home tab is locked to 1:1 — it sets both the frame
//  height and `.aspectRatio(1, …)` from the width — which crops a 16:9 webcam
//  down the sides. Here the preview keeps the camera's real aspect ratio and
//  fills the panel instead.
//

import AVFoundation
import Defaults
import SwiftUI

struct MirrorView: View {
    @ObservedObject private var webcamManager = WebcamManager.shared
    @EnvironmentObject var vm: BoringViewModel

    @Default(.mirrorShape) private var mirrorShape

    /// Falls back to 16:9 until the device reports its own dimensions, which is
    /// what practically every built-in and USB webcam uses anyway.
    @State private var aspect: CGFloat = 16.0 / 9.0

    var body: some View {
        ZStack {
            if webcamManager.isSessionRunning, let layer = webcamManager.previewLayer {
                CameraPreviewLayerView(previewLayer: layer)
                    // Front cameras aren't mirrored in the raw feed; flipping
                    // makes it behave like an actual mirror.
                    .scaleEffect(x: -1, y: 1)
                    .aspectRatio(mirrorShape == .circle ? 1 : aspect, contentMode: .fit)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.06), lineWidth: 1))
                    .transition(.opacity)
            } else {
                idleState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.25), value: webcamManager.isSessionRunning)
        .onAppear { start() }
        .onDisappear {
            // The camera light staying on after leaving the tab would be alarming.
            webcamManager.stopSession()
        }
    }

    /// Type-erased: a `@ViewBuilder` conditional yields `_ConditionalContent`,
    /// which is not a `Shape`, so it can't be used for clipping.
    private var shape: AnyShape {
        mirrorShape == .circle
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 14))
    }

    private var idleState: some View {
        VStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 26))
                .foregroundStyle(.gray)
            Text(statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(.gray)

            if webcamManager.authorizationStatus == .denied
                || webcamManager.authorizationStatus == .restricted {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusIcon: String {
        switch webcamManager.authorizationStatus {
        case .denied, .restricted: return "exclamationmark.triangle"
        default: return webcamManager.cameraAvailable ? "web.camera" : "video.slash"
        }
    }

    private var statusMessage: String {
        switch webcamManager.authorizationStatus {
        case .denied, .restricted: return "Camera access denied"
        default:
            if !webcamManager.cameraAvailable { return "No camera connected" }
            return "Starting camera…"
        }
    }

    private func start() {
        switch webcamManager.authorizationStatus {
        case .authorized:
            if webcamManager.cameraAvailable { webcamManager.startSession() }
        case .notDetermined:
            webcamManager.checkAndRequestVideoAuthorization()
            // The authorization callback flips `cameraAvailable`; give it a
            // moment, then start if we were granted access.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if webcamManager.authorizationStatus == .authorized,
                   webcamManager.cameraAvailable {
                    webcamManager.startSession()
                }
            }
        default:
            break
        }
    }
}
