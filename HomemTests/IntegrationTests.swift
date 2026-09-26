import XCTest
@testable import Homem

/// Run scripts/fixture-server.py before these tests. No production credentials needed.
@MainActor final class IntegrationTests: XCTestCase {
    func connectedClient() async throws -> APIClient {
        let url = URL(string: "http://127.0.0.1:18765/api")!
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15
        let api = APIClient(baseURL: url, session: URLSession(configuration: config))
        do { _ = try await api.session.data(from: URL(string: "http://127.0.0.1:18765/health")!) }
        catch {
            if ProcessInfo.processInfo.environment["CI_XCODE_CLOUD"] == "TRUE" { throw error }
            throw XCTSkip("Start scripts/fixture-server.py for wire integration tests: \(error.localizedDescription)")
        }
        let response = try await api.call("/auth/login", method: "POST", body: ["username": "fixture", "password": "fixture-password"])
        api.token = response["access_token"].string
        return api
    }
    func testNativeDesktopSurvivesIdleWithPingAndFragmentedFrames() async throws {
        let api = try await connectedClient()
        let socket = try await api.socket("/display-test/ws")
        let desktop = RuntimeDesktopConnection(socket: socket, heartbeatInterval: .milliseconds(150), pingTimeout: .seconds(2))
        let probe = DesktopFrameProbe()
        let task = Task { try await desktop.run { image in await probe.received(width: image.width, height: image.height) } }
        let deadline = Date().addingTimeInterval(5)
        while await probe.count < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        let count = await probe.count
        XCTAssertGreaterThanOrEqual(count, 3, "Quiet desktops must stay responsive through WebSocket pings")
        let size = await probe.size
        XCTAssertEqual(size, [2, 2])
        await desktop.close(); task.cancel()
        _ = await task.result
    }
    func testFirstMessageQueuedBeforeConnectionKeepsLocationAndAttachments() async throws {
        let api = try await connectedClient()
        let model = ChatModel(api: api, botID: "fixture-bot", sessionID: "fixture-session")
        let prompt = "New conversation \(UUID().uuidString)"
        let attachment: JSONValue = ["name": "note.txt", "type": "file", "mime": "text/plain", "base64": "data:text/plain;base64,aGk="]
        model.draft = prompt; model.workspaceTargetID = "studio-mac"
        let queued = await model.send(attachments: [attachment])
        XCTAssertTrue(queued); XCTAssertNil(model.error)
        await model.start(); defer { model.stop() }
        let deadline = Date().addingTimeInterval(20)
        while (!model.history.contains { $0["text"].string == prompt } || model.active), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let turns = model.history.filter { $0["text"].string == prompt }
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?["workspace_target_id"], "studio-mac")
        XCTAssertEqual(turns.first?["attachments"].array, [attachment])
        XCTAssertTrue(model.pending.isEmpty)
    }
    func testAvatarLoadsThroughPrivateAndCDNRedirects() async throws {
        let api = try await connectedClient()
        let url = URL(string: "http://127.0.0.1:18765/avatars/private")!
        var request = try XCTUnwrap(api.avatarRequest(url))
        request.setValue("fixture-team", forHTTPHeaderField: "X-Team-ID")
        request.setValue("session=fixture", forHTTPHeaderField: "Cookie")
        let data = try await AvatarImages.data(url, request: request)
        XCTAssertNotNil(AvatarImages.decode(data))
        // Mutating API traffic retains its stricter no-redirect behavior.
        let strictAPI = APIClient(baseURL: api.baseURL, token: api.token)
        let (_, response) = try await strictAPI.session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
    }
    func testRealHTTPAndStreamOperation() async throws {
        let api = try await connectedClient()
        let bots = try await api.call("/bots")
        XCTAssertEqual(bots.items.first?["id"], "fixture-bot")
        var events: [JSONValue] = []
        let result = try await api.streamOperation("/test/stream", method: "POST", body: [:]) { events.append($0) }
        XCTAssertEqual(events.map { $0["type"].string }, ["started", "step", "done"])
        XCTAssertEqual(result["id"], "fixture-install")
    }
    func testRealWebSocketAdmissionDeltaAndHistoryReconciliation() async throws {
        let api = try await connectedClient()
        let model = ChatModel(api: api, botID: "fixture-bot", sessionID: "fixture-session")
        await model.start(); defer { model.stop() }
        let readyDeadline = Date().addingTimeInterval(20)
        while model.connection != "Connected", Date() < readyDeadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(model.connection, "Connected")
        let initialCount = model.history.count
        let prompt = "A real URLSession WebSocket request \(UUID().uuidString)"
        model.draft = prompt
        let sent = await model.send(); XCTAssertTrue(sent)
        let deadline = Date().addingTimeInterval(20)
        while (model.history.count <= initialCount || model.active), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.history.contains { $0["messages"].array.first?["content"] == "Verified native WebSocket response." })
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertFalse(model.active)
        let users = model.visibleTurns.filter { $0["role"] == "user" && $0["text"].string == prompt }
        XCTAssertEqual(users.count, 1)
    }
}

private actor DesktopFrameProbe {
    var count = 0
    var size = [Int]()
    func received(width: Int, height: Int) { count += 1; size = [width, height] }
}
