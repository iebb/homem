import XCTest
@testable import Homem

final class CoreTests: XCTestCase {
    func testScheduleRepeatPreservesComplexPatternsAndSupportsVisualPresets() {
        for pattern in ["*/15 * * * *", "12 * * * *", "30 9 * * *", "30 9 * * 1,3,5", "15 8 31 * *"] {
            let rule = ScheduleRepeat(pattern: pattern)
            XCTAssertNotEqual(rule.frequency, .custom)
            XCTAssertEqual(rule.pattern, pattern)
        }
        for pattern in ["0 0 9 * * MON-FRI", "CRON_TZ=UTC 0 9 * * *", "@every 2h", "0 9 * * 1-5", "5,10 * * * *", "0 9 * * 7"] {
            let rule = ScheduleRepeat(pattern: pattern)
            XCTAssertEqual(rule.frequency, .custom)
            XCTAssertEqual(rule.pattern, pattern)
        }
        var weekly = ScheduleRepeat(pattern: "0 9 * * 1")
        weekly.weekdays = []
        var draft = ScheduleDraft(["name": "Test", "command": "Check updates"])
        draft.repeatRule = weekly
        XCTAssertFalse(draft.canSave)
    }
    func testScheduleUpdatePreservesExecutionAndExplicitlyClearsLimit() {
        var draft = ScheduleDraft(["name": "Morning", "command": "Check updates", "pattern": "0 9 * * *", "max_calls": 5,
                                   "run_target": "new_session", "bot_agent_id": "coding", "runtime_type": "codex", "acp_model_id": "custom-model"])
        draft.name = "Evening"
        XCTAssertTrue(draft.body(editing: true)["execution"].isNull)
        XCTAssertNil(draft.body(editing: true).object["max_calls"])
        draft.limited = false
        XCTAssertEqual(draft.body(editing: true).object["max_calls"], .null)
        draft.changeTarget("existing_session")
        XCTAssertFalse(draft.canSave)
        draft.selectSession("chat-1")
        draft.execution["model_id"] = "previous-model"
        draft.selectSession("chat-2")
        XCTAssertTrue(draft.execution["model_id"].isNull)
        draft.selectSession("chat-1")
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.body(editing: true)["execution"], ["run_target": "existing_session", "target_session_id": "chat-1"])
        XCTAssertTrue(draft.body(editing: true)["run_target"].isNull)
        let create = draft.body(editing: false)
        XCTAssertEqual(create["target_session_id"], "chat-1")
        XCTAssertTrue(create["execution"].isNull)
        draft.changeTarget("new_session")
        draft.execution["model_id"] = "native"
        draft.execution["reasoning_effort"] = "high"
        draft.selectAgent("external")
        XCTAssertEqual(draft.body(editing: false)["bot_agent_id"], "external")
        XCTAssertTrue(draft.body(editing: false)["model_id"].isNull)
        XCTAssertTrue(draft.body(editing: false)["reasoning_effort"].isNull)
    }
    func testConversationAgentIdentitySupportsCurrentAndLegacySessions() {
        XCTAssertEqual(ChatAgentType.session(["type": "chat"]), .memoh)
        XCTAssertEqual(ChatAgentType.session(["runtime_type": "codex"]), .codex)
        XCTAssertEqual(ChatAgentType.session(["runtime_type": "claude-code"]), .claudeCode)
        XCTAssertEqual(ChatAgentType.session(["type": "acp_agent", "metadata": ["acp_agent_id": "codex"]]), .codex)
        XCTAssertEqual(ChatAgentType.session(["runtime_type": "acp_agent", "runtime_metadata": ["acp_agent_id": "custom-agent"]]), .acp)
    }
    func testNewConversationUsesEnabledAgentIDAndRuntimeContract() {
        let catalog: JSONValue = ["items": [
            ["id": "codex-1", "name": "Coding", "runtime": "codex", "enabled": true],
            ["id": "claude-1", "name": "Review", "runtime": "claude-code", "enabled": true],
            ["id": "acp-1", "name": "Research", "runtime": "acp", "metadata": ["provider": "custom-acp"]],
            ["id": "disabled", "runtime": "codex", "enabled": false],
            ["id": "future", "runtime": "unknown", "enabled": true]
        ]]
        let agents = ConversationAgent.enabled(in: catalog)
        XCTAssertEqual(agents.map(\.id), ["codex-1", "claude-1", "acp-1"])
        XCTAssertEqual(agents[0].sessionBody(title: "Hello")["bot_agent_id"], "codex-1")
        XCTAssertEqual(agents[0].sessionBody(title: "Hello")["runtime_type"], "codex")
        XCTAssertEqual(agents[1].sessionBody(title: "Hello")["runtime_type"], "claude-code")
        let acp = agents[2].sessionBody(title: "Hello", settings: ["default_bot_agent_id": "acp-1", "chat_acp_project_path": "/data/project"])
        XCTAssertEqual(acp["runtime_type"], "acp_agent")
        XCTAssertEqual(acp["runtime_metadata"]["acp_agent_id"], "custom-acp")
        XCTAssertEqual(acp["runtime_metadata"]["project_path"], "/data/project")
        XCTAssertEqual(acp["runtime_metadata"]["acp_project_mode"], "project")
        let native = ConversationAgent.memoh.sessionBody(title: "Hello")
        XCTAssertEqual(native["runtime_type"], "model")
        XCTAssertTrue(native["bot_agent_id"].isNull)
        XCTAssertEqual(native["type"], "chat")
    }
    func testAgentSettingsChangesPreserveFalseAndExplicitClears() {
        let original: JSONValue = ["search_provider_id": "old-provider", "display_enabled": true, "language": "en", "read_only_id": "unchanged"]
        let draft: JSONValue = ["search_provider_id": "", "display_enabled": false, "language": "en", "read_only_id": "changed", "chat_model_id": .null]
        let patch = AgentSettingsFields.changes(from: original, to: draft, allowed: ["search_provider_id", "display_enabled", "language", "chat_model_id"])
        XCTAssertEqual(patch, ["search_provider_id": "", "display_enabled": false])
        XCTAssertTrue(AgentSettingsFields.changes(from: original, to: original, allowed: ["display_enabled"]).object.isEmpty)
    }
    func testAgentSettingsPickerKeepsSelectedDisabledModelAndFiltersIncompatibleModels() {
        let rows: [JSONValue] = [
            ["id": "chat", "name": "Chat model", "type": "chat", "enable": true],
            ["id": "image", "name": "Image model", "type": "chat", "config": ["compatibilities": ["image-output"]]],
            ["id": "embedding", "name": "Embedding", "type": "embedding"],
            ["id": "disabled", "name": "Previous model", "type": "chat", "enable": false],
            ["id": "other-disabled", "name": "Disabled model", "type": "chat", "enable": false]
        ]
        XCTAssertEqual(Set(AgentSettingsFields.options(rows, key: "chat_model_id", selected: "disabled").map(\.id)), ["chat", "image", "disabled"])
        XCTAssertEqual(AgentSettingsFields.options(rows, key: "image_model_id", selected: "").map(\.id), ["image"])
        XCTAssertEqual(AgentSettingsFields.source("search_provider_id", botID: "bot"), "/search-providers")
        XCTAssertEqual(AgentSettingsFields.source("default_bot_agent_id", botID: "bot"), "/bots/bot/agents")
        XCTAssertEqual(AgentSettingsFields.source("tts_model_id", botID: "bot"), "/speech-models")
    }

    func testAvatarSourcesSupportOfficialAndCustomHosts() {
        let base = URL(string: "https://selfhost.example/api")!
        XCTAssertEqual(AvatarSource.url("/avatars/one.png", baseURL: base)?.absoluteString, "https://selfhost.example/avatars/one.png")
        XCTAssertEqual(AvatarSource.url("https://cdn.example/bot.png", baseURL: base)?.host, "cdn.example")
        XCTAssertNil(AvatarSource.url("", baseURL: base))
        XCTAssertNil(AvatarSource.url("file:///etc/passwd", baseURL: base))
        XCTAssertNil(AvatarSource.url("https://user:password@example.com/icon.png", baseURL: base))
        XCTAssertEqual(AvatarSource.initials("  Kitta Studio "), "KS")
        XCTAssertEqual(AvatarSource.initials("小猫"), "小")
    }
    @MainActor func testAvatarImageDecodingAndInvalidImageFallback() async throws {
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNQSnv3HwAEmgJ2pp70QwAAAABJRU5ErkJggg=="
        let image = try await AvatarImages.load(XCTUnwrap(URL(string: png)))
        XCTAssertNotNil(image)
        let invalid = try await AvatarImages.load(XCTUnwrap(URL(string: "data:image/png;base64,bm90LWFuLWltYWdl")))
        XCTAssertNil(invalid)
    }
    func testJSONRoundTripPreservesPluginConfiguration() throws {
        let value = try JSONValue.parse(#"{"config":{"args":["--safe",3,true,null],"日本語":"記憶"},"number":1.25}"#)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: value.encoded), value)
    }
    func testSSESupportsMultilineAndIgnoresHeartbeat() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(": heartbeat")); XCTAssertNil(parser.consume(""))
        XCTAssertNil(parser.consume("event: progress"))
        XCTAssertNil(parser.consume("data: {\"type\": \"step\","))
        XCTAssertNil(parser.consume("data: \"message\": \"Installing\"}"))
        XCTAssertEqual(parser.consume(""), "{\"type\": \"step\",\n\"message\": \"Installing\"}")
        XCTAssertNil(parser.consume(""))
    }
    func testSSEByteFramesPreserveBlankLinesAndUnicode() {
        for separator in ["\n", "\r\n", "\r"] {
            var parser = SSEParser()
            let wire = "data: {\"type\":\"step\",\"message\":\"日本語\"}\(separator)\(separator)data: {\"type\":\"done\"}\(separator)\(separator)"
            let events = wire.utf8.compactMap { parser.consume(byte: $0) }
            XCTAssertEqual(events, ["{\"type\":\"step\",\"message\":\"日本語\"}", "{\"type\":\"done\"}"])
        }
    }
    @MainActor func testURLBasePathAndEscaping() throws {
        let api = APIClient(baseURL: try APIClient.normalizedURL("https://example.com/memoh/api/"), token: "secret")
        let request = try api.request("/bots/" + "a/b?#".pathComponent + "/messages", query: ["session_id": "a&b +日本"])
        XCTAssertEqual(request.url?.path, "/memoh/api/bots/a/b?#/messages")
        XCTAssertTrue(request.url!.absoluteString.contains("a%2Fb%3F%23"))
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b +日本")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }
    @MainActor func testRejectsCredentialURLsAndForeignEndpoints() throws {
        for url in ["file:///etc/passwd", "https://u:p@example.com", "https://example.com?token=x", "example.com", "https://example.com/#x"] { XCTAssertThrowsError(try APIClient.normalizedURL(url)) }
        let api = APIClient(baseURL: URL(string: "https://example.com")!)
        XCTAssertThrowsError(try api.request("https://other.com"))
        XCTAssertThrowsError(try api.request("/../other"))
    }
    func testRuntimeReplayAndRecovery() throws {
        var state = RuntimeState()
        state.apply(snapshot)
        let delta: JSONValue = ["type": "runtime_delta", "session_id": "s", "epoch": "e", "seq": 2, "delta": ["message_appends": [["id": 1, "type": "text", "content": " world"]]]]
        state.apply(delta); state.apply(delta)
        XCTAssertEqual(state.messages[0]["content"], "Hello world")
        var gap = delta; gap["seq"] = 4; state.apply(gap)
        XCTAssertTrue(state.needsSnapshot)
        var late = delta; late["seq"] = 3; state.apply(late)
        XCTAssertEqual(state.sequence, 2)
        state.apply(snapshot); XCTAssertFalse(state.needsSnapshot)
        XCTAssertEqual(state.messages[0]["content"], "Hello")
    }
    func testConversationSpinnerFollowsRunLifecycle() {
        var state = ConversationRunState()
        XCTAssertFalse(state.active)
        XCTAssertFalse(state.apply(["type": "runtime_snapshot", "snapshot": ["epoch": "e", "seq": 1, "current_run_view": ["status": "running"]]]))
        XCTAssertTrue(state.active)
        for (index, status) in ["waiting_decision", "aborting", "finishing", "completed"].enumerated() {
            XCTAssertFalse(state.apply(["type": "runtime_delta", "epoch": "e", "seq": .number(Double(index + 2)), "delta": ["run": ["status": .string(status)]]]))
            XCTAssertEqual(state.active, status != "completed")
        }
        XCTAssertFalse(state.apply(["type": "runtime_delta", "epoch": "e", "seq": 6, "delta": ["current_run_view": ["status": "admitting"]]]))
        XCTAssertTrue(state.active)
        XCTAssertFalse(state.apply(["type": "runtime_delta", "epoch": "e", "seq": 7, "delta": ["current_run_view": .null]]))
        XCTAssertFalse(state.active)
    }
    func testConversationSpinnerRecoversFromGapsAndIgnoresReplay() {
        var state = ConversationRunState()
        let initial: JSONValue = ["type": "runtime_snapshot", "snapshot": ["epoch": "e", "seq": 2, "current_run_view": ["status": "running"]]]
        _ = state.apply(initial)
        XCTAssertFalse(state.apply(["type": "runtime_delta", "epoch": "e", "seq": 1, "delta": ["current_run_view": .null]]))
        XCTAssertTrue(state.active)
        XCTAssertTrue(state.apply(["type": "runtime_delta", "epoch": "e", "seq": 4, "delta": ["current_run_view": .null]]))
        XCTAssertFalse(state.apply(["type": "runtime_dropped"])) // Only request recovery once.
        XCTAssertFalse(state.apply(["type": "runtime_snapshot", "snapshot": ["epoch": "new", "seq": 10, "current_run_view": .null]]))
        XCTAssertFalse(state.active)
        XCTAssertTrue(state.apply(["type": "runtime_delta", "epoch": "e", "seq": 11, "delta": ["run": ["status": "running"]]]))
        XCTAssertFalse(state.active)
    }
    func testRuntimeUpsertWinsOverAppendAndClearsRun() {
        var state = RuntimeState(); state.apply(snapshot)
        state.apply(["type": "runtime_delta", "epoch": "e", "seq": 2, "delta": ["message_appends": [["id": 1, "type": "text", "content": " there"]], "message_upserts": [["id": 1, "type": "text", "content": "Authoritative"]]]])
        XCTAssertEqual(state.messages[0]["content"], "Authoritative")
        state.apply(["type": "runtime_delta", "epoch": "e", "seq": 3, "delta": ["current_run_view": .null]])
        XCTAssertFalse(state.active); XCTAssertTrue(state.messages.isEmpty)
    }
    func testSchemaValidationPreventsMalformedWrites() throws {
        let schema: JSONValue = ["type": "object", "required": ["name"], "properties": ["name": ["type": "string"], "limit": ["type": "integer", "minimum": 1], "config": ["type": "object"]]]
        XCTAssertThrowsError(try SchemaCatalog.shared.validate(["limit": 4], schema: schema))
        XCTAssertThrowsError(try SchemaCatalog.shared.validate(["name": "Test", "limit": "abc"], schema: schema))
        XCTAssertThrowsError(try SchemaCatalog.shared.validate(["name": "Test", "limit": 0], schema: schema))
        XCTAssertThrowsError(try SchemaCatalog.shared.validate(["name": "Test", "config": "{"], schema: schema))
        XCTAssertNoThrow(try SchemaCatalog.shared.validate(["name": "Test", "config": ["enabled": true]], schema: schema))
    }
    func testBundledContractIncludesCoreOperations() {
        let catalog = SchemaCatalog.shared
        XCTAssertGreaterThan(catalog.operations.count, 300)
        for (path, method) in [("/bots", "POST"), ("/bots/{bot_id}/schedule", "POST"), ("/bots/{bot_id}/memory/{memory_id}", "PUT"), ("/bots/{bot_id}/container/fs/write", "POST"), ("/providers", "POST")] { XCTAssertNotNil(catalog.operation(path, method)) }
    }
    @MainActor func testDemoWritesAreIsolatedAndUnsupportedActionsFail() throws {
        let demo = DemoServer()
        let created = try demo.call("/bots/atlas/schedule", method: "POST", query: [:], body: ["name": "Test", "pattern": "0 9 * * *"])
        XCTAssertFalse(created["id"].string.isEmpty)
        _ = try demo.call("/bots/atlas/schedule/" + created["id"].string, method: "DELETE", query: [:], body: nil)
        XCTAssertEqual(demo.collections["/bots/atlas/schedule"]?.count, 1)
        XCTAssertThrowsError(try demo.call("/bots/atlas/container/start", method: "POST", query: [:], body: nil))
    }
    var snapshot: JSONValue { ["type": "runtime_snapshot", "session_id": "s", "snapshot": ["epoch": "e", "seq": 1, "current_run_view": ["run_id": "r", "status": "running", "turn_id": "t", "messages": [["id": 1, "type": "text", "content": "Hello"]]]]] }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var responseHeaders: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let (status, data) = try Self.handler!(request); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: Self.responseHeaders.merging(["Content-Type": "application/json"]) { old, _ in old })!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class NetworkingTests: XCTestCase {
    func client(token: String = "") -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        return APIClient(baseURL: URL(string: "https://test.invalid/api")!, token: token, session: URLSession(configuration: config))
    }
    func testHTTPErrorPreservesServerMessage() async {
        StubURLProtocol.handler = { _ in (403, Data(#"{"message":"Manage permission required"}"#.utf8)) }
        do { _ = try await client().call("/bots"); XCTFail("Expected 403") } catch { XCTAssertTrue(error.localizedDescription.contains("Manage permission required")) }
    }
    func testHTMLProxyResponseIsNotSuccess() async {
        StubURLProtocol.handler = { _ in (200, Data("<html>Login</html>".utf8)) }
        do { _ = try await client().call("/bots"); XCTFail("Expected invalid response") } catch { XCTAssertTrue(error.localizedDescription.contains("API base")) }
    }
    func testTokenRefreshRetriesWithNewBearer() async throws {
        var requests = 0
        StubURLProtocol.handler = { req in
            requests += 1
            if req.url!.path.hasSuffix("/auth/refresh") { return (200, Data(#"{"access_token":"new-token"}"#.utf8)) }
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer new-token" { return (200, Data(#"{"items":[]}"#.utf8)) }
            return (401, Data(#"{"message":"expired"}"#.utf8))
        }
        let api = client(token: "expired"); _ = try await api.call("/bots")
        XCTAssertEqual(api.token, "new-token"); XCTAssertEqual(requests, 3)
        try Keychain.save(nil, account: api.baseURL.absoluteString)
    }
}
