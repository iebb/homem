import XCTest
@testable import Homem

@MainActor final class ChatQueueTests: XCTestCase {
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }
    private func model() -> ChatModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://queue.invalid/api")!, session: URLSession(configuration: config))
        return ChatModel(api: api, botID: "bot-a", sessionID: "session-a")
    }
    private func body(_ request: URLRequest) throws -> JSONValue {
        if let data = request.httpBody { return try JSONDecoder().decode(JSONValue.self, from: data) }
        guard let stream = request.httpBodyStream else { return .null }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    func testSendDuringRunQueuesTextAndRecoversExistingItems() async throws {
        let chat = model()
        chat.runtime.run = ["status": "running"]
        chat.draft = "  A follow-up  "
        var posts = 0
        StubURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.hasPrefix("/api/bots/bot-a/sessions/session-a/"))
            if request.httpMethod == "POST" {
                posts += 1
                XCTAssertTrue(request.url!.path.hasSuffix("/follow-up-queue"))
                let payload = try self.body(request)
                XCTAssertEqual(payload["text"], "A follow-up")
                XCTAssertFalse(payload["invocation_id"].string.isEmpty)
                return (200, try (["item_id": "queued", "text": "A follow-up", "status": "accepted", "position": 2] as JSONValue).encoded)
            }
            return (200, try (["steer_supported": true, "steer": [["item_id": "steering", "text": "Focus", "status": "claimed", "position": 1]], "follow_up": [["item_id": "queued", "text": "A follow-up", "status": "accepted", "position": 2]]] as JSONValue).encoded)
        }
        let sent = await chat.send()
        XCTAssertTrue(sent); XCTAssertEqual(posts, 1); XCTAssertTrue(chat.draft.isEmpty)
        XCTAssertTrue(chat.pending.isEmpty)
        XCTAssertEqual(chat.queue.items.map(\.itemID), ["steering", "queued"])
        XCTAssertFalse(chat.queue.items[0].editable)
        XCTAssertTrue(chat.queue.steerSupported)
        let restored = model()
        await restored.queue.refresh()
        XCTAssertEqual(restored.queue.items.map(\.itemID), ["steering", "queued"])
    }
    func testLostEnqueueResponseKeepsDraftAndRetriesSameInvocationAfterRunEnds() async throws {
        let chat = model(); chat.runtime.run = ["status": "running"]; chat.draft = "Keep this"
        var invocations: [String] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                invocations.append(try self.body(request)["invocation_id"].string)
                if invocations.count == 1 { throw URLError(.networkConnectionLost) }
                return (200, try (["item_id": "one", "status": "accepted", "text": "Keep this"] as JSONValue).encoded)
            }
            return (200, try (["follow_up": [["item_id": "one", "status": "accepted", "text": "Keep this"]]] as JSONValue).encoded)
        }
        let first = await chat.send()
        XCTAssertFalse(first); XCTAssertEqual(chat.draft, "Keep this"); XCTAssertNotNil(chat.queue.error)
        let reopened = model()
        reopened.draft = chat.draft
        let retry = await reopened.send()
        XCTAssertTrue(retry); XCTAssertEqual(invocations.count, 2); XCTAssertEqual(invocations[0], invocations[1])
        XCTAssertEqual(reopened.queue.items.count, 1); XCTAssertTrue(reopened.pending.isEmpty)
    }
    func testQueueRejectsAttachmentsWithoutSendingOrClearingDraft() async {
        let chat = model(); chat.runtime.run = ["status": "running"]; chat.draft = "Keep my file"
        StubURLProtocol.handler = { _ in XCTFail("The queue cannot carry attachments"); return (500, Data()) }
        let sent = await chat.send(attachments: [["name": "note.txt"]])
        XCTAssertFalse(sent); XCTAssertEqual(chat.draft, "Keep my file"); XCTAssertNotNil(chat.queue.error)
        XCTAssertTrue(chat.queue.items.isEmpty)
    }
    func testQueueManagementUsesTypedReferencesAndSeparatesSteering() async throws {
        let queue = model().queue
        let a: JSONValue = ["item_id": "a", "status": "accepted", "text": "First", "position": 1]
        let b: JSONValue = ["item_id": "b", "status": "accepted", "text": "Second", "position": 2]
        var mutations: [(String, String, JSONValue)] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod != "GET" { mutations.append((request.httpMethod!, request.url!.path, try self.body(request))) }
            return (200, try (["steer_supported": true, "follow_up": .array([a, b]), "steer": []] as JSONValue).encoded)
        }
        await queue.refresh()
        let item = queue.items[0]
        await queue.update(item, text: "Edited")
        await queue.move(item, by: 1)
        await queue.steer(item)
        await queue.remove(item)
        XCTAssertEqual(mutations.map { $0.0 }, ["PATCH", "PUT", "POST", "DELETE"])
        XCTAssertEqual(mutations[0].2, ["text": "Edited"])
        XCTAssertEqual(mutations[1].2, ["item": ["item_id": "a"], "before": ["item_id": ""]])
        XCTAssertTrue(mutations[2].1.hasSuffix("/follow-up-queue/a/steer"))
        XCTAssertTrue(mutations[3].1.hasSuffix("/follow-up-queue/a"))
    }
    func testFailedRefreshRetainsVisibleQueueAndFailedMutationShowsError() async throws {
        let queue = model().queue
        queue.items = [ChatQueuedMessage(value: ["item_id": "one", "status": "accepted", "text": "Queued"], kind: .followUp)]
        StubURLProtocol.handler = { request in (request.httpMethod == "GET" ? 503 : 409, Data("{}".utf8)) }
        await queue.refresh()
        XCTAssertEqual(queue.items.count, 1)
        await queue.remove(queue.items[0])
        XCTAssertNotNil(queue.error); XCTAssertEqual(queue.items.count, 1); XCTAssertTrue(queue.busy.isEmpty)
    }
}
