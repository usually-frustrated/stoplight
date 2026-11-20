import XCTest
@testable import StoplightCore

final class AgentReviewTests: XCTestCase {
    func testSplitsByConfidence() throws {
        let json = #"{"summary":"Two issues.","findings":[{"path":"a.swift","line":3,"confidence":"high","body":"Crash"},{"path":"b.swift","line":9,"confidence":"Medium","body":"Maybe"},{"path":"c.swift","line":1,"confidence":"low","body":"Nit"}]}"#
        let r = try JSONDecoder().decode(AgentReview.self, from: Data(json.utf8))
        XCTAssertEqual(r.posted.map(\.path), ["a.swift"])
        XCTAssertEqual(r.drafts.map(\.path), ["b.swift", "c.swift"])
        XCTAssertEqual(AgentReview.inline(r.posted, under: r.summary), "Two issues.\n- `a.swift:3` Crash")
    }
}
