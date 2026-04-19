/*
 * State.swift — Global runtime state
 *
 * All mutable runtime state lives here as module-level globals.
 * This is intentional: the app is a single-process menu bar utility
 * with no concurrency beyond the main thread, so global state is
 * simpler and more appropriate than a singleton class.
 *
 * Persisted values are backed by UserDefaults under the "spacerabbit." prefix.
 */

import CoreGraphics
import Foundation

// MARK: - Runtime State

/// The active CGEvent tap (installed at startup, never replaced).
var gTap: CFMachPort?

/// Master on/off toggle. When false, both instant-switch and auto-follow are disabled.
var gEnabled: Bool = true

/// Feature 1 toggle: intercept space-switch hotkeys and post instant gestures.
var gInstantSwitchEnabled: Bool = true

/// Feature 2 toggle: follow activated apps to their space on Cmd+Tab.
var gAutoFollowEnabled: Bool = true

/// Whether to play a sound effect when toggling the master switch.
var gSoundsEnabled: Bool = false

/// Timestamp of the last space switch triggered by instant-switch.
/// Used to suppress auto-follow immediately after an instant-switch,
/// preventing the two features from fighting each other.
var gLastSpaceSwitchTime: Date = .distantPast

/// Lifetime count of space switches performed by Space Rabbit.
var gSwitchCount: Int = 0

/// The last value of gSwitchCount that was written to disk.
/// Compared against gSwitchCount to avoid unnecessary writes.
var gSwitchCountSaved: Int = 0

// MARK: - Keyboard Shortcut State
//
// These hold the user's configured "Move left/right a space" shortcuts,
// loaded from macOS system preferences at startup (see Shortcuts.swift).

/// Virtual keycode for "move left a space" (default: 123 = left arrow).
var gKeyLeft: Int64 = 123

/// Virtual keycode for "move right a space" (default: 124 = right arrow).
var gKeyRight: Int64 = 124

/// Required modifier flags for the space-switch shortcut (default: Control).
var gModMask: CGEventFlags = .maskControl

// MARK: - UI References

/// The menu bar status item instance (created at startup).
var gMenu: SwoopMenu?

// MARK: - UserDefaults Keys

/// Centralizes all UserDefaults key strings to avoid typos and make
/// them discoverable in one place. All keys use the "spacerabbit." prefix.
enum Defaults {
    static let enabled       = "spacerabbit.enabled"
    static let instantSwitch = "spacerabbit.instantSwitch"
    static let autoFollow    = "spacerabbit.autoFollow"
    static let sounds        = "spacerabbit.sounds"
    static let switchCount   = "spacerabbit.switchCount"
}

// MARK: - Persistence

/// Writes the current switch count to UserDefaults if it has changed.
/// Called periodically (every 5 minutes) and on app termination to
/// avoid excessive disk I/O on every single switch.
func flushSwitchCount() {
    guard gSwitchCount != gSwitchCountSaved else { return }
    UserDefaults.standard.set(gSwitchCount, forKey: Defaults.switchCount)
    gSwitchCountSaved = gSwitchCount
}
