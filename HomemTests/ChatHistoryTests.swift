import XCTest
@testable import Homem

@MainActor final class ChatHistoryTests: XCTestCase {
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    private func model() -> ChatModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ChatModel(api: APIClient(baseURL: URL(string: "https://history.invalid/api")!, session: URLSession(configuration: config)), botID: "bot", sessionID: "session")
    }
    private func turn(_ id: Int, text: String = "Original") -> JSONValue {
        ["id": .number(Double(id)), "turn_id": .string("turn-\(id)"), "role": "user", "turn_position": .number(Double(id)), "text": .string(text)]
    }
    func testLoadingOlderMessagesDoesNotChangeLatestTurnOrDuplicateBoundary() async throws {
        let chat = model()
        chat.history = [turn(3), turn(4)]
        let latest = chat.latestTurnID
        StubURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "before_message_id" }?.value, "3")
            return (200, try JSONValue.array([self.turn(3), self.turn(2), self.turn(1)]).encoded)
        }
        await chat.loadHistory(older: true)
        XCTAssertEqual(chat.history.map { $0["turn_id"].string }, ["turn-1", "turn-2", "turn-3", "turn-4"])
        XCTAssertEqual(chat.latestTurnID, latest)
        XCTAssertFalse(chat.hasMore)
    }
    func testReconnectPreservesEarlierPagesAndReplacesEditedTail() async throws {
        let chat = model()
        chat.history = (1...60).map { turn($0) }
        chat.hasMore = true
        StubURLProtocol.handler = { _ in (200, try JSONValue.array((11...61).map { self.turn($0, text: "Updated") }).encoded) }
        await chat.loadHistory()
        XCTAssertEqual(chat.history.count, 61)
        XCTAssertEqual(chat.history.first?["turn_id"], "turn-1")
        XCTAssertEqual(chat.history[10]["text"], "Updated")
        XCTAssertEqual(chat.history.last?["turn_id"], "turn-61")
        XCTAssertTrue(chat.hasMore)
    }
    func testRefreshRemovesTurnsTruncatedByRetry() async throws {
        let chat = model()
        chat.history = (1...6).map { turn($0) }
        StubURLProtocol.handler = { _ in (200, try JSONValue.array([self.turn(3), self.turn(4, text: "Retried")]).encoded) }
        await chat.loadHistory()
        XCTAssertEqual(chat.history.map { $0["turn_id"].string }, ["turn-1", "turn-2", "turn-3", "turn-4"])
        XCTAssertEqual(chat.history.last?["text"], "Retried")
    }
    func testRefreshWithNoOverlapReplacesHistory() async throws {
        let chat = model()
        chat.history = [turn(1)]
        StubURLProtocol.handler = { _ in (200, try JSONValue.array([self.turn(100)]).encoded) }
        await chat.loadHistory()
        XCTAssertEqual(chat.history, [turn(100)])
        XCTAssertFalse(chat.loading)
        XCTAssertFalse(chat.hasMore)
    }
    func testFailureRetainsHistoryAndAllowsRetry() async throws {
        let chat = model()
        chat.history = [turn(1)]
        StubURLProtocol.handler = { _ in (503, Data("{}".utf8)) }
        await chat.loadHistory(older: true)
        XCTAssertEqual(chat.history, [turn(1)])
        XCTAssertNotNil(chat.error)
        XCTAssertFalse(chat.loading)
        StubURLProtocol.handler = { _ in (200, try JSONValue.array([self.turn(1), self.turn(2)]).encoded) }
        await chat.loadHistory()
        XCTAssertNil(chat.error)
        XCTAssertEqual(chat.history.count, 2)
    }
    func testEmptyRefreshClearsRemovedConversation() async throws {
        let chat = model()
        chat.history = [turn(1)]
        StubURLProtocol.handler = { _ in (200, try JSONValue.array([]).encoded) }
        await chat.loadHistory()
        XCTAssertTrue(chat.history.isEmpty)
        XCTAssertNil(chat.latestTurnID)
        XCTAssertFalse(chat.hasMore)
    }
}
