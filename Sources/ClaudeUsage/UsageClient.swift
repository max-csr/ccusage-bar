import Foundation

enum FetchOutcome {
    case success(UsageResponse)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(Int)
    case transport(Error)
    case decode(Error)
}

/// Networking for the undocumented Claude Code usage endpoint and OAuth refresh.
final class UsageClient {
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let refreshURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    // Claude Code's public OAuth client id (community-known; used only for refresh).
    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    let userAgent: String
    private let session: URLSession

    init(userAgent: String) {
        self.userAgent = userAgent
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        cfg.waitsForConnectivity = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        self.session = URLSession(configuration: cfg)
    }

    private func usageRequest(accessToken: String) -> URLRequest {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // User-Agent is effectively required: omitting it risks persistent 429s.
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// The undecoded response body, for `--probe --raw`. `UsageResponse` silently
    /// drops any key it doesn't declare, so this is the only way to discover a
    /// window the app doesn't model yet (e.g. a newly-named per-model weekly limit).
    func fetchRawUsage(accessToken: String) async -> Result<(status: Int, body: Data), Error> {
        do {
            let (data, resp) = try await session.data(for: usageRequest(accessToken: accessToken))
            guard let http = resp as? HTTPURLResponse else {
                return .failure(URLError(.badServerResponse))
            }
            return .success((http.statusCode, data))
        } catch {
            return .failure(error)
        }
    }

    func fetchUsage(accessToken: String) async -> FetchOutcome {
        do {
            let (data, resp) = try await session.data(for: usageRequest(accessToken: accessToken))
            guard let http = resp as? HTTPURLResponse else {
                return .transport(URLError(.badServerResponse))
            }
            switch http.statusCode {
            case 200:
                do {
                    return .success(try JSONDecoder.usage.decode(UsageResponse.self, from: data))
                } catch {
                    return .decode(error)
                }
            case 401:
                return .unauthorized
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                return .rateLimited(retryAfter: retryAfter)
            default:
                return .server(http.statusCode)
            }
        } catch {
            return .transport(error)
        }
    }

    struct RefreshResult {
        let accessToken: String
        let refreshToken: String?
        let expiresAtMs: Double?
    }

    /// Exchanges a refresh token for a fresh access token. Best-effort: the
    /// refresh endpoint is community-sourced, so any failure returns nil and
    /// the caller falls back to the `.unauthorized` state.
    func refresh(refreshToken: String) async -> RefreshResult? {
        var req = URLRequest(url: refreshURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = obj["access_token"] as? String else {
                return nil
            }
            let refresh = obj["refresh_token"] as? String
            let expiresIn = obj["expires_in"] as? Double
            let expiresAtMs = expiresIn.map { (Date().timeIntervalSince1970 + $0) * 1000 }
            return RefreshResult(accessToken: accessToken, refreshToken: refresh, expiresAtMs: expiresAtMs)
        } catch {
            return nil
        }
    }
}
