import Foundation

struct Credentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAtMs: Double?
}

enum KeychainError: Error, Equatable {
    case notFound      // item absent (security exit 44) -> user hasn't signed in
    case denied        // user dismissed/denied the access dialog, or timed out
    case decode        // got output but couldn't parse the JSON
    case failed(Int32) // any other non-zero exit
}

/// Reads Claude Code's OAuth credentials by shelling out to the signed
/// `/usr/bin/security` binary, which is already on the keychain item's ACL.
/// Going through `security` (rather than the SecItem API) means the access
/// prompt, if any, names `security` and a one-time "Always Allow" sticks.
/// Stateless: the poller owns the negative-cache / retry policy.
enum KeychainReader {
    static let service = "Claude Code-credentials"

    static func readCredentials(timeout: TimeInterval = 5) -> Result<Credentials, KeychainError> {
        let result = runWithTimeout(
            path: "/usr/bin/security",
            args: ["find-generic-password", "-s", service, "-w"],
            timeout: timeout)

        guard let result = result else {
            return .failure(.failed(-1))
        }
        if result.timedOut {
            return .failure(.denied)
        }
        if result.code != 0 {
            // 44 = errSecItemNotFound; 128/36 etc. = user cancelled / denied
            if result.code == 44 { return .failure(.notFound) }
            if result.code == 128 || result.code == 36 { return .failure(.denied) }
            return .failure(.failed(result.code))
        }

        // `-w` prints the secret (our JSON) followed by a newline.
        guard let raw = String(data: result.out, encoding: .utf8) else {
            return .failure(.decode)
        }
        let json = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let blob = try? JSONDecoder().decode(CredentialsFile.self, from: data),
              let oauth = blob.claudeAiOauth else {
            return .failure(.decode)
        }
        return .success(Credentials(
            accessToken: oauth.accessToken,
            refreshToken: oauth.refreshToken,
            expiresAtMs: oauth.expiresAt))
    }

    private struct CredentialsFile: Decodable {
        let claudeAiOauth: OAuthBlob?
        struct OAuthBlob: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
        }
    }
}

// MARK: - Process with hard timeout

struct ProcessResult {
    let code: Int32
    let out: Data
    let err: Data
    let timedOut: Bool
}

/// Runs a command, killing it after `timeout`. Output is small (~2 KB) so
/// reading the pipes after exit is safe (no 64 KB buffer deadlock risk).
func runWithTimeout(path: String, args: [String], timeout: TimeInterval) -> ProcessResult? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe

    do {
        try proc.run()
    } catch {
        return nil
    }

    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        proc.waitUntilExit()
        sem.signal()
    }

    var timedOut = false
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        proc.terminate()                              // SIGTERM
        if sem.wait(timeout: .now() + 1) == .timedOut {
            kill(proc.processIdentifier, SIGKILL)     // escalate if it survives
            _ = sem.wait(timeout: .now() + 1)
        }
    }

    let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
    // Reading terminationStatus on a still-running Process throws an uncatchable
    // ObjC exception — only read it once the process has actually exited.
    let code = proc.isRunning ? -1 : proc.terminationStatus
    return ProcessResult(code: code, out: outData, err: errData, timedOut: timedOut)
}
