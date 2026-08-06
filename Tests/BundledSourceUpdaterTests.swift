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

    func testRetiredBundledSourceIsDisabledDuringRefresh() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: BookSourceRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let oldDefinition = try definition(
            id: "archive.870ca07aea94fc8c54d0ef9e",
            timestamp: 1,
            searchURL: "/old"
        )
        let newDefinition = try definition(
            id: "archive.870ca07aea94fc8c54d0ef9e",
            timestamp: 2,
            searchURL: "/new",
            enabled: false
        )
        let record = try BookSourceRecord(definition: oldDefinition)
        record.enabled = true
        context.insert(record)
        try context.save()

        let updateCount = try BundledSourceUpdater.refreshExistingSources(
            in: context,
            definitions: [newDefinition]
        )

        XCTAssertEqual(updateCount, 1)
        XCTAssertFalse(record.enabled)
        XCTAssertEqual(record.definition?.searchUrl, "/new")
    }

    func testBundledPagedSourcesHaveCompletePaginationRules() throws {
        let sources = try BundledSourceUpdater.bundledDefinitions()
        let wolf = try XCTUnwrap(sources.first { $0.bookSourceName == "饿狼小说" })
        let forest = try XCTUnwrap(sources.first { $0.bookSourceName == "森林文学" })
        let b5200 = try XCTUnwrap(sources.first { $0.bookSourceName == "B5200" })

        for source in [wolf, forest] {
            XCTAssertEqual(
                source.ruleToc?.nextTocUrl,
                ".listpage a:containsOwn(下一页)@href"
            )
            XCTAssertEqual(
                source.ruleContent?.nextContentUrl,
                ".section-opt a:containsOwn(下一页)@href"
            )
        }
        XCTAssertFalse(b5200.isEnabled)
        XCTAssertEqual(b5200.groupName, "备用源 · 目录可能缺章")
    }

    private func definition(
        id: String = "bundled.test",
        timestamp: Int64,
        searchURL: String,
        enabled: Bool = true
    ) throws -> BookSourceDefinition {
        let data = try JSONSerialization.data(withJSONObject: [
            "sourceId": id,
            "bookSourceUrl": "https://example.com",
            "bookSourceName": "内置测试源",
            "bookSourceGroup": "内置",
            "enabled": enabled,
            "lastUpdateTime": timestamp,
            "searchUrl": searchURL,
            "ruleSearch": ["bookList": "$.data"]
        ])
        return try JSONDecoder().decode(BookSourceDefinition.self, from: data)
    }
}
