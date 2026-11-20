import Foundation

/// What an auto-review agent writes to $STOPLIGHT_REVIEW_FILE (format in skills/stoplight-review/SKILL.md).
public struct AgentReview: Decodable, Sendable, Equatable {
    public struct Finding: Decodable, Sendable, Equatable {
        public let path: String
        public let line: Int
        public let confidence: String
        public let body: String
        public init(path: String, line: Int, confidence: String, body: String) {
            self.path = path; self.line = line; self.confidence = confidence; self.body = body
        }
        public var isHigh: Bool { confidence.lowercased() == "high" }
    }
    public let summary: String
    public let findings: [Finding]

    public init(summary: String, findings: [Finding]) { self.summary = summary; self.findings = findings }

    /// High confidence gets posted; medium and low become drafts (a pending review).
    public var posted: [Finding] { findings.filter(\.isHigh) }
    public var drafts: [Finding] { findings.filter { !$0.isHigh } }

    /// Findings as review-body text, for when GitHub rejects inline comments (a line outside the diff).
    public static func inline(_ findings: [Finding], under summary: String) -> String {
        ([summary] + findings.map { "- `\($0.path):\($0.line)` \($0.body)" }).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
