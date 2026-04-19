/*
 * Settings.swift — Preferences window with General and About tabs
 *
 * The settings window uses a toolbar-style NSTabViewController with two tabs:
 *
 *   General — Launch at Login toggle, feature toggles, sounds, Dock instant-hide
 *   About   — App icon, version, authors, update notice
 *
 * All UI is built programmatically (no nibs or storyboards) using
 * Auto Layout and NSStackView for consistent, resizable layouts.
 */

import AppKit
import ServiceManagement

// MARK: - Tab View Controller

/// Manages the toolbar tabs and resizes the window to fit each tab's content.
final class PreferencesTabViewController: NSTabViewController {

    override func viewDidAppear() {
        super.viewDidAppear()
        let item = tabViewItems[selectedTabViewItemIndex]
        applyWindowSize(for: item, animate: false)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let item = tabViewItem else { return }
        applyWindowSize(for: item, animate: true)
    }

    /// Re-applies the window size for the current tab (e.g. after showing/hiding a banner).
    func resizeCurrent(animate: Bool = true) {
        let item = tabViewItems[selectedTabViewItemIndex]
        applyWindowSize(for: item, animate: animate)
    }

    /// Resizes the window to fit the given tab's content, keeping the
    /// title bar anchored at the top (origin.y shifts to compensate).
    private func applyWindowSize(for item: NSTabViewItem, animate: Bool) {
        guard let vc = item.viewController, let window = view.window else { return }
        vc.view.layoutSubtreeIfNeeded()
        window.title = item.label

        let contentSize = vc.view.fittingSize
        var frame       = window.frame
        let newHeight   = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).height

        // Anchor the top edge: shift origin down by the height difference
        frame.origin.y   += frame.height - newHeight
        frame.size.height = newHeight
        window.setFrame(frame, display: true, animate: animate)
    }
}

// MARK: - Settings Window Controller

/// Singleton that owns and shows the preferences window.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    /// Shows the settings window, creating it on first call.
    func show() {
        if window == nil { window = makeWindow() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let tabVC = PreferencesTabViewController()
        tabVC.tabStyle = .toolbar

        // General tab: toggles and system settings
        let generalItem = NSTabViewItem(viewController: GeneralViewController())
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "togglepower", accessibilityDescription: nil)
        tabVC.addTabViewItem(generalItem)

        // About tab: app info, authors, update notice
        let aboutItem = NSTabViewItem(viewController: AboutViewController())
        aboutItem.label = "About"
        aboutItem.image = NSImage(systemSymbolName: "hare", accessibilityDescription: nil)
        tabVC.addTabViewItem(aboutItem)

        let w = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentViewController = tabVC
        return w
    }
}

// MARK: - General Tab

/// The "General" preferences tab with all runtime settings.
final class GeneralViewController: NSViewController {

    /// When true, the launch-at-login row will flash on next appearance
    /// (set by the menu bar warning banner to draw attention).
    static var pendingLaunchAtLoginAlert = false

    // MARK: Controls

    private var instantSwitchControl:   NSSwitch!
    private var autoFollowControl:      NSSwitch!
    private var soundsControl:          NSSwitch!
    private var launchAtLoginControl:   NSSwitch!
    private var launchStatusLabel:      NSTextField!
    private var launchWarningBanner:    NSView!
    private var instantDockHideControl: NSSwitch!
    private var dockResetDivider:       NSView!
    private var dockResetRow:           NSView!

    override func loadView() { view = NSView() }

    // MARK: View Setup

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create all toggle switches
        instantSwitchControl   = makeSwitch(gInstantSwitchEnabled, #selector(toggleInstantSwitch))
        autoFollowControl      = makeSwitch(gAutoFollowEnabled,    #selector(toggleAutoFollow))
        soundsControl          = makeSwitch(gSoundsEnabled,        #selector(toggleSounds))
        launchAtLoginControl   = makeSwitch(false,                  #selector(toggleLaunchAtLogin))

        // Status label shown below the launch-at-login toggle when there's an issue
        launchStatusLabel                         = NSTextField(wrappingLabelWithString: "")
        launchStatusLabel.font                    = .systemFont(ofSize: 11)
        launchStatusLabel.textColor               = .secondaryLabelColor
        launchStatusLabel.preferredMaxLayoutWidth = 240
        launchStatusLabel.isHidden                = true

        // --- Group 1: Launch at Login ---
        let group1 = groupContainer()
        group1.addArrangedSubview(settingsRow(
            symbol: "gearshape.2.fill",
            color:  NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1),
            label:  "Launch at login",
            control: launchAtLoginControl,
            subtitle: launchStatusLabel
        ))

        // --- Group 2: Feature Toggles ---
        let group2 = groupContainer()
        group2.addArrangedSubview(settingsRow(
            symbol: "arrow.left.arrow.right",
            color:  NSColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1),
            label:  "Instant space switch",
            control: instantSwitchControl
        ))
        group2.addArrangedSubview(rowDivider())
        group2.addArrangedSubview(settingsRow(
            symbol: "scope",
            color:  NSColor(red: 0.35, green: 0.75, blue: 0.40, alpha: 1),
            label:  "Auto-follow on \u{2318}\u{21E5}",
            control: autoFollowControl
        ))

        // --- Group 3: Interface ---
        let group3 = groupContainer()
        group3.addArrangedSubview(settingsRow(
            symbol: "speaker.wave.2.fill",
            color:  NSColor(red: 0.60, green: 0.35, blue: 0.85, alpha: 1),
            label:  "Enable sounds",
            control: soundsControl
        ))

        // Warning banner shown when launch-at-login is not enabled
        launchWarningBanner = makeLaunchWarningBanner()

        // --- Group 4: Advanced (Dock instant-hide) ---
        let dockSubtitle                     = NSTextField(wrappingLabelWithString:
            "This changes a global macOS setting.")
        dockSubtitle.font                    = .systemFont(ofSize: 11)
        dockSubtitle.textColor               = .secondaryLabelColor
        dockSubtitle.preferredMaxLayoutWidth = 240

        instantDockHideControl = makeSwitch(isDockInstantHideEnabled(), #selector(toggleDockInstantHide))

        // "Reset to system default" link button
        let resetBtn = LinkButton(title: "", target: self, action: #selector(resetDockToDefault))
        resetBtn.isBordered = false
        resetBtn.attributedTitle = NSAttributedString(string: "Reset to system default", attributes: [
            .font:            NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
        ])

        let resetIcon = NSImageView()
        resetIcon.image            = NSImage(systemSymbolName: "arrow.clockwise",
                                             accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
        resetIcon.contentTintColor = .linkColor

        let resetStack = NSStackView(views: [resetIcon, resetBtn])
        resetStack.orientation = .horizontal
        resetStack.spacing     = 2
        resetStack.alignment   = .centerY
        resetStack.translatesAutoresizingMaskIntoConstraints = false

        let resetRowView = NSView()
        resetRowView.addSubview(resetStack)
        NSLayoutConstraint.activate([
            resetStack.trailingAnchor.constraint(equalTo: resetRowView.trailingAnchor, constant: -8),
            resetStack.topAnchor.constraint(equalTo: resetRowView.topAnchor, constant: 4),
            resetStack.bottomAnchor.constraint(equalTo: resetRowView.bottomAnchor, constant: -7),
        ])

        dockResetRow     = resetRowView
        dockResetDivider = rowDivider()

        // Hidden by default; viewWillAppear sets the correct visibility
        dockResetDivider.isHidden = true
        dockResetRow.isHidden     = true

        let group4 = groupContainer()
        group4.addArrangedSubview(settingsRow(
            symbol:   "dock.rectangle",
            color:    NSColor(red: 0.85, green: 0.50, blue: 0.15, alpha: 1),
            label:    "Instant Dock hide",
            control:  instantDockHideControl,
            subtitle: dockSubtitle
        ))
        group4.addArrangedSubview(dockResetDivider)
        group4.addArrangedSubview(dockResetRow)

        // --- Assemble the outer layout ---
        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment   = .leading
        outerStack.spacing     = 6
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        outerStack.addArrangedSubview(launchWarningBanner)
        outerStack.setCustomSpacing(14, after: launchWarningBanner)
        outerStack.addArrangedSubview(sectionTitle("Auto-start"))
        outerStack.addArrangedSubview(group1)
        outerStack.setCustomSpacing(14, after: group1)
        outerStack.addArrangedSubview(sectionTitle("Features"))
        outerStack.addArrangedSubview(group2)
        outerStack.setCustomSpacing(14, after: group2)
        outerStack.addArrangedSubview(sectionTitle("Interface"))
        outerStack.addArrangedSubview(group3)
        outerStack.setCustomSpacing(14, after: group3)
        outerStack.addArrangedSubview(sectionTitle("Advanced"))
        outerStack.addArrangedSubview(group4)

        // Make all groups stretch to full width
        for sub in [launchWarningBanner!, group1, group2, group3, group4] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            outerStack.addConstraint(
                sub.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor)
            )
        }

        view.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            outerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            outerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            outerStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16),
            view.widthAnchor.constraint(equalToConstant: 480),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        updateLaunchAtLoginUI()
    }

    // MARK: View Lifecycle

    override func viewWillAppear() {
        super.viewWillAppear()

        // Refresh all toggle states (they may have been changed via the menu bar)
        instantSwitchControl.state   = gInstantSwitchEnabled     ? .on : .off
        autoFollowControl.state      = gAutoFollowEnabled        ? .on : .off
        soundsControl.state          = gSoundsEnabled            ? .on : .off
        instantDockHideControl.state = isDockInstantHideEnabled() ? .on : .off
        updateDockResetLink()
        updateLaunchAtLoginUI()

        // If the user arrived here from the menu bar warning, flash the banner
        if GeneralViewController.pendingLaunchAtLoginAlert {
            GeneralViewController.pendingLaunchAtLoginAlert = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                launchWarningBanner.animator().alphaValue = 0.2
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
                    self.launchWarningBanner.animator().alphaValue = 1.0
                }
            }
        }
    }

    // MARK: - Row Builder Helpers

    /// Creates a standard settings row: colored icon | label (+ optional subtitle) | control.
    private func settingsRow(symbol: String, color: NSColor, label: String,
                             control: NSView, subtitle: NSTextField? = nil) -> NSView {
        let icon = makeIconView(symbol: symbol, color: color)

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.spacing     = 2
        textStack.alignment   = .leading
        textStack.addArrangedSubview(labelField)
        if let sub = subtitle { textStack.addArrangedSubview(sub) }

        let row = NSStackView()
        row.orientation  = .horizontal
        row.spacing      = 10
        row.alignment    = .centerY
        row.edgeInsets   = NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())   // Flexible spacer pushes the control to the right
        row.addArrangedSubview(control)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])
        return row
    }

    /// Creates a rounded, bordered container for grouping related settings rows.
    private func groupContainer() -> NSStackView {
        let isDark  = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark ? NSColor(white: 1, alpha: 0.02) : NSColor(white: 0, alpha: 0.02)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing     = 0
        stack.wantsLayer  = true
        stack.layer?.cornerRadius    = 8
        stack.layer?.borderWidth     = 0.5
        stack.layer?.borderColor     = NSColor.separatorColor.cgColor
        stack.layer?.backgroundColor = bgColor.cgColor
        return stack
    }

    /// Creates a small colored square with an SF Symbol icon inside (used as row icons).
    private func makeIconView(symbol: String, color: NSColor) -> NSView {
        let container = NSView()
        container.wantsLayer    = true
        container.layer?.backgroundColor = color.cgColor
        container.layer?.cornerRadius    = 6

        let cfg     = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let imgView = NSImageView()
        imgView.image              = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        imgView.contentTintColor   = .white
        imgView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imgView)
        NSLayoutConstraint.activate([
            imgView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imgView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// Creates an uppercase section title label (e.g. "FEATURES", "ADVANCED").
    private func sectionTitle(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font      = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Creates a horizontal separator line between settings rows.
    private func rowDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// Creates a mini NSSwitch pre-configured with the given state and action.
    private func makeSwitch(_ state: Bool, _ action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.controlSize = .mini
        s.state       = state ? .on : .off
        s.target      = self
        s.action      = action
        return s
    }

    /// Creates the orange warning banner shown when launch-at-login is disabled.
    private func makeLaunchWarningBanner() -> NSView {
        let container = NSView()
        container.wantsLayer              = true
        container.layer?.cornerRadius     = 8
        container.layer?.borderWidth      = 0.5
        container.layer?.backgroundColor  = NSColor.systemOrange.withAlphaComponent(0.05).cgColor
        container.layer?.borderColor      = NSColor.systemOrange.withAlphaComponent(0.20).cgColor

        let cfg     = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let imgView = NSImageView()
        imgView.image            = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                           accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        imgView.contentTintColor = .systemOrange
        imgView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString:
            "Space Rabbit is not set to launch at login. Enable \u{201C}Launch at login\u{201D} below so it starts automatically.")
        label.font      = .systemFont(ofSize: 12)
        label.textColor = NSColor.systemOrange
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imgView)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            imgView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            imgView.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            imgView.widthAnchor.constraint(equalToConstant: 15),
            imgView.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    // MARK: - Launch at Login

    /// Updates the launch-at-login switch, status label, and warning banner
    /// to reflect the current SMAppService registration state.
    private func updateLaunchAtLoginUI(errorMessage: String? = nil) {
        let status = SMAppService.mainApp.status

        launchAtLoginControl.state     = (status == .enabled) ? .on : .off
        launchAtLoginControl.isEnabled = true
        launchWarningBanner?.isHidden  = (status == .enabled)

        // Resize the window to accommodate the banner appearing/disappearing
        (parent as? PreferencesTabViewController)?.resizeCurrent()

        if let msg = errorMessage {
            launchStatusLabel.stringValue = msg
            launchStatusLabel.isHidden    = false
        } else if status == .requiresApproval {
            launchStatusLabel.stringValue = "Approval needed — check Login Items in System Settings."
            launchStatusLabel.isHidden    = false
        } else {
            launchStatusLabel.isHidden = true
        }
    }

    // MARK: - Toggle Actions

    @objc private func toggleInstantSwitch() {
        gInstantSwitchEnabled = instantSwitchControl.state == .on
        UserDefaults.standard.set(gInstantSwitchEnabled, forKey: Defaults.instantSwitch)
        gMenu?.syncMenuItems()
    }

    @objc private func toggleAutoFollow() {
        gAutoFollowEnabled = autoFollowControl.state == .on
        UserDefaults.standard.set(gAutoFollowEnabled, forKey: Defaults.autoFollow)
        gMenu?.syncMenuItems()
    }

    @objc private func toggleSounds() {
        gSoundsEnabled = soundsControl.state == .on
        UserDefaults.standard.set(gSoundsEnabled, forKey: Defaults.sounds)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginControl.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            updateLaunchAtLoginUI()
        } catch {
            let msg = "Could not update login item: \(error.localizedDescription)"
            fputs("Space Rabbit: launch at login: \(error)\n", stderr)
            updateLaunchAtLoginUI(errorMessage: msg)
        }
    }

    // MARK: - Dock Instant-Hide
    //
    // macOS supports a hidden preference `autohide-time-modifier` on com.apple.dock
    // that controls the Dock show/hide animation speed. Setting it to 0.0 makes the
    // Dock appear and disappear instantly (no animation). Removing the key restores
    // the system default behavior.
    //
    // Changes require a Dock restart to take effect (`killall Dock`).

    /// Checks whether the Dock's autohide animation is set to instant (0.0 seconds).
    private func isDockInstantHideEnabled() -> Bool {
        let v = CFPreferencesCopyAppValue(
            "autohide-time-modifier" as CFString,
            "com.apple.dock" as CFString
        )
        return (v as? NSNumber)?.doubleValue == 0.0
    }

    /// Sets the Dock's autohide animation duration, or removes the override entirely.
    private func setDockAutohideModifier(_ value: Double?) {
        if let v = value {
            CFPreferencesSetAppValue(
                "autohide-time-modifier" as CFString,
                NSNumber(value: v),
                "com.apple.dock" as CFString
            )
        } else {
            CFPreferencesSetAppValue(
                "autohide-time-modifier" as CFString,
                nil,
                "com.apple.dock" as CFString
            )
        }
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
    }

    /// Shows or hides the "Reset to system default" link based on whether
    /// the Dock autohide modifier is currently overridden.
    private func updateDockResetLink() {
        let hasOverride = CFPreferencesCopyAppValue(
            "autohide-time-modifier" as CFString,
            "com.apple.dock" as CFString
        ) != nil
        dockResetDivider.isHidden = !hasOverride
        dockResetRow.isHidden     = !hasOverride
        (parent as? PreferencesTabViewController)?.resizeCurrent()
    }

    /// Prompts the user to restart the Dock so the autohide change takes effect.
    private func promptDockRestart() {
        let alert = NSAlert()
        alert.messageText     = "Restart Dock to apply changes?"
        alert.informativeText = "The Dock needs to restart for this setting to take effect. Your Dock will briefly disappear and reappear."
        alert.addButton(withTitle: "Restart Dock Now")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            let task = Process()
            task.launchPath = "/usr/bin/killall"
            task.arguments  = ["Dock"]
            try? task.run()
        }
    }

    @objc private func toggleDockInstantHide() {
        let enabled = instantDockHideControl.state == .on
        setDockAutohideModifier(enabled ? 0.0 : nil)
        updateDockResetLink()
        promptDockRestart()
    }

    @objc private func resetDockToDefault() {
        setDockAutohideModifier(nil)
        instantDockHideControl.state = .off
        updateDockResetLink()
        promptDockRestart()
    }
}

// MARK: - About Tab

/// The "About" tab showing app info, version, authors, and update notice.
final class AboutViewController: NSViewController {
    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        // App icon
        let iconView = NSImageView()
        iconView.image        = NSImage(named: "NSApplicationIcon")
        iconView.imageScaling = .scaleProportionallyDown
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 80),
            iconView.heightAnchor.constraint(equalToConstant: 80),
        ])

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

        // App name and version labels
        let nameLabel = NSTextField(labelWithString: "Space Rabbit")
        nameLabel.font      = .boldSystemFont(ofSize: 15)
        nameLabel.textColor = .labelColor

        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font      = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let copyrightLabel = NSTextField(labelWithString: "© 2026 Yaël Guilloux & Valerian Saliou")
        copyrightLabel.font      = .systemFont(ofSize: 11)
        copyrightLabel.textColor = .tertiaryLabelColor

        let websiteLink = makeAuthorLink(name: "space-rabbit.app", url: "https://space-rabbit.app")
        websiteLink.font = .systemFont(ofSize: 11)

        let appStack = NSStackView(views: [iconView, nameLabel, versionLabel, copyrightLabel, websiteLink])
        appStack.orientation = .vertical
        appStack.alignment   = .centerX
        appStack.spacing     = 5
        appStack.setCustomSpacing(10, after: iconView)

        // --- Update notice box ---
        let updateIcon = NSImageView()
        updateIcon.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        updateIcon.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            updateIcon.widthAnchor.constraint(equalToConstant: 14),
            updateIcon.heightAnchor.constraint(equalToConstant: 14),
        ])

        let updateText = NSTextField(wrappingLabelWithString: "")
        updateText.preferredMaxLayoutWidth = 340
        updateText.stringValue  = "Space Rabbit does not update automatically. Updates must be applied manually. However, we will notify you when there is a new update available."
        updateText.font         = .systemFont(ofSize: 11)
        updateText.textColor    = .secondaryLabelColor

        let updateRow = NSStackView(views: [updateIcon, updateText])
        updateRow.orientation = .horizontal
        updateRow.alignment   = .top
        updateRow.spacing     = 6

        let updateBox = NSView()
        updateBox.wantsLayer              = true
        updateBox.layer?.cornerRadius     = 8
        updateBox.layer?.borderWidth      = 0.5
        updateBox.layer?.borderColor      = NSColor.separatorColor.cgColor
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        updateBox.layer?.backgroundColor  = (isDark ? NSColor(white: 1, alpha: 0.02)
                                                     : NSColor(white: 0, alpha: 0.02)).cgColor

        updateRow.translatesAutoresizingMaskIntoConstraints = false
        updateBox.addSubview(updateRow)
        NSLayoutConstraint.activate([
            updateRow.topAnchor.constraint(equalTo: updateBox.topAnchor, constant: 10),
            updateRow.leadingAnchor.constraint(equalTo: updateBox.leadingAnchor, constant: 12),
            updateRow.trailingAnchor.constraint(equalTo: updateBox.trailingAnchor, constant: -12),
            updateRow.bottomAnchor.constraint(equalTo: updateBox.bottomAnchor, constant: -10),
        ])

        // --- Author links ---
        let authorsStack = NSStackView(views: [
            makeAuthorLink(name: "Yaël Guilloux",   url: "https://github.com/tahul"),
            makeAuthorLink(name: "Valerian Saliou", url: "https://valeriansaliou.name"),
        ])
        authorsStack.orientation = .horizontal
        authorsStack.spacing     = 16

        // --- Final layout ---
        let outerStack = NSStackView(views: [appStack, authorsStack, updateBox])
        outerStack.orientation = .vertical
        outerStack.alignment   = .centerX
        outerStack.spacing     = 20
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.setCustomSpacing(20, after: appStack)

        view.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            outerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            outerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            outerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            outerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            updateBox.leadingAnchor.constraint(equalTo: outerStack.leadingAnchor),
            updateBox.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor),
            view.widthAnchor.constraint(equalToConstant: 480),
        ])
    }

    /// Creates a clickable author link as an NSTextField with a URL attribute.
    private func makeAuthorLink(name: String, url: String) -> NSTextField {
        let field = LinkTextField(labelWithString: "")
        field.isSelectable              = true
        field.allowsEditingTextAttributes = true
        field.attributedStringValue     = NSAttributedString(string: name, attributes: [
            .font:  NSFont.systemFont(ofSize: 12),
            .link:  URL(string: url)!,
        ])
        return field
    }
}

// MARK: - Custom Controls

/// An NSTextField subclass that shows a pointing-hand cursor on hover.
/// Used for author/website links in the About tab.
final class LinkTextField: NSTextField {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// An NSButton subclass that shows a pointing-hand cursor on hover.
/// Used for the "Reset to system default" link in the General tab.
final class LinkButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
