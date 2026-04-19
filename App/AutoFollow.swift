/*
 * AutoFollow.swift — Feature 2: Auto-follow on Cmd+Tab
 *
 * When the user activates an app (via Cmd+Tab, Dock click, etc.),
 * this observer checks whether the app's windows are on a different space.
 * If so, it switches to that space instantly, then brings the app to front.
 *
 * This makes Cmd+Tab behave as if all apps are on the current space —
 * you never see the slow sliding animation to reach a distant desktop.
 */

import AppKit

// MARK: - Constants

/// How long after an instant-switch to suppress auto-follow (in seconds).
///
/// When the user presses Control+Arrow, our event tap posts a gesture
/// that switches spaces. macOS then fires an app-activation notification
/// for whatever app lands in focus on the new space. Without this guard,
/// auto-follow would see that notification and potentially chase a second
/// window of the same app on yet another space, causing a visual glitch.
///
/// 300ms is wide enough to cover the notification delay but narrow enough
/// not to interfere with a real Cmd+Tab shortly after.
private let kAutoFollowSuppressionWindow: TimeInterval = 0.3

/// Delay after switching spaces before bringing the app's windows to front.
///
/// The space switch needs a moment to settle before the window server
/// will correctly respond to activation requests.
private let kPostSwitchActivationDelay: TimeInterval = 0.1

// MARK: - App Activation Observer

/// Watches for `NSWorkspace.didActivateApplicationNotification` and
/// auto-switches to the activated app's space when needed.
///
/// Registered in `main.swift` on the workspace notification center.
final class SwoopObserver: NSObject {

    /// Called whenever an application becomes active system-wide.
    ///
    /// - Parameter note: The notification containing the activated app info.
    @objc func appActivated(_ note: Notification) {
        guard gEnabled, gAutoFollowEnabled else { return }

        // Suppress auto-follow when instant-switch just fired
        // (see kAutoFollowSuppressionWindow documentation above)
        guard Date().timeIntervalSince(gLastSpaceSwitchTime) > kAutoFollowSuppressionWindow
        else { return }

        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }

        // Find which space the app's windows are on.
        // Returns 0 if the app is already on a visible space (no switch needed).
        let targetSpace = findSpaceForPid(app.processIdentifier)
        guard targetSpace != 0 else { return }

        // Decide whether `activate(.activateAllWindows)` is safe to call later.
        // We check NOW, before the gesture, while CGS state is fresh.
        //
        // `.activateAllWindows` tells macOS to raise every window of the app,
        // which triggers a native cross-space switch for any window on a
        // different space. If the app's windows are all on the target space,
        // this is safe. If any window is on another space, we must use `[]`
        // to stay put after switching.
        let safeToActivateAll = appWindowsConfinedToSpace(app.processIdentifier, targetSpace)

        // Switch to the target space and record it for statistics
        switchToSpace(targetSpace)
        gMenu?.recordSwitch()

        // After a short delay (to let the space switch settle),
        // bring the activated app's windows to the front
        DispatchQueue.main.asyncAfter(deadline: .now() + kPostSwitchActivationDelay) {
            let options: NSApplication.ActivationOptions = safeToActivateAll
                ? .activateAllWindows
                : []
            app.activate(options: options)
        }
    }
}
