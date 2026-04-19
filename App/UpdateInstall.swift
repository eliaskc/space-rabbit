/*
 * UpdateInstall.swift — Automatic update download and installation
 *
 * Handles the full update flow when the user clicks "Update available"
 * in the menu bar dropdown:
 *
 *   1. Opens a small progress window and downloads the DMG from GitHub.
 *   2. Mounts the DMG, copies the new .app over the running bundle, unmounts.
 *   3. Prompts the user to restart (dismissible — the old version keeps running).
 *
 * On failure an alert offers "Try Again" or "Cancel".
 * Cancelling at any point leaves the "Update available" banner intact.
 */

import AppKit
import Foundation

// MARK: - Entry Point

/// Called by MenuBar when the user clicks the "Update available" banner.
func startUpdate(downloadURL: String) {
    UpdaterWindowController.shared.start(downloadURL: downloadURL)
}

// MARK: - UpdaterWindowController

final class UpdaterWindowController: NSObject, NSWindowDelegate, URLSessionDownloadDelegate {

    static let shared = UpdaterWindowController()

    // MARK: UI

    private let window:       NSWindow
    private let statusLabel:  NSTextField
    private let progressBar:  NSProgressIndicator
    private let cancelButton: NSButton

    // MARK: State

    private var session:      URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var currentURL:   String?
    private var isInstalling  = false   // true while files are being written (block window close)

    // MARK: - Init

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 130),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        window.title = "Space Rabbit Update"
        window.isReleasedWhenClosed      = false
        window.isMovableByWindowBackground = true

        statusLabel = NSTextField(labelWithString: "Preparing download…")
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar = NSProgressIndicator()
        progressBar.style           = .bar
        progressBar.isIndeterminate = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.keyEquivalent = "\u{1b}"   // Escape
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        super.init()

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        window.delegate     = self

        let content = window.contentView!
        content.addSubview(statusLabel)
        content.addSubview(progressBar)
        content.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor .constraint(equalTo: content.leadingAnchor,      constant:  20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor,     constant: -20),
            statusLabel.topAnchor     .constraint(equalTo: content.topAnchor,          constant:  22),

            progressBar.leadingAnchor .constraint(equalTo: content.leadingAnchor,      constant:  20),
            progressBar.trailingAnchor.constraint(equalTo: content.trailingAnchor,     constant: -20),
            progressBar.topAnchor     .constraint(equalTo: statusLabel.bottomAnchor,   constant:  12),

            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor,    constant: -20),
            cancelButton.topAnchor     .constraint(equalTo: progressBar.bottomAnchor,  constant:  14),
            cancelButton.bottomAnchor  .constraint(equalTo: content.bottomAnchor,      constant: -16),
        ])
    }

    // MARK: - Start

    /// Resets the window state and begins a fresh download.
    /// Safe to call while a previous download is already in progress.
    func start(downloadURL: String) {
        currentURL   = downloadURL
        isInstalling = false

        // Cancel any in-flight session silently (won't fire the error delegate)
        session?.invalidateAndCancel()
        session      = nil
        downloadTask = nil

        // Reset UI to initial state
        statusLabel.stringValue     = "Downloading update…"
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        cancelButton.isEnabled      = true

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard let url = URL(string: downloadURL) else { return }
        let s    = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session  = s
        downloadTask = s.downloadTask(with: url)
        downloadTask?.resume()
    }

    // MARK: - Cancel

    @objc private func cancelTapped() {
        guard !isInstalling else { return }
        session?.invalidateAndCancel()
        session      = nil
        downloadTask = nil
        window.close()
        // Banner stays visible — update is still available
    }

    // MARK: - NSWindowDelegate

    /// Blocks the close button while files are being written to disk.
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isInstalling }

    func windowWillClose(_ notification: Notification) {
        guard !isInstalling else { return }
        session?.invalidateAndCancel()
        session      = nil
        downloadTask = nil
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.progressBar.isIndeterminate = false
            self.progressBar.minValue        = 0
            self.progressBar.maxValue        = 1
            self.progressBar.doubleValue     = fraction
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move to a stable temp path — the provided location is ephemeral
        let dmgPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpaceRabbitUpdate.dmg")

        do {
            if FileManager.default.fileExists(atPath: dmgPath.path) {
                try FileManager.default.removeItem(at: dmgPath)
            }
            try FileManager.default.moveItem(at: location, to: dmgPath)
        } catch {
            reportFailure()
            return
        }

        DispatchQueue.main.async {
            self.isInstalling               = true
            self.statusLabel.stringValue    = "Installing…"
            self.progressBar.isIndeterminate = true
            self.progressBar.startAnimation(nil)
            self.cancelButton.isEnabled     = false
        }

        // Install runs synchronously on the URLSession background thread
        install(dmgPath: dmgPath)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        // User-initiated cancellation — no error UI needed
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        reportFailure()
    }

    // MARK: - Install

    /// Mounts the DMG, copies the .app over the running bundle, then unmounts.
    /// Runs on a background thread (URLSession delegate queue).
    private func install(dmgPath: URL) {
        // 1. Mount the DMG
        let mountOutput = shell("/usr/bin/hdiutil",
                                ["attach", "-nobrowse", "-noautoopen", dmgPath.path])

        guard let mountPoint = parseMountPoint(from: mountOutput) else {
            cleanup(dmgPath: dmgPath, mountPoint: nil)
            reportFailure()
            return
        }

        // 2. Locate the .app bundle inside the mounted volume
        let volumeURL = URL(fileURLWithPath: mountPoint)
        guard let appEntry = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint))?
                .first(where: { $0.hasSuffix(".app") }) else {
            cleanup(dmgPath: dmgPath, mountPoint: mountPoint)
            reportFailure()
            return
        }

        let sourceApp = volumeURL.appendingPathComponent(appEntry)
        let destApp   = Bundle.main.bundleURL

        // 3. Stage the new .app next to the current one (same volume → cheap rename)
        let stagedApp = destApp.deletingLastPathComponent()
            .appendingPathComponent("Space Rabbit.staged.app")

        do {
            if FileManager.default.fileExists(atPath: stagedApp.path) {
                try FileManager.default.removeItem(at: stagedApp)
            }
            try FileManager.default.copyItem(at: sourceApp, to: stagedApp)
        } catch {
            cleanup(dmgPath: dmgPath, mountPoint: mountPoint)
            reportFailure()
            return
        }

        // 4. Atomically swap the staged bundle into place
        do {
            _ = try FileManager.default.replaceItemAt(destApp, withItemAt: stagedApp)
        } catch {
            try? FileManager.default.removeItem(at: stagedApp)
            cleanup(dmgPath: dmgPath, mountPoint: mountPoint)
            reportFailure()
            return
        }

        // 5. Unmount and delete the temp DMG
        cleanup(dmgPath: dmgPath, mountPoint: mountPoint)

        // 6. Prompt for restart on the main thread
        DispatchQueue.main.async { self.showRestartPrompt() }
    }

    // MARK: - Post-Install Prompt

    private func showRestartPrompt() {
        isInstalling = false
        window.close()

        let alert = NSAlert()
        alert.messageText      = "Update installed"
        alert.informativeText  = "Restart Space Rabbit to start using the new version."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Spawn a detached shell that waits for this process to exit, then
        // opens the (now-updated) bundle.  This is more reliable than calling
        // openApplication + terminate back-to-back, where the process can die
        // before the OS has processed the open request.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments     = ["-c", "sleep 0.5 && open \"$1\"", "--",
                               Bundle.main.bundleURL.path]
        try? proc.run()
        NSApp.terminate(nil)
    }

    // MARK: - Error

    private func reportFailure() {
        DispatchQueue.main.async {
            self.isInstalling = false
            self.window.close()

            let alert = NSAlert()
            alert.messageText     = "Could not update Space Rabbit"
            alert.informativeText = "Something went wrong while downloading or installing the update."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Cancel")

            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, let url = self.currentURL {
                self.start(downloadURL: url)
            }
            // "Cancel" — window stays closed, banner stays visible
        }
    }

    // MARK: - Helpers

    private func cleanup(dmgPath: URL, mountPoint: String?) {
        if let mp = mountPoint {
            shell("/usr/bin/hdiutil", ["detach", mp, "-force"])
        }
        try? FileManager.default.removeItem(at: dmgPath)
    }

    /// Runs a command synchronously and returns its stdout.
    @discardableResult
    private func shell(_ executable: String, _ args: [String]) -> String {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL  = URL(fileURLWithPath: executable)
        proc.arguments      = args
        proc.standardOutput = pipe
        proc.standardError  = Pipe()   // suppress stderr
        try? proc.run()
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8) ?? ""
    }

    /// Extracts the /Volumes/… mount point from `hdiutil attach` output.
    ///
    /// hdiutil prints one tab-separated row per partition:
    ///   /dev/diskNsM  \t  FSType  \t  /Volumes/Name
    private func parseMountPoint(from output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let cols = line.components(separatedBy: "\t")
            if cols.count >= 3 {
                let candidate = cols[2].trimmingCharacters(in: .whitespaces)
                if candidate.hasPrefix("/Volumes/") { return candidate }
            }
        }
        return nil
    }
}
