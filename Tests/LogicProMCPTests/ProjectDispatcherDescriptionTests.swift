import Foundation
import Testing
@testable import LogicProMCP

@Suite("ProjectDispatcher retained-repair discovery")
struct ProjectDispatcherDescriptionTests {
    @Test("repair discovery defers availability to the canonical preview, not an obsolete denylist")
    func retainedRepairHelpDescribesTheCurrentApprovalBoundary() throws {
        let description = try #require(ProjectDispatcher.tool.description)
        let start = try #require(description.range(of: "apply_session_repair ->"))
        let apply = String(description[start.upperBound...])
            .components(separatedBy: "cleanup_apply ->")[0]

        #expect(!apply.contains("Changed names, coupled naming repair, sort, unknown, expired and routing plans remain refused."))
        #expect(apply.contains("canonical preview"))
        for parameter in ["plan_id", "digest", "confirmed", "idempotency_key"] {
            #expect(apply.contains(parameter))
        }
    }
}
