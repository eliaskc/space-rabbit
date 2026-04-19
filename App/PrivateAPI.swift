/*
 * PrivateAPI.swift — Undocumented CGEvent fields and private CGS functions
 *
 * macOS does not provide a public API for querying or switching Spaces
 * (virtual desktops). The constants and function pointers below are
 * resolved at runtime via dlsym and give us the ability to:
 *
 *   - Construct synthetic DockSwipe gesture events (the CGEvent field IDs)
 *   - Query the current space and enumerate all spaces per display (CGS functions)
 *   - Map window IDs to the space they belong to (SLSCopySpacesForWindows)
 *
 * These are the main fragility points of the app — they rely on
 * implementation details of macOS that may change in future releases.
 *
 * References:
 *   - https://github.com/jurplel/InstantSpaceSwitcher (original technique)
 *   - CGSInternal headers (community-maintained)
 */

import CoreGraphics
import Darwin

// MARK: - Undocumented CGEvent Field IDs
//
// These raw integer IDs identify private fields on CGEvent objects.
// They are used to construct the synthetic DockSwipe gesture events
// that trick the Dock into performing an instant (non-animated) space switch.

/// Internal event type discriminator (gesture vs. dock-control vs. normal input).
let kCGSEventTypeField            = CGEventField(rawValue: 55)!

/// Identifies the HID gesture type (e.g. DockSwipe = 23).
let kCGEventGestureHIDType        = CGEventField(rawValue: 110)!

/// Vertical scroll component of the gesture (set to 0 for horizontal swipes).
let kCGEventGestureScrollY        = CGEventField(rawValue: 119)!

/// Indicates whether the gesture involves a swipe motion (1 = yes).
let kCGEventGestureSwipeMotion    = CGEventField(rawValue: 123)!

/// How far the swipe has progressed (+-2.0 triggers an immediate switch).
let kCGEventGestureSwipeProgress  = CGEventField(rawValue: 124)!

/// Horizontal velocity of the swipe (+-400 is high enough to be "instant").
let kCGEventGestureSwipeVelocityX = CGEventField(rawValue: 129)!

/// Vertical velocity of the swipe (set to 0 for horizontal swipes).
let kCGEventGestureSwipeVelocityY = CGEventField(rawValue: 130)!

/// The phase of the gesture (began = 1, ended = 4).
let kCGEventGesturePhase          = CGEventField(rawValue: 132)!

/// Bitfield that encodes the swipe direction (0 = left, 1 = right).
let kCGEventScrollGestureFlagBits = CGEventField(rawValue: 135)!

/// Zoom/delta field repurposed to carry a non-zero epsilon value
/// (prevents the Dock from ignoring the gesture).
let kCGEventGestureZoomDeltaX     = CGEventField(rawValue: 139)!

// MARK: - Undocumented Event Type Constants

/// HID event type for a Dock swipe gesture.
let kIOHIDEventTypeDockSwipe: Int64 = 23

/// CGS event subtype: generic gesture.
let kCGSEventGesture:         Int64 = 29

/// CGS event subtype: Dock control gesture (triggers the space switch).
let kCGSEventDockControl:     Int64 = 30

/// Gesture phase: the swipe just started.
let kCGSGesturePhaseBegan:    Int64 = 1

/// Gesture phase: the swipe has ended (this is when velocity/progress matter).
let kCGSGesturePhaseEnded:    Int64 = 4

// MARK: - CGS Type Aliases

/// Opaque connection handle returned by CGSMainConnectionID.
typealias CGSConnectionID = Int32

/// 64-bit identifier for a single Space (virtual desktop).
typealias CGSSpaceID      = UInt64

// MARK: - Private CGS Function Signatures
//
// These are the C calling-convention signatures of the private functions
// we resolve at runtime. Each typedef matches the actual symbol's ABI.

/// `CGSMainConnectionID() -> CGSConnectionID`
/// Returns the connection ID for the current login session.
typealias FnMainConnection   = @convention(c) () -> CGSConnectionID

/// `CGSGetActiveSpace(cid) -> CGSSpaceID`
/// Returns the ID of the currently active space on the main display.
typealias FnActiveSpace      = @convention(c) (CGSConnectionID) -> CGSSpaceID

/// `CGSCopyManagedDisplaySpaces(cid, displayUUID?) -> CFArray?`
/// Returns an array of dictionaries describing every display and its spaces.
typealias FnDisplaySpaces    = @convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?

/// `SLSCopySpacesForWindows(cid, type, windowIDs) -> CFArray?`
/// Maps an array of window IDs to the space IDs they belong to.
typealias FnSpacesForWindows = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?

// MARK: - Runtime Symbol Resolution
//
// We load private symbols from the WindowServer framework using dlsym
// at process startup. If any symbol is missing (e.g. Apple renamed it
// in a future macOS version), the corresponding variable will be nil
// and the features that depend on it will gracefully no-op.

/// `RTLD_DEFAULT` — search all loaded images (equivalent to `(void *)-2` on macOS).
private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2 as Int)

/// Resolves a C symbol by name and casts it to the requested function type.
private func loadSym<T>(_ name: String) -> T? {
    guard let ptr = dlsym(rtldDefault, name) else { return nil }
    return unsafeBitCast(ptr, to: T.self)
}

/// Returns the CGS connection ID for the current session.
let cgsMainConnection:       FnMainConnection?   = loadSym("CGSMainConnectionID")

/// Returns the active space ID on the main display.
let cgsGetActiveSpace:       FnActiveSpace?       = loadSym("CGSGetActiveSpace")

/// Lists all displays and their associated spaces.
let cgsCopyDisplaySpaces:    FnDisplaySpaces?     = loadSym("CGSCopyManagedDisplaySpaces")

/// Maps window IDs to the spaces they live on.
let slsCopySpacesForWindows: FnSpacesForWindows?  = loadSym("SLSCopySpacesForWindows")
