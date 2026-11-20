import Foundation
import OSLog
import StoplightCore

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "AutoReview")

/// Hands PRs that request my review to my own agent command, headless, one at a time.
/// Each PR runs once per head commit; output goes to ~/Library/Logs/Stoplight/.
@MainActor
final class AutoReviewer {
    static let claudeCommand =
        #"claude -p "$STOPLIGHT_PROMPT" --allowedTools "Bash(gh pr view:*)" "Bash(gh pr diff:*)" "Edit(/$STOPLIGHT_REVIEW_FILE)""#

    nonisolated static func prompt(_ url: String, file: String) -> String {
        """
        Your review was requested on the GitHub pull request \(url). Use the stoplight-review skill if you have it.
        Read the PR with `gh pr view \(url) --comments` and `gh pr diff \(url)`.
        Look for real problems: bugs, security issues, missing tests, confusing code. Skip style nits.
        Do not post anything to GitHub and do not edit code. Stoplight posts for you.
        Write your review as JSON to \(file), exactly this shape:
        {"summary": "one or two sentences", "findings": [{"path": "src/a.swift", "line": 42, "confidence": "high", "body": "what is wrong and why"}]}
        `line` is a line number in the new version of the file, and must be a line the diff adds or shows.
        `confidence` is "high" only when you are sure it is a real bug; otherwise "medium" or "low".
        High findings are posted as your review comments; medium and low become drafts the user checks first.
        No findings: write an empty findings list.
        """
    }

    /// Called on the main actor when a run ends: the review the agent wrote (nil if it wrote none or bad JSON),
    /// and the log file to point at.
    var onFinished: ((PullRequest, AgentReview?, URL) async -> Void)?

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
        let reviewFile = logFile.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.removeItem(at: reviewFile)
        log.info("auto-review \(url, privacy: .public) → \(logFile.path, privacy: .public)")
        Task.detached {
            let status = Self.run(command, url: url, logFile: logFile, reviewFile: reviewFile)
            log.info("auto-review \(url, privacy: .public) exited \(status)")
            let review = (try? Data(contentsOf: reviewFile)).flatMap { try? JSONDecoder().decode(AgentReview.self, from: $0) }
            await self.finish(pr, review, logFile)
        }
    }

    private func finish(_ pr: PullRequest, _ review: AgentReview?, _ logFile: URL) async {
        await onFinished?(pr, review, logFile)
        running = false
        next()
    }

    private static func logURL(for pr: PullRequest) -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Stoplight")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("review-\(pr.repo.replacingOccurrences(of: "/", with: "-"))-\(pr.number).log")
    }

    /// Runs under the user's login shell, like `LoginShell.shell`, but with no 15s limit: agents take minutes.
    nonisolated private static func run(_ command: String, url: String, logFile: URL, reviewFile: URL) -> Int32 {
        let sh = LoginShell.loginShell
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sh.path)
        p.arguments = sh.args + [command]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginShell.extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["TERM"] = "dumb"
        env["STOPLIGHT_PR_URL"] = url
        env["STOPLIGHT_REVIEW_FILE"] = reviewFile.path
        env["STOPLIGHT_PROMPT"] = prompt(url, file: reviewFile.path)
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
