/*
 * UpdateCheck.swift — GitHub release version checking
 *
 * Checks the GitHub Releases API for a newer version of Space Rabbit.
 * If a newer DMG is available, shows a banner in the menu bar dropdown
 * with a direct download link.
 *
 * This runs once, 5 seconds after launch, on a background thread.
 * There is no periodic polling — the user must relaunch to check again.
 */

import Foundation

// MARK: - GitHub API

/// The GitHub API endpoint for the latest release of Space Rabbit.
private let kReleasesURL = "https://api.github.com/repos/Tahul/space-rabbit/releases/latest"

// MARK: - Version Comparison

/// Compares two semantic version strings (with optional "v" prefix).
///
/// Supports versions with any number of components (e.g. "1.2", "1.2.3", "2.0.0.1").
/// Missing components are treated as zero (e.g. "1.2" == "1.2.0").
///
/// - Parameters:
///   - remote: The version string from the GitHub release (e.g. "v1.3.0").
///   - local: The current app version (e.g. "1.2.0").
/// - Returns: `true` if `remote` is strictly newer than `local`.
private func isNewerVersion(_ remote: String, than local: String) -> Bool {
    let stripPrefix = { (s: String) -> String in s.hasPrefix("v") ? String(s.dropFirst()) : s }
    let toComponents = { (s: String) -> [Int] in
        stripPrefix(s).split(separator: ".").compactMap { Int($0) }
    }

    let remoteComponents = toComponents(remote)
    let localComponents  = toComponents(local)
    let maxCount         = max(remoteComponents.count, localComponents.count)

    for i in 0..<maxCount {
        let remoteValue = i < remoteComponents.count ? remoteComponents[i] : 0
        let localValue  = i < localComponents.count  ? localComponents[i]  : 0
        if remoteValue != localValue { return remoteValue > localValue }
    }

    // All components are equal
    return false
}

// MARK: - Update Check

/// Fetches the latest GitHub release and compares its tag to the current version.
///
/// If a newer version exists with a DMG asset, shows the update banner
/// in the menu bar dropdown. Runs on a background URLSession thread and
/// dispatches the UI update back to the main thread.
///
/// Called once from `main.swift`, 5 seconds after launch.
func checkForUpdates() {
    guard let url = URL(string: kReleasesURL) else { return }

    URLSession.shared.dataTask(with: url) { data, _, _ in
        guard let data,
              let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag    = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let dmg    = assets.first(where: {
                  ($0["name"] as? String)?.hasSuffix(".dmg") == true
              }),
              let downloadURL = dmg["browser_download_url"] as? String
        else { return }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard isNewerVersion(tag, than: currentVersion) else { return }

        // Update the UI on the main thread
        DispatchQueue.main.async { gMenu?.showUpdateBanner(downloadURL: downloadURL) }
    }.resume()
}
