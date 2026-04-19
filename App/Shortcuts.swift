/*
 * Shortcuts.swift — System keyboard shortcut reading
 *
 * macOS stores the user's configured keyboard shortcuts for
 * "Move left/right a space" in the com.apple.symbolichotkeys
 * preference domain. The hotkey IDs are:
 *
 *   79 = Move left a space
 *   81 = Move right a space
 *
 * We read these at startup so the event tap knows which key
 * combination to intercept. If the shortcuts are disabled or
 * unreadable, we fall back to Control + Arrow Keys.
 */

import CoreGraphics
import CoreFoundation
import Foundation

// MARK: - Carbon-to-CoreGraphics Flag Conversion

/// Converts Carbon-era modifier flags (as stored in symbolic hotkeys)
/// to their CoreGraphics equivalents.
///
/// Carbon modifier bit layout:
///   - 0x020000 = Shift
///   - 0x040000 = Control
///   - 0x080000 = Option (Alternate)
///   - 0x100000 = Command
private func carbonToCGFlags(_ carbon: Int64) -> CGEventFlags {
    var flags = CGEventFlags()
    if carbon & 0x040000 != 0 { flags.insert(.maskControl)   }
    if carbon & 0x020000 != 0 { flags.insert(.maskShift)     }
    if carbon & 0x080000 != 0 { flags.insert(.maskAlternate) }
    if carbon & 0x100000 != 0 { flags.insert(.maskCommand)   }
    return flags
}

// MARK: - Hotkey Parsing

/// Reads a single hotkey entry from the symbolic hotkeys dictionary.
///
/// Each entry is structured as:
/// ```
/// "79" = {
///     enabled = 1;
///     value = {
///         parameters = (65535, 123, 8650752);
///         type = "standard";
///     };
/// };
/// ```
///
/// Where `parameters[1]` is the virtual keycode and `parameters[2]`
/// is the Carbon modifier flags. A keycode of 65535 means "not set"
/// (the user cleared the shortcut).
private func readHotkey(from hotkeys: NSDictionary, key: String,
                        keycode: inout Int64, mods: inout CGEventFlags) {
    guard let entry = hotkeys[key] as? NSDictionary else { return }

    // Check if the hotkey is enabled (skip disabled entries)
    if let enabled = entry["enabled"] {
        if let b = enabled as? Bool,                     !b      { return }
        if let n = (enabled as? NSNumber)?.intValue, n == 0     { return }
    }

    guard let value  = entry["value"]      as? NSDictionary,
          let params = value["parameters"] as? NSArray,
          params.count >= 3 else { return }

    let newKeycode = (params[1] as? NSNumber)?.int64Value ?? 0
    let newMods    = (params[2] as? NSNumber)?.int64Value ?? 0

    // 65535 means the keycode slot is empty — keep the default
    if newKeycode != 65535 { keycode = newKeycode }
    // 0 means no modifiers set — keep the default
    if newMods    != 0     { mods    = carbonToCGFlags(newMods) }
}

// MARK: - Public Interface

/// Reads the user's configured "Move left/right a space" shortcuts
/// from macOS system preferences and updates the global state
/// (gKeyLeft, gKeyRight, gModMask).
///
/// Falls back to the defaults (Control + Arrow Keys) if the preferences
/// cannot be read or the hotkeys are disabled.
func loadSpaceSwitchShortcuts() {
    guard let prefs = CFPreferencesCopyAppValue(
        "AppleSymbolicHotKeys" as CFString,
        "com.apple.symbolichotkeys" as CFString
    ) as? NSDictionary else { return }

    var leftMods  = CGEventFlags()
    var rightMods = CGEventFlags()

    // Hotkey 79 = "Move left a space", Hotkey 81 = "Move right a space"
    readHotkey(from: prefs, key: "79", keycode: &gKeyLeft,  mods: &leftMods)
    readHotkey(from: prefs, key: "81", keycode: &gKeyRight, mods: &rightMods)

    // Use whichever modifier set is non-empty (they should be the same,
    // but if only one side is configured, prefer that one)
    if      !leftMods.isEmpty  { gModMask = leftMods  }
    else if !rightMods.isEmpty { gModMask = rightMods }
}
