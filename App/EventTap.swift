/*
 * EventTap.swift — Feature 1: Instant space switch via event tap
 *
 * Installs a CGEvent tap at the session level to intercept keyDown
 * events that match the user's "Move left/right a space" shortcut.
 *
 * When the shortcut is detected:
 *   1. The original key event is swallowed (returns nil to the tap)
 *   2. A synthetic DockSwipe gesture pair is posted (see SpaceSwitching.swift)
 *   3. The Dock handles the gesture and switches spaces instantly
 *
 * The tap also re-enables itself if macOS disables it due to timeout
 * or user input (a safety measure built into CGEvent taps).
 */

import CoreGraphics
import Foundation

// MARK: - Event Tap Callback
//
// This is a C-compatible global function used as the CGEvent tap callback.
// It cannot be a method or closure — the CGEvent API requires a plain
// function pointer.

/// CGEvent tap callback that intercepts space-switch keyboard shortcuts.
///
/// Called for every keyDown event system-wide (requires Accessibility permission).
/// Returns `nil` to swallow the event (preventing the default animated switch),
/// or `Unmanaged.passUnretained(event)` to let it through unchanged.
func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                      event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // macOS may disable our tap if it takes too long or misbehaves.
    // Re-enable it immediately to stay alive.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    // Only process keyDown events when both the master switch and
    // instant-switch feature are enabled
    guard type == .keyDown, gEnabled, gInstantSwitchEnabled else {
        return Unmanaged.passUnretained(event)
    }

    let flags   = event.flags
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)

    // Check that exactly the required modifiers are held (no extras).
    // This prevents false positives when e.g. Cmd+Control+Arrow is pressed
    // but we only want Control+Arrow.
    let relevantMods: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
    guard flags.intersection(relevantMods) == gModMask else {
        return Unmanaged.passUnretained(event)
    }

    // Determine switch direction from keycode
    let direction: Int
    if      keycode == gKeyLeft  { direction = -1 }
    else if keycode == gKeyRight { direction = +1 }
    else                         { return Unmanaged.passUnretained(event) }

    // Bounds check: don't switch past the first or last space.
    // If we can't determine the layout, proceed anyway (the gesture
    // will harmlessly no-op if there's nowhere to go).
    let (spaceIDs, currentIdx) = getSpaceList()
    if currentIdx >= 0 {
        let targetIdx = currentIdx + direction
        guard targetIdx >= 0, targetIdx < spaceIDs.count else { return nil }
    }

    // Post the synthetic gesture and record the switch
    if postSwitchGesture(direction: direction) {
        gLastSpaceSwitchTime = Date()
        gMenu?.recordSwitch()
    }

    // Return nil to swallow the original key event (prevents the animated switch)
    return nil
}
