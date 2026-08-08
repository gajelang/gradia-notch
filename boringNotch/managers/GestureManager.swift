//
//  GestureManager.swift
//  Gradia
//
//  Hand-gesture control for playback, by finger count:
//    ☝️  index only        → next track
//    ✌️  index + middle    → previous track
//    ✊  closed fist       → play / pause
//
//  Counting fingers beats waving on every axis that matters: a pose is held
//  deliberately so it can't be triggered by reaching for the keyboard, it needs
//  no travel distance across the frame, and it sidesteps the mirrored-camera
//  question entirely — there is no left or right to get backwards.
//
//  This runs its own capture session rather than sharing WebcamManager's. The
//  mirror session only exists while the mirror is on screen, uses a `.high`
//  preset, and has no frame delegate — all wrong for a always-ready recogniser
//  that should be cheap. Here the preset is low and frames are throttled.
//

import AppKit
import AVFoundation
import Combine
import Defaults
import SwiftUI
import Vision

// MARK: - Gestures

enum HandGesture: Equatable {
    case next
    case previous
    case playPause

    var symbolName: String {
        // Shows the action rather than the pose — clearer at a glance.
        switch self {
        case .previous: return "backward.fill"
        case .next: return "forward.fill"
        case .playPause: return "playpause.fill"
        }
    }

    var label: String {
        switch self {
        case .previous: return "Previous"
        case .next: return "Next"
        case .playPause: return "Play / Pause"
        }
    }
}

/// What the hand is currently doing. Only the three named shapes act; anything
/// else — a relaxed hand, three fingers, a thumbs-up — is deliberately inert.
enum HandPose: Equatable {
    case fist
    case oneFinger
    case twoFingers
    case other

    var gesture: HandGesture? {
        switch self {
        case .oneFinger: return .next
        case .twoFingers: return .previous
        case .fist: return .playPause
        case .other: return nil
        }
    }
}

// MARK: - Manager

@MainActor
final class GestureManager: ObservableObject {
    static let shared = GestureManager()

    /// Camera is live and looking for hands.
    @Published private(set) var isRunning = false
    /// A hand is in frame right now — drives the on-screen aiming indicator.
    @Published private(set) var handDetected = false
    /// Horizontal hand position, 0…1 left-to-right *as the user sees themselves*.
    @Published private(set) var handPosition: CGFloat = 0.5
    /// How far through a fist-hold we are, 0…1. Powers the fill animation.
    @Published private(set) var holdProgress: Double = 0

    /// Set briefly when a gesture fires so the notch can flash a confirmation.
    @Published private(set) var firedGesture: HandGesture?

    /// Why the recogniser is or isn't watching. Surfaced in Settings — without
    /// it, turning the feature on and having nothing happen is unexplainable.
    enum Status: Equatable {
        case off
        case noCameraAccess
        case noCamera
        case waitingForPlayback
        case watching

        var message: String {
            switch self {
            case .off: return "Off"
            case .noCameraAccess: return "Camera access denied — allow Gradia in System Settings › Privacy & Security › Camera"
            case .noCamera: return "No camera found"
            case .waitingForPlayback: return "Idle — starts watching when music plays"
            case .watching: return "Watching for gestures"
            }
        }

        var isHealthy: Bool { self == .watching || self == .waitingForPlayback }
    }

    @Published private(set) var status: Status = .off

    private lazy var pipeline = HandCapturePipeline { [weak self] observation in
        Task { @MainActor in self?.consume(observation) }
    }

    private var cancellables = Set<AnyCancellable>()
    private var lastFiredAt: Date = .distantPast
    private var clearFiredTask: Task<Void, Never>?
    /// The pose being held, and since when. Resets the moment the hand changes
    /// shape, so a hand passing through ✌️ on its way to ✊ never fires twice.
    private var heldPose: (pose: HandPose, since: Date)?

    /// Ignore window after a gesture lands, so keeping the pose up doesn't
    /// repeat the action.
    private let cooldown: TimeInterval = 1.4
    /// How long a pose must be held before it counts. Long enough to rule out
    /// a hand merely passing through the shape, short enough not to be a chore.
    private let holdDuration: TimeInterval = 0.5

    private init() {
        // React to the feature being toggled, and to playback starting/stopping
        // when the user only wants the camera on while music runs.
        Defaults.publisher(.enableHandGestures)
            .sink { [weak self] _ in Task { @MainActor in self?.reevaluate() } }
            .store(in: &cancellables)

        Defaults.publisher(.handGesturesOnlyWhilePlaying)
            .sink { [weak self] _ in Task { @MainActor in self?.reevaluate() } }
            .store(in: &cancellables)

        MusicManager.shared.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.reevaluate() } }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    /// Starts or stops the camera to match the current settings. Cheap to call.
    func reevaluate() {
        guard Defaults[.enableHandGestures] else {
            stop()
            status = .off
            return
        }
        if Defaults[.handGesturesOnlyWhilePlaying], !MusicManager.shared.isPlaying {
            stop()
            status = .waitingForPlayback
            return
        }
        start()
    }

    func start() {
        guard !isRunning else { return }

        guard hasCamera else {
            status = .noCamera
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.beginSession()
                    } else {
                        self.status = .noCameraAccess
                    }
                }
            }
        case .denied, .restricted:
            status = .noCameraAccess
            NSLog("Gesture control: camera access denied")
        @unknown default:
            break
        }
    }

    private var hasCamera: Bool {
        !AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices.isEmpty
    }

    /// Re-prompts, or opens the right System Settings pane when the user has
    /// already said no (macOS only ever asks once).
    func requestCameraAccess() {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        guard current == .denied || current == .restricted else {
            reevaluate()
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        handDetected = false
        holdProgress = 0
        heldPose = nil
        pipeline.stop()
    }

    private func beginSession() {
        isRunning = true
        status = .watching
        pipeline.start()
    }

    // MARK: Recognition

    private func consume(_ observation: HandObservation) {
        guard isRunning else { return }

        guard let hand = observation.hand else {
            handDetected = false
            holdProgress = 0
            heldPose = nil
            return
        }

        handDetected = true
        handPosition = hand.x

        let now = Date()
        guard now.timeIntervalSince(lastFiredAt) > cooldown else {
            holdProgress = 0
            heldPose = nil
            return
        }

        guard let gesture = hand.pose.gesture else {
            // Hand is visible but not making one of the three shapes.
            holdProgress = 0
            heldPose = nil
            return
        }

        // Changing shape restarts the clock rather than carrying progress over.
        if heldPose?.pose != hand.pose {
            heldPose = (hand.pose, now)
        }

        let elapsed = now.timeIntervalSince(heldPose?.since ?? now)
        holdProgress = min(1, elapsed / holdDuration)

        if holdProgress >= 1 {
            fire(gesture)
        }
    }

    private func fire(_ gesture: HandGesture) {
        lastFiredAt = Date()
        heldPose = nil
        holdProgress = 0

        switch gesture {
        case .next: MusicManager.shared.nextTrack()
        case .previous: MusicManager.shared.previousTrack()
        case .playPause: MusicManager.shared.togglePlay()
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            firedGesture = gesture
        }
        clearFiredTask?.cancel()
        clearFiredTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self?.firedGesture = nil
            }
        }
    }
}

// MARK: - Capture pipeline

/// Owns the capture session. Deliberately *not* main-actor isolated: session
/// configuration and frame delivery both belong off the main thread, and
/// isolating them would only force hops that AVFoundation doesn't want.
private final class HandCapturePipeline {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.elangsamudra.gradia.gesture", qos: .userInitiated)
    private let processor: HandFrameProcessor

    init(onResult: @escaping (HandObservation) -> Void) {
        processor = HandFrameProcessor(onResult: onResult)
    }

    func start() {
        queue.async { [self] in
            configureIfNeeded()
            guard !session.isRunning, !session.inputs.isEmpty else { return }
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureIfNeeded() {
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Hand landmarks survive a small frame just fine, and this keeps the
        // recogniser far cheaper than the mirror's full-resolution feed.
        session.sessionPreset = .vga640x480

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discovery.devices.first,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            NSLog("Gesture control: no usable camera")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(processor, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
    }
}

// MARK: - Vision frame processing

struct HandObservation {
    struct Hand {
        /// Normalised horizontal position, for the on-screen indicator only.
        let x: CGFloat
        let pose: HandPose
    }
    let hand: Hand?
}

/// Runs Vision off the main actor and reports at a fixed cadence.
private final class HandFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let request = VNDetectHumanHandPoseRequest()
    private let onResult: (HandObservation) -> Void
    private var lastProcessed = Date.distantPast

    /// Hands don't move fast enough to need 30fps, and Vision is the expensive
    /// part of this feature.
    private let interval: TimeInterval = 1.0 / 15.0

    init(onResult: @escaping (HandObservation) -> Void) {
        self.onResult = onResult
        super.init()
        request.maximumHandCount = 1
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= interval else { return }
        lastProcessed = now

        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observation = request.results?.first else {
            onResult(HandObservation(hand: nil))
            return
        }
        onResult(HandObservation(hand: describe(observation)))
    }

    private func describe(_ observation: VNHumanHandPoseObservation) -> HandObservation.Hand? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        guard let wrist = points[.wrist], wrist.confidence > 0.4 else { return nil }

        // Middle-finger base tracks the palm's centre far more steadily than
        // the wrist, which swings a lot during a wave.
        let anchor = points[.middleMCP].flatMap { $0.confidence > 0.4 ? $0 : nil } ?? wrist

        return HandObservation.Hand(
            x: anchor.location.x,
            pose: Self.pose(points: points, wrist: wrist)
        )
    }

    /// A finger counts as extended when its tip is farther from the wrist than
    /// its middle joint. Comparing against the wrist keeps this working at any
    /// hand rotation, unlike a plain "tip is above knuckle" test.
    ///
    /// The thumb is ignored on purpose — Vision places it unreliably, and it
    /// drifts in and out of "extended" while the other fingers hold still.
    ///
    /// All four fingers must be measured confidently before any pose is
    /// reported. Without that rule, a dim room where Vision sees nothing
    /// clearly reads as zero extended fingers, i.e. a fist, and pauses the
    /// music at random.
    private static func pose(points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint],
                             wrist: VNRecognizedPoint) -> HandPose {
        let fingers: [(name: String, tip: VNHumanHandPoseObservation.JointName,
                       pip: VNHumanHandPoseObservation.JointName)] = [
            ("index", .indexTip, .indexPIP),
            ("middle", .middleTip, .middlePIP),
            ("ring", .ringTip, .ringPIP),
            ("little", .littleTip, .littlePIP),
        ]

        var extended: Set<String> = []
        var measured = 0

        for finger in fingers {
            guard let tip = points[finger.tip], tip.confidence > 0.3,
                  let pip = points[finger.pip], pip.confidence > 0.3
            else { continue }
            measured += 1
            if distance(tip, wrist) > distance(pip, wrist) * 1.15 {
                extended.insert(finger.name)
            }
        }

        guard measured == fingers.count else { return .other }

        switch extended {
        case []:                    return .fist
        case ["index"]:             return .oneFinger
        case ["index", "middle"]:   return .twoFingers
        default:                    return .other
        }
    }

    private static func distance(_ a: VNRecognizedPoint, _ b: VNRecognizedPoint) -> CGFloat {
        hypot(a.location.x - b.location.x, a.location.y - b.location.y)
    }
}
