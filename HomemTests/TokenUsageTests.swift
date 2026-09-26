import XCTest
@testable import Homem

final class TokenUsageTests: XCTestCase {
    func testRequiredDateRangeIncludesTodayWithExclusiveEndAcrossLeapDay() throws {
        let now = try XCTUnwrap("2024-03-01T23:50:00Z".wireDate)
        let period = TokenUsagePeriod(days: 7, now: now)
        XCTAssertEqual(period.query, ["from": "2024-02-24", "to": "2024-03-02"])
        let oneDay = TokenUsagePeriod(days: 1, now: now)
        XCTAssertEqual(oneDay.query, ["from": "2024-03-01", "to": "2024-03-02"])
    }
    @MainActor func testUsageRequestEncodesMandatoryRange() throws {
        let api = APIClient(baseURL: URL(string: "https://memoh.example/api")!, token: "test")
        let query = TokenUsagePeriod(days: 30, now: try XCTUnwrap("2026-09-18T23:59:00Z".wireDate)).query
        let request = try api.request("/bots/example/token-usage", query: query)
        let parts = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/api/bots/example/token-usage")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "from", value: "2026-08-20"), URLQueryItem(name: "to", value: "2026-09-19")])
    }
    func testDailyUsageCombinesBucketsWithoutDoubleCountingModelsOrCachedTokens() {
        let summary = TokenUsageSummary([
            "chat": [["day": "2026-09-17", "input_tokens": 100, "output_tokens": 20, "cache_read_tokens": 50, "reasoning_tokens": 10]],
            "discuss": [["day": "2026-09-17", "input_tokens": 30, "output_tokens": 5]],
            "acp_agent": [["day": "2026-09-18", "input_tokens": 40, "output_tokens": 10]],
            "schedule": [["day": "2026-09-17", "input_tokens": 20, "output_tokens": 5]],
            "by_model": [["model_name": "Example", "input_tokens": 190, "output_tokens": 40]]
        ])
        XCTAssertEqual(summary.days.map(\.id), ["2026-09-17", "2026-09-18"])
        XCTAssertEqual(summary.days.map(\.total), [180, 50])
        XCTAssertEqual(summary.input, 190)
        XCTAssertEqual(summary.output, 40)
        XCTAssertEqual(summary.total, 230)
        XCTAssertEqual(TokenUsageSummary(["chat": .null, "by_model": .null]).total, 0)
    }
}
