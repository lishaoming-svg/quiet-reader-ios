import Combine
import Foundation
import XCTest
@testable import QuietReader

final class SourcePerformanceAndLofterTests: XCTestCase {
    private func source(_ name: String = "LOFTER") throws -> BookSourceDefinition {
        try JSONDecoder().decode(BookSourceDefinition.self, from: Data("{\"bookSourceName\":\"\(name)\",\"bookSourceUrl\":\"https://api.lofter.com/\",\"sourceId\":\"\(name)\",\"searchUrl\":\"@js:LF.search(key,page)\"}".utf8))
    }
    @MainActor
    func testFastSourceAppearsBeforeSlowSourceAndResultsRemainRanked() async throws {
        let gate = SearchGate()
        let fast = try source("fast"), slow = try source("slow")
        let result = SearchBook(sourceID: fast.id, sourceName: "fast", name: "海风", author: "作者", intro: "", kind: "", lastChapter: "", updateTime: "", bookURL: "https://example.org/book", coverURL: "", tocURL: "")
        let model = SearchViewModel { _, source in
            if source.id == "slow" { await gate.wait(); return [] }
            return [result]
        }
        let visible = expectation(description: "快速书源已显示")
        var delivered = false
        let token = model.$results.sink { values in
            if !values.isEmpty && !delivered { delivered = true; visible.fulfill() }
        }
        let search = Task { await model.search(keyword: "海风", sources: [slow, fast]) }
        await fulfillment(of: [visible], timeout: 3)
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.results, [result])
        await gate.release(); await search.value
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.completedSources, 2)
        withExtendedLifetime(token) {}
    }
    @MainActor
    func testNewSearchCannotBeOverwrittenByAnOlderResponse() async throws {
        let gate = SearchGate(), source = try source()
        let started = expectation(description: "旧查询已开始")
        let model = SearchViewModel { keyword, _ in
            if keyword == "旧查询" { started.fulfill(); await gate.wait() }
            return []
        }
        let old = Task { await model.search(keyword: "旧查询", sources: [source]) }
        await fulfillment(of: [started], timeout: 3)
        await model.search(keyword: "新查询", sources: [source])
        await gate.release(); await old.value
        XCTAssertEqual(model.searchedKeyword, "新查询")
        XCTAssertEqual(model.errorMessage, "没有找到“新查询”")
    }
    func testCollectionSearchEscapesKeywordAndRecognizesSource() throws {
        XCTAssertTrue(NativeLofterAdapter.accepts(try source()))
        let address = NativeLofterAdapter.searchAddress("#合集 & 中文", page: 2)
        XCTAssertTrue(address.contains("newsearch/collection.json"))
        XCTAssertEqual(NativeLofterAdapter.fields(in: address)["key"], "合集 & 中文")
        XCTAssertEqual(NativeLofterAdapter.fields(in: address)["offset"], "20")
    }
    func testCollectionLoadsPastIncorrectNegativeOffsetAndDeduplicatesChapters() async throws {
        let adapter = NativeLofterAdapter(source: try source(), transport: { address in
            let offset = NativeLofterAdapter.fields(in: address)["offset"] ?? "0"
            let rows = offset == "0" ? "{\"id\":11,\"blogId\":7,\"title\":\"第一章\"},{\"id\":12,\"blogId\":7,\"title\":\"第二章\"}" : "{\"id\":13,\"blogId\":7,\"title\":\"第三章\"}"
            return Data("{\"meta\":{\"status\":200},\"response\":{\"offset\":-1,\"collection\":{\"id\":8,\"blogId\":7,\"postCount\":3},\"items\":[\(rows)]}}".utf8)
        })
        let book = SearchBook(sourceID: adapter.source.id, sourceName: "LOFTER", name: "测试合集", author: "", intro: "", kind: "合集", lastChapter: "", updateTime: "", bookURL: NativeLofterAdapter.collection(blog: "7", id: "8", offset: 0), coverURL: "", tocURL: "")
        let chapters = try await adapter.chapters(book)
        XCTAssertEqual(chapters.map(\.title), ["第一章", "第二章", "第三章"])
        XCTAssertEqual(chapters.map(\.index), [0, 1, 2])
    }
    func testNativeAdapterRejectsOtherHostsAndDoesNotRunImportedScripts() async throws {
        let adapter = NativeLofterAdapter(source: try source(), transport: { _ in XCTFail("不应发出请求"); return Data() })
        do { _ = try await adapter.request("https://example.com/private"); XCTFail("应拒绝其他域名") }
        catch { XCTAssertTrue(error is SourceEngineError) }
        do { _ = try await adapter.request("https://api.lofter.com/arbitrary-script"); XCTFail("应拒绝未知接口") }
        catch { XCTAssertTrue(error is SourceEngineError) }
    }
}
private actor SearchGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}
