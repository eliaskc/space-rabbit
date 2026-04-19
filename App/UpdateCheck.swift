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

// MARK: - Version Comparison

/// Compares two semantic version strings (with optional "v" prefix).
/// Returns true if `remote` is strictly newer than `local`.
///
/// Examples:
///   isNewerVersion("v1.2.0", than: "1.1.0") -> true
///   isNewerVersion("1.0.0", than: "1.0.0")  -> false
///   isNewerVersion("1.0.1", than: "1.1.0")  -> false
private func isNewerVersion(_ remote: String, than local: String) -> Bool {
    let strip = { (s: String) -> String in s.hasPrefix("v") ? String(s.dropFirst()) : s }
    let parts = { (s: String) -> [Int] in strip(s).split(separator: ".").compactMap { Int($0) } }

    let r = parts(remote), l = parts(local)

    for i in 0..<max(r.count, l.count) {
        let rv = i < r.count ? r[i] : 0
        let lv = i < l.count ? l[i] : 0
        if rv != lv { return rv > lv }
    }
    return false
}

// MARK: - Update Check

/// Fetches the latest GitHub release and compares its tag to the current version.
/// If a newer version exists with a DMG asset, shows the update banner in the menu.
func checkForUpdates() {
    guard let url = URL(string: "https://api.github.com/repos/Tahul/space-rabbit/releases/latest")
    else { return }

    URLSession.shared.dataTask(with: url) { data, _, _ in
        guard let data,
              let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag    = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let dmg    = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let dlURL  = dmg["browser_download_url"] as? String
        else { return }

        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard isNewerVersion(tag, than: current) else { return }

        // Update the UI on the main thread
        DispatchQueue.main.async { gMenu?.showUpdateBanner(downloadURL: dlURL) }
    }.resume()
}
