import XCTest
@testable import QuietReader

final class SourceResponseGuardTests: XCTestCase {
    func testAnonymousQuotaMessageRequiresAuthentication() {
        let message = "您今日免登录访问次数已达上限(3次)！继续阅读请登录后刷新页面。"

        XCTAssertEqual(SourceEngine.authenticationMessage(in: message), message)
        let error = SourceEngineError.authenticationRequired(message)
        XCTAssertTrue(error.requiresAuthentication)
        XCTAssertEqual(error.localizedDescription, message)
    }

    func testNormalChapterIsNotAuthenticationMessage() {
        XCTAssertNil(SourceEngine.authenticationMessage(in: "第一章的正常正文。"))
    }
}
