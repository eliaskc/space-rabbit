/*
 * MenuBar.swift — Menu bar status item and dropdown menu
 *
 * Manages the rabbit icon in the macOS menu bar and its dropdown menu.
 * The menu provides:
 *   - Enable/disable toggle (also available via right-click on the icon)
 *   - Feature toggles (instant switch, auto-follow)
 *   - Usage statistics (switch count + estimated time saved)
 *   - Access to the settings window
 *   - Update availability banner
 *   - Launch-at-login warning
 */

import AppKit
import ServiceManagement

// MARK: - Time Formatting

/// Formats a number of seconds into a human-readable "time saved" string.
/// Each space switch saves roughly 1 second of animation time.
private func formatTimeSaved(_ seconds: Int) -> String {
    switch seconds {
    case ..<60:
        return "\(seconds) sec"
    case ..<3600:
        return "\(seconds / 60) min"
    case ..<86400:
        let hr = seconds / 3600; let min = (seconds % 3600) / 60
        return min > 0 ? "\(hr) hr \(min) min" : "\(hr) hr"
    default:
        let days = seconds / 86400; let hr = (seconds % 86400) / 3600
        return hr > 0 ? "\(days) days \(hr) hr" : "\(days) days"
    }
}

// MARK: - SwoopMenu

final class SwoopMenu: NSObject {

    // MARK: Menu Items

    private let statusItem:          NSStatusItem
    private let enableItem:          NSMenuItem
    private let instantSwitchItem:   NSMenuItem
    private let autoFollowItem:      NSMenuItem
    private let statsItem:           NSMenuItem

    /// Banner shown at the top of the menu when an update is available.
    private let updateAvailableItem: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateAvailableSep:  NSMenuItem = .separator()

    /// Banner shown when the app is not set to launch at login.
    private let launchWarningItem:   NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchWarningSep:    NSMenuItem = .separator()

    private var statusMenu:          NSMenu!
    private var updateDownloadURL:   String?

    // MARK: Initialization

    override init() {
        // Register default preference values (used on first launch)
        let ud = UserDefaults.standard
        ud.register(defaults: [
            Defaults.enabled:       true,
            Defaults.instantSwitch: true,
            Defaults.autoFollow:    true,
            Defaults.sounds:        false,
            Defaults.switchCount:   0,
        ])

        // Load persisted state into globals
        gEnabled              = ud.bool(forKey: Defaults.enabled)
        gInstantSwitchEnabled = ud.bool(forKey: Defaults.instantSwitch)
        gAutoFollowEnabled    = ud.bool(forKey: Defaults.autoFollow)
        gSoundsEnabled        = ud.bool(forKey: Defaults.sounds)
        gSwitchCount          = ud.integer(forKey: Defaults.switchCount)
        gSwitchCountSaved     = gSwitchCount

        // Create the status bar item (variable width to accommodate the icon)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Create the main menu items
        enableItem        = NSMenuItem(title: "Enable Space Rabbit",
                                       action: #selector(toggleEnabled(_:)),
                                       keyEquivalent: "")
        instantSwitchItem = NSMenuItem(title: "Instant space switch",
                                       action: #selector(toggleInstantSwitch(_:)),
                                       keyEquivalent: "s")
        autoFollowItem    = NSMenuItem(title: "Auto-follow on \u{2318}\u{21E5}",
                                       action: #selector(toggleAutoFollow(_:)),
                                       keyEquivalent: "f")
        statsItem         = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        super.init()

        // Configure update banner (hidden by default, shown when an update is found)
        updateAvailableItem.isHidden = true
        updateAvailableItem.target   = self
        updateAvailableItem.action   = #selector(openDownloadURL)
        updateAvailableSep.isHidden  = true

        // Configure launch warning banner
        launchWarningItem.target = self
        launchWarningItem.action = #selector(openSettingsForLaunchAtLogin)

        // Wire up menu item targets and initial states
        enableItem.target        = self
        instantSwitchItem.target = self
        instantSwitchItem.state  = gInstantSwitchEnabled ? .on : .off
        autoFollowItem.target    = self
        autoFollowItem.state     = gAutoFollowEnabled    ? .on : .off
        statsItem.isEnabled      = false

        // Assign SF Symbol icons to feature toggle items
        if let img = NSImage(systemSymbolName: "arrow.left.arrow.right",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            instantSwitchItem.image = img
        }
        if let img = NSImage(systemSymbolName: "scope",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            autoFollowItem.image = img
        }
        if let img = NSImage(systemSymbolName: "timer",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            statsItem.image = img
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

        // Assemble the menu
        statusMenu = NSMenu()
        statusMenu.addItem(updateAvailableItem)
        statusMenu.addItem(updateAvailableSep)
        statusMenu.addItem(launchWarningItem)
        statusMenu.addItem(launchWarningSep)
        statusMenu.addItem(enableItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(menuHeader("Configure:"))
        statusMenu.addItem(instantSwitchItem)
        statusMenu.addItem(autoFollowItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(menuHeader("Statistics:"))
        statusMenu.addItem(statsItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(greyLabel("Version \(version)"))

        let settings = NSMenuItem(title: "Preferences\u{2026}",
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        if let img = NSImage(systemSymbolName: "gear",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            settings.image = img
        }
        statusMenu.addItem(settings)
        statusMenu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        if let img = NSImage(systemSymbolName: "xmark.rectangle",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            quit.image = img
        }
        statusMenu.addItem(quit)

        // Handle left-click (open menu) and right-click (toggle enable) separately
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Set initial UI state
        updateMenuBarIcon()
        updateEnableItem()
        updateStatsDisplay()
        updateLaunchWarning()
    }

    // MARK: - Click Handling

    /// Dispatches left-click (open menu) vs right-click (toggle enable).
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click: quick toggle without opening the menu
            setEnabled(!gEnabled)
        } else {
            // Left-click: refresh warnings and show the dropdown menu.
            // We temporarily assign the menu, perform the click, then
            // remove it so right-click continues to work.
            updateLaunchWarning()
            statusItem.menu = statusMenu
            sender.performClick(nil)
            statusItem.menu = nil
        }
    }

    // MARK: - Menu Bar Icon

    /// Updates the menu bar icon appearance based on the enabled state.
    /// When disabled, the icon fades to 25% opacity.
    private func updateMenuBarIcon() {
        if let img = NSImage(systemSymbolName: "hare.fill",
                             accessibilityDescription: "Space Rabbit") {
            img.isTemplate = true
            statusItem.button?.image = img
        }
        statusItem.button?.alphaValue = gEnabled ? 1.0 : 0.25
    }

    /// Updates the enable/disable menu item text and icon color.
    private func updateEnableItem() {
        if gEnabled {
            enableItem.title = "Disable Space Rabbit"
            enableItem.image = tintedSymbol("xmark.circle.fill",
                                            color: NSColor(red: 0.94, green: 0.51, blue: 0.40, alpha: 1))
        } else {
            enableItem.title = "Enable Space Rabbit"
            enableItem.image = tintedSymbol("checkmark.circle.fill",
                                            color: NSColor(red: 0.19, green: 0.77, blue: 0.55, alpha: 1))
        }
    }

    /// Creates a two-tone SF Symbol image (inner color + background color)
    /// suitable for use as a menu item icon.
    private func tintedSymbol(_ name: String, color: NSColor, size: CGFloat = 16) -> NSImage? {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let innerColor: NSColor = isDark ? .black : .white

        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [innerColor, color]))

        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }

        // Render the symbol into a fixed-size canvas to avoid layout jitter
        let canvas = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        canvas.isTemplate = false
        return canvas
    }

    // MARK: - Menu Label Helpers

    /// Creates a small, grey section header for the dropdown menu.
    private func menuHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    /// Creates a non-interactive grey label (e.g. for the version string).
    private func greyLabel(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        setEnabled(!gEnabled)
    }

    /// Sets the master enabled state, persists it, and updates the UI.
    private func setEnabled(_ enabled: Bool) {
        gEnabled = enabled
        UserDefaults.standard.set(gEnabled, forKey: Defaults.enabled)
        if enabled, gSoundsEnabled { NSSound(named: .init("Bottle"))?.play() }
        updateMenuBarIcon()
        updateEnableItem()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openSettingsForLaunchAtLogin() {
        GeneralViewController.pendingLaunchAtLoginAlert = true
        SettingsWindowController.shared.show()
    }

    // MARK: - Launch Warning Banner

    /// Shows or hides the "not auto-launching" warning in the dropdown menu.
    private func updateLaunchWarning() {
        let notEnabled = SMAppService.mainApp.status != .enabled
        launchWarningItem.isHidden = !notEnabled
        launchWarningSep.isHidden  = !notEnabled

        if notEnabled {
            launchWarningItem.attributedTitle = NSAttributedString(
                string: "Not auto-launching  ·  Click to fix",
                attributes: [
                    .font:            NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.systemOrange,
                ]
            )
            launchWarningItem.image = tintedSymbol(
                "exclamationmark.triangle.fill",
                color: NSColor.systemOrange
            )
        }
    }

    // MARK: - Update Banner

    /// Shows the "Update available" banner at the top of the dropdown menu.
    func showUpdateBanner(downloadURL: String) {
        updateDownloadURL            = downloadURL
        updateAvailableItem.attributedTitle = NSAttributedString(
            string: "Update available  \u{00B7}  Click to download",
            attributes: [
                .font:            NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        updateAvailableItem.image   = tintedSymbol("arrow.down.circle.fill", color: .systemBlue)
        updateAvailableItem.isHidden = false
        updateAvailableSep.isHidden  = false
    }

    @objc private func openDownloadURL() {
        guard let urlStr = updateDownloadURL, let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Feature Toggle Sync

    /// Called by the settings window after it changes a feature toggle,
    /// so the menu checkmarks stay in sync.
    func syncMenuItems() {
        instantSwitchItem.state = gInstantSwitchEnabled ? .on : .off
        autoFollowItem.state    = gAutoFollowEnabled    ? .on : .off
    }

    @objc private func toggleInstantSwitch(_ sender: NSMenuItem) {
        gInstantSwitchEnabled.toggle()
        sender.state = gInstantSwitchEnabled ? .on : .off
        UserDefaults.standard.set(gInstantSwitchEnabled, forKey: Defaults.instantSwitch)
    }

    @objc private func toggleAutoFollow(_ sender: NSMenuItem) {
        gAutoFollowEnabled.toggle()
        sender.state = gAutoFollowEnabled ? .on : .off
        UserDefaults.standard.set(gAutoFollowEnabled, forKey: Defaults.autoFollow)
    }

    // MARK: - Statistics

    /// Updates the stats menu item with the current switch count and estimated time saved.
    private func updateStatsDisplay() {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let countStr = fmt.string(from: NSNumber(value: gSwitchCount)) ?? "\(gSwitchCount)"
        statsItem.title = "\(countStr) switches  ·  \(formatTimeSaved(gSwitchCount)) saved"
    }

    /// Increments the switch counter and refreshes the stats display.
    func recordSwitch() {
        gSwitchCount += 1
        updateStatsDisplay()
    }
}
