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

    func testTransientNetworkFailuresAreRetried() {
        XCTAssertTrue(SourceRequestRetryPolicy.shouldRetry(URLError(.timedOut)))
        XCTAssertTrue(SourceRequestRetryPolicy.shouldRetry(URLError(.networkConnectionLost)))
        XCTAssertTrue(SourceRequestRetryPolicy.shouldRetry(SourceEngineError.httpStatus(503)))
        XCTAssertFalse(SourceRequestRetryPolicy.shouldRetry(URLError(.cancelled)))
        XCTAssertFalse(SourceRequestRetryPolicy.shouldRetry(SourceEngineError.httpStatus(404)))
    }

    func testNetworkFailuresUseChineseMessages() {
        let timeout = SourceRequestRetryPolicy.userFacingError(for: URLError(.timedOut))
        let disconnected = SourceRequestRetryPolicy.userFacingError(
            for: URLError(.networkConnectionLost)
        )

        XCTAssertEqual(timeout.localizedDescription, "书源多次请求仍然超时，请稍后重试")
        XCTAssertEqual(
            disconnected.localizedDescription,
            "书源连接中断，多次请求仍未完整返回正文"
        )
    }
}
