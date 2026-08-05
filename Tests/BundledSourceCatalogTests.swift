import XCTest
@testable import QuietReader

final class BundledSourceCatalogTests: XCTestCase {
    func testCatalogIndexAndShardedDefinitionLoad() async throws {
        let catalog = BundledSourceCatalog(bundle: .main)
        let index = try await catalog.loadIndex()

        XCTAssertGreaterThan(index.sourceCount, 25_000)
        XCTAssertEqual(index.entries.count, index.sourceCount)
        XCTAssertEqual(index.shardCount, 64)
        let entry = try XCTUnwrap(index.entries.first { $0.status == .compatible })
        let definitions = try await catalog.loadDefinitions(ids: [entry.id])
        let definition = try XCTUnwrap(definitions.first)
        XCTAssertEqual(definition.id, entry.id)
        XCTAssertEqual(definition.bookSourceName, entry.name)
        XCTAssertFalse(definition.isEnabled)
    }
}
