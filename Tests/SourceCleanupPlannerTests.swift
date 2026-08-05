import XCTest
@testable import QuietReader

final class SourceCleanupPlannerTests: XCTestCase {
    func testKeepsEnabledCuratedAndBookshelfSources() {
        let removable = SourceCleanupPlanner.removableSourceIDs(
            allSourceIDs: ["enabled", "curated", "bookshelf", "unused"],
            enabledSourceIDs: ["enabled"],
            curatedSourceIDs: ["curated"],
            bookshelfSourceIDs: ["bookshelf"]
        )

        XCTAssertEqual(removable, ["unused"])
    }
}
