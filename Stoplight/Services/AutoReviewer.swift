import Foundation
import OSLog
import StoplightCore

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "AutoReview")

/// Hands PRs that request my review to my own agent command, headless, one at a time.
/// Each PR runs once per head commit; output goes to ~/Library/Logs/Stoplight/.
@MainActor
final class AutoReviewer {
    static let claudeCommand =
        #"claude -p "$STOPLIGHT_PROMPT" --allowedTools "Bash(gh pr view:*)" "Bash(gh pr diff:*)" "Bash(gh pr review:*)""#

    nonisolated static func prompt(_ url: String) -> String {
        """
        Your review was requested on the GitHub pull request \(url).
        Read it with `gh pr view \(url) --comments` and `gh pr diff \(url)`.
        Look for real problems: bugs, security issues, missing tests, confusing code. Skip style nits.
        Then post exactly one review with `gh pr review \(url) --comment --body "<findings>"`,
        findings ordered by severity, each with file:line. If you find nothing, say so in one line.
        Do not approve, do not request changes, and do not edit any code.
        """
    }

    private let prefs: UserPrefs
    private var queue: [PullRequest] = []
    private var running = false

    init(prefs: UserPrefs) { self.prefs = prefs }

    private static func key(_ pr: PullRequest) -> String { "\(pr.id)@\(pr.headSha)" }

    func enqueue(_ prs: [PullRequest]) {
        for pr in prs where !pr.isDraft && !prefs.autoReviewed.contains(Self.key(pr)) && !queue.contains(where: { $0.id == pr.id }) {
            queue.append(pr)
        }
        next()
    }

    // ponytail: one agent at a time; a long queue drains slowly. Run a few in parallel if that hurts.
    private func next() {
        guard !running, !queue.isEmpty else { return }
        let command = prefs.autoReviewCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { queue = []; return }
        let pr = queue.removeFirst()
        prefs.autoReviewed = Array((prefs.autoReviewed + [Self.key(pr)]).suffix(500))
        running = true
        let url = pr.url.absoluteString
        let logFile = Self.logURL(for: pr)
        log.info("auto-review \(url, privacy: .public) → \(logFile.path, privacy: .public)")
        Task.detached {
            let status = Self.run(command, url: url, logFile: logFile)
            log.info("auto-review \(url, privacy: .public) exited \(status)")
            await MainActor.run {
                self.running = false
                self.next()
            }
        }
    }

    private static func logURL(for pr: PullRequest) -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Stoplight")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("review-\(pr.repo.replacingOccurrences(of: "/", with: "-"))-\(pr.number).log")
    }

    /// Runs under the user's login shell, like `LoginShell.shell`, but with no 15s limit: agents take minutes.
    nonisolated private static func run(_ command: String, url: String, logFile: URL) -> Int32 {
        let sh = LoginShell.loginShell
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sh.path)
        p.arguments = sh.args + [command]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginShell.extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["TERM"] = "dumb"
        env["STOPLIGHT_PR_URL"] = url
        env["STOPLIGHT_PROMPT"] = prompt(url)
        p.environment = env
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: logFile) else { return -1 }
        defer { try? out.close() }
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        // A hung agent would block the queue forever.
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30 * 60, execute: watchdog)
        p.waitUntilExit()
        watchdog.cancel()
        return p.terminationStatus
    }
}
