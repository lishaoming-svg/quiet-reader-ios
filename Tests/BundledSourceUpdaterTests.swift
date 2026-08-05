import SwiftData
import XCTest
@testable import QuietReader

@MainActor
final class BundledSourceUpdaterTests: XCTestCase {
    func testUpdatesRulesButPreservesLocalSettings() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: BookSourceRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let oldDefinition = try definition(timestamp: 1, searchURL: "/old")
        let newDefinition = try definition(timestamp: 2, searchURL: "/new")
        let record = try BookSourceRecord(definition: oldDefinition)
        record.sourceName = "我的名称"
        record.sourceGroup = "我的分组"
        record.enabled = false
        context.insert(record)
        try context.save()

        let updateCount = try BundledSourceUpdater.refreshExistingSources(
            in: context,
            definitions: [newDefinition]
        )

        XCTAssertEqual(updateCount, 1)
        XCTAssertEqual(record.definition?.searchUrl, "/new")
        XCTAssertEqual(record.sourceName, "我的名称")
        XCTAssertEqual(record.sourceGroup, "我的分组")
        XCTAssertFalse(record.enabled)
    }

    private func definition(timestamp: Int64, searchURL: String) throws -> BookSourceDefinition {
        let data = try JSONSerialization.data(withJSONObject: [
            "sourceId": "bundled.test",
            "bookSourceUrl": "https://example.com",
            "bookSourceName": "内置测试源",
            "bookSourceGroup": "内置",
            "enabled": true,
            "lastUpdateTime": timestamp,
            "searchUrl": searchURL,
            "ruleSearch": ["bookList": "$.data"]
        ])
        return try JSONDecoder().decode(BookSourceDefinition.self, from: data)
    }
}
