/*
 * main.swift — Space Rabbit entry point
 *
 * This is the application entry point. It:
 *   1. Checks for Accessibility permissions (required for the event tap)
 *   2. Loads the user's space-switch keyboard shortcuts
 *   3. Creates the menu bar UI
 *   4. Installs the CGEvent tap for instant space switching
 *   5. Registers the app-activation observer for auto-follow
 *   6. Schedules periodic persistence and runs the main event loop
 *
 * Space Rabbit runs as an "accessory" app (no Dock icon, no app menu),
 * living entirely in the menu bar.
 */

import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - Application Setup

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: - Accessibility Permission Check
//
// The CGEvent tap requires Accessibility access. Without it, the tap
// cannot be created and the app is useless. We prompt once and exit
// if permission is not granted.

let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
guard AXIsProcessTrustedWithOptions(axOpts as CFDictionary) else {
    fputs("Space Rabbit: accessibility permission required\n", stderr)
    fputs("  Grant in: System Settings → Privacy & Security → Accessibility\n", stderr)
    exit(1)
}

// MARK: - Initialization

// Load the user's configured space-switch keyboard shortcuts from system preferences
loadSpaceSwitchShortcuts()

// Create the menu bar status item and load persisted preferences
gMenu = SwoopMenu()

// Check for updates 5 seconds after launch (gives the app time to settle)
DispatchQueue.main.asyncAfter(deadline: .now() + 5) { checkForUpdates() }

// Persist the switch count to disk every 5 minutes (reduces disk I/O
// compared to writing on every switch)
Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
    flushSwitchCount()
}

// MARK: - Event Tap Installation
//
// The event tap intercepts keyDown events at the session level.
// When a space-switch shortcut is detected, the original event is
// swallowed and replaced with a synthetic DockSwipe gesture.

let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

gTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: eventMask,
    callback: eventTapCallback,
    userInfo: nil
)

guard let tap = gTap else {
    fputs("Space Rabbit: failed to create event tap\n", stderr)
    exit(1)
}

guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
    fputs("Space Rabbit: failed to create run loop source\n", stderr)
    exit(1)
}

CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// MARK: - App Activation Observer (Auto-Follow)
//
// Listens for app-activation events (Cmd+Tab, Dock click, etc.)
// and switches to the activated app's space if it's not already visible.

let observer = SwoopObserver()
NSWorkspace.shared.notificationCenter.addObserver(
    observer,
    selector: #selector(SwoopObserver.appActivated(_:)),
    name: NSWorkspace.didActivateApplicationNotification,
    object: nil
)

// Also stamp the switch time on any space change (covers trackpad swipes,
// which bypass the event tap entirely). This notification arrives before
// the app activation notification, so the auto-follow guard fires correctly.
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil, queue: .main
) { _ in gLastSpaceSwitchTime = Date() }

// MARK: - Cleanup on Exit
//
// Flush stats to disk and tear down the event tap when the app terminates.

NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil, queue: .main
) { _ in
    flushSwitchCount()
    NSWorkspace.shared.notificationCenter.removeObserver(observer)
    CGEvent.tapEnable(tap: tap, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
}

// MARK: - Signal Handling
//
// Gracefully terminate on SIGINT/SIGTERM so the cleanup handler runs.

/// Signal handler — must be a global C-compatible function.
func onSignal(_ sig: Int32) {
    DispatchQueue.main.async { NSApp.terminate(nil) }
}

signal(SIGINT,  onSignal)
signal(SIGTERM, onSignal)

// MARK: - Run

print("Space Rabbit: running")
app.run()
