//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }
        
        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class BoringNotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false
    
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        
        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        
        // Apply initial sharing type setting
        updateSharingType()
    }
    
    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)
    }
    
    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
    }
    
    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }
    
    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }
    
    private var observers: Set<AnyCancellable> = []
    
    // Opened only while the search field is on screen; see NotchKeyboardFocus.
    override var canBecomeKey: Bool { NotchKeyboardFocus.shared.isActive }
    override var canBecomeMain: Bool { false }
}

/// Gates keyboard focus for the notch panels.
///
/// The notch normally refuses to become key: it sits above the menu bar and
/// follows the pointer, so accepting focus would yank the caret out of whatever
/// the user is typing in. Search needs a real text field though, and the panels
/// carry `.nonactivatingPanel`, which lets them take key status *without*
/// activating the app — the same trick Spotlight uses. So focus is opened only
/// while search is on screen, and closed again the moment it leaves.
@MainActor
final class NotchKeyboardFocus {
    static let shared = NotchKeyboardFocus()
    private init() {}

    private(set) var isActive = false

    /// Whoever had focus before the notch borrowed it. Taking key status makes
    /// Gradia frontmost, so anything asking "what was the user in?" after that
    /// point gets Gradia — useless for handing focus back.
    private(set) var appBeforeFocus: NSRunningApplication?

    func begin() {
        guard !isActive else { return }
        appBeforeFocus = NSWorkspace.shared.frontmostApplication
        isActive = true
        // The panels cache nothing, but AppKit needs a nudge to re-ask.
        for window in NSApp.windows where window is NSPanel {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func end() {
        guard isActive else { return }
        isActive = false

        // `resignKey()` only posts the notification — it does not relinquish
        // key status, so the panel stayed key after leaving Search and kept
        // swallowing keystrokes. Handing focus back to the app it was borrowed
        // from is what actually releases it.
        if let previous = appBeforeFocus,
           !previous.isTerminated,
           previous.bundleIdentifier != Bundle.main.bundleIdentifier {
            previous.activate()
        }
        // No `NSApp.hide` fallback: this app is LSUIElement and the notch is
        // its only window, so hiding the app would hide the notch.
        appBeforeFocus = nil
    }
}
