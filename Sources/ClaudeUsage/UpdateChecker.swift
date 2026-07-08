import Foundation

struct UpdateInfo: Equatable {
    let version: String   // e.g. "1.0.1"
    let url: URL          // release page
}

/// Feedback for the manual "Check for Updates" button.
enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateInfo)
}

/// Lightweight update check: asks the GitHub Releases API for the latest release
/// and compares its tag to this build's version. No auto-install — the app surfaces
/// a banner that opens the release page. (Silent OTA would be Sparkle; see README.)
enum UpdateChecker {
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/max-csr/ccusage-bar/releases/latest")!

    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func check() async -> UpdateInfo? {
        var req = URLRequest(url: latestReleaseAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CC-Usage", forHTTPHeaderField: "User-Agent")  // GitHub requires a UA
        req.timeoutInterval = 15

        // No shared cache/cookies — matches the ephemeral session used elsewhere.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        let session = URLSession(configuration: cfg)

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let urlString = obj["html_url"] as? String,
              let url = URL(string: urlString) else {
            return nil
        }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(latest, than: currentVersion()) else { return nil }
        return UpdateInfo(version: latest, url: url)
    }

    /// Numeric semver-ish comparison ("1.0.10" > "1.0.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
