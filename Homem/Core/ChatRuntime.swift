import Foundation
import Observation

struct RuntimeState {
    var epoch = ""
    var sequence: Double = 0
    var run: JSONValue = .null
    var needsSnapshot = false
    var messages: [JSONValue] { run["messages"].array }
    var active: Bool { Self.isActive(run["status"].string) }
    static func isActive(_ status: String) -> Bool { ["admitting", "running", "waiting_decision", "aborting", "finishing"].contains(status) }
    mutating func apply(_ event: JSONValue) {
        if event["type"] == "runtime_dropped" { needsSnapshot = true; return }
        if event["type"] == "runtime_snapshot" {
            needsSnapshot = false
            let snap = event["snapshot"]
            epoch = snap["epoch"].string.nonEmpty ?? event["epoch"].string
            sequence = snap["seq"].isNull ? event["seq"].number : snap["seq"].number
            run = snap["current_run_view"]; return
        }
        guard event["type"] == "runtime_delta" else { return }
        guard !needsSnapshot else { return }
        let next = event["seq"].number
        guard event["epoch"].string == epoch else { needsSnapshot = true; return }
        guard next > sequence else { return }
        guard next == sequence + 1 else { needsSnapshot = true; return }
        sequence = next
        let delta = event["delta"]
        if delta.object.keys.contains("current_run_view") { run = delta["current_run_view"] }
        for (key, value) in delta["run"].object { run[key] = value }
        var messages = delta["reset_messages"].bool ? [] : run["messages"].array
        for append in delta["message_appends"].array {
            if let i = messages.firstIndex(where: { $0["id"] == append["id"] }) { messages[i]["content"] = .string(messages[i]["content"].string + append["content"].string) }
            else { messages.append(append) }
        }
        for append in delta["progress_appends"].array {
            if let i = messages.firstIndex(where: { $0["id"] == append["id"] }) {
                messages[i]["progress"] = .array(messages[i]["progress"].array + [append["progress"]])
                if !append["input"].isNull { messages[i]["input"] = append["input"] }
            }
        }
        // Full upserts are authoritative and must follow incremental appends.
        for var message in delta["message_upserts"].array {
            if let i = messages.firstIndex(where: { $0["id"] == message["id"] || !message["tool_call_id"].string.isEmpty && $0["tool_call_id"] == message["tool_call_id"] }) {
                message["id"] = messages[i]["id"]; messages[i] = message
            } else { messages.append(message) }
        }
        run["messages"] = .array(messages.sorted { $0["id"].number < $1["id"].number })
        for key in ["user", "steer"] {
            var turns = run[key + "_turns"].array
            let idKey = key == "user" ? "turn_id" : "item_id"
            for turn in delta[key + "_turn_upserts"].array {
                if let i = turns.firstIndex(where: { $0[idKey] == turn[idKey] }) { turns[i] = turn } else { turns.append(turn) }
            }
            let removals = delta[key + "_turn_removals"].array
            run[key + "_turns"] = .array(turns.filter { !removals.contains($0[idKey]) })
        }
    }
}

@MainActor @Observable final class ChatModel {
    let api: APIClient
    let botID: String
    let sessionID: String
    let queue: ChatQueue
    var history: [JSONValue] = []
    var runtime = RuntimeState()
    var pending: [JSONValue] = []
    var connection = "Connecting"
    var error: String?
    var loading = false
    var hasMore = false
    var models: [Record] = []
    var modelID = ""
    var effort = ""
    var workspaceTargetID = ""
    var draft = ""
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reliable: [String: JSONValue] = [:]
    private var isStopped = false
    var active: Bool { runtime.active || !pending.isEmpty }
    var prefix: String { "/bots/\(botID.pathComponent)" }
    var sessionPath: String { prefix + "/sessions/\(sessionID.pathComponent)" }
    init(api: APIClient, botID: String, sessionID: String) {
        self.api = api; self.botID = botID; self.sessionID = sessionID
        queue = ChatQueue(api: api, path: "/bots/\(botID.pathComponent)/sessions/\(sessionID.pathComponent)")
        if !api.isDemo { draft = Keychain.read("draft|\(api.draftScope)|\(botID)|\(sessionID)") ?? queue.unconfirmedText ?? "" }
    }
    func saveDraft() { if !api.isDemo && !api.signedOut { try? Keychain.save(draft.isEmpty ? nil : draft, account: "draft|\(api.draftScope)|\(botID)|\(sessionID)") } }
    func start() async {
        isStopped = false
        queue.start()
        await loadHistory()
        await loadModels()
        guard !api.isDemo else { connection = "Demo"; return }
        connect()
    }
    func loadModels() async {
        do {
            models = try await api.call("/models").items.map(Record.init).filter { $0.value["type"] == "chat" && $0.value["enable"] != false && $0.value["config"]["catalog_available"] != false }
            if !modelID.isEmpty && !models.contains(where: { $0.id == modelID }) { modelID = ""; effort = "" }
        } catch { /* Keep the bot default usable without model-list permission. */ }
    }
    func stop() {
        saveDraft(); queue.stop()
        isStopped = true; receiveTask?.cancel(); pingTask?.cancel(); socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }
    func connect() {
        guard !api.isDemo else { return }
        receiveTask?.cancel(); pingTask?.cancel(); socket?.cancel(with: .goingAway, reason: nil)
        receiveTask = Task { [weak self] in
            guard let self else { return }
            var backoff: UInt64 = 1
            while !Task.isCancelled && !self.isStopped {
                do {
                    self.connection = backoff == 1 ? "Connecting" : "Reconnecting"
                    if backoff > 1 { _ = try await self.api.call("/users/me") }
                    let ws = try await self.api.socket(self.prefix + "/web/ws")
                    self.socket = ws
                    try await self.write(["type": "runtime_subscribe", "session_id": .string(self.sessionID)])
                    for item in self.reliable.values { try await self.write(item) }
                    self.connection = "Connected"; backoff = 1
                    self.pingTask?.cancel()
                    self.pingTask = Task { [weak self, weak ws] in
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(20)); try Task.checkCancellation() } catch { return }
                            ws?.sendPing { error in if error != nil { Task { @MainActor in self?.socket?.cancel(with: .goingAway, reason: nil) } } }
                        }
                    }
                    while !Task.isCancelled {
                        let frame = try await ws.receive()
                        let data: Data
                        switch frame { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                        let event = try JSONDecoder().decode(JSONValue.self, from: data)
                        await self.handle(event)
                    }
                } catch {
                    self.pingTask?.cancel()
                    if Task.isCancelled || self.isStopped { return }
                    self.connection = "Reconnecting"
                    do { try await Task.sleep(nanoseconds: backoff * 1_000_000_000) } catch { return }
                    backoff = min(backoff * 2, 30)
                }
            }
        }
    }
    private func write(_ value: JSONValue) async throws {
        guard let socket else { throw ClientError.message("The chat connection is not ready.".localized) }
        try await socket.send(.string(String(data: try value.encoded, encoding: .utf8)!))
    }
    func reliableSend(_ value: JSONValue) async throws {
        reliable[value.text("invocation_id", "control_id")] = value
        try await write(value)
    }
    func loadHistory(older: Bool = false) async {
        loading = true; defer { loading = false }
        do {
            var query = ["session_id": sessionID, "limit": "50"]
            if older, let first = history.first { query["before_message_id"] = first.text("id", "turn_id") }
            let items = try await api.call(prefix + "/messages", query: query).items
            // Upstream returns chronological UI turns. Position is authoritative when supplied.
            let sorted = items.sorted {
                if !$0["turn_position"].isNull && !$1["turn_position"].isNull { return $0["turn_position"].number < $1["turn_position"].number }
                return $0["timestamp"].string < $1["timestamp"].string
            }
            if older {
                let known = Set(history.map { $0["turn_id"].string + $0["role"].string })
                history = sorted.filter { !known.contains($0["turn_id"].string + $0["role"].string) } + history
            } else { history = sorted }
            hasMore = items.count == 50; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func send(attachments: [JSONValue] = []) async -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return false }
        if !api.isDemo, active || queue.retryKind(for: text) != nil {
            return await enqueue(kind: queue.retryKind(for: text) ?? .followUp, attachments: attachments)
        }
        let invocation = UUID().uuidString.lowercased()
        let turn: JSONValue = ["turn_id": .string(invocation), "role": "user", "text": .string(text), "attachments": .array(attachments)]
        if api.isDemo {
            history.append(turn)
            history.append(["turn_id": .string(UUID().uuidString), "role": "assistant", "messages": [["id": 1, "type": "text", "content": "This is a local demo reply. Connect your Memoh server in Settings to send messages to a real agent. Your message has not left this device."]]])
            api.demo.collections["messages/" + sessionID] = history; draft = ""; return true
        }
        var request: JSONValue = ["type": "message", "invocation_id": .string(invocation), "session_id": .string(sessionID), "text": .string(text), "attachments": .array(attachments)]
        if !workspaceTargetID.isEmpty { request["workspace_target_id"] = .string(workspaceTargetID) }
        if !modelID.isEmpty { request["model_id"] = .string(modelID) }
        if !effort.isEmpty { request["reasoning_effort"] = .string(effort) }
        pending.append(turn); draft = ""
        if socket == nil {
            reliable[invocation] = request
            return true
        }
        do { try await reliableSend(request); return true }
        catch { self.error = "Connection interrupted. Your message is queued for reconnection."; return true }
    }
    func enqueue(kind: ChatQueueKind, attachments: [JSONValue] = []) async -> Bool {
        let sentDraft = draft
        guard await queue.enqueue(text: sentDraft, kind: kind, attachments: attachments) else { return false }
        if draft == sentDraft { draft = ""; saveDraft() }
        return true
    }
    func handle(_ event: JSONValue) async {
        let type = event["type"].string
        if !event["session_id"].string.isEmpty && event["session_id"].string != sessionID { return }
        if ["run_accepted", "run_rejected", "error", "command_result", "command_error"].contains(type) {
            reliable.removeValue(forKey: event["invocation_id"].string)
        }
        if type == "run_accepted" {
            if let i = pending.firstIndex(where: { $0["turn_id"] == event["invocation_id"] }) { pending[i]["turn_id"] = event["turn_id"] }
            try? await write(["type": "runtime_subscribe", "session_id": .string(sessionID)])
        } else if ["error", "run_rejected", "command_error"].contains(type) {
            error = event["message"].string.nonEmpty ?? event["error"]["message"].string
            pending.removeAll { $0["turn_id"] == event["invocation_id"] }
        } else if type == "control_ack" {
            reliable.removeValue(forKey: event["control_id"].string)
            if !event["applied"].bool { error = event["code"].string.nonEmpty ?? "The control could not be applied." }
        } else if type.hasPrefix("runtime_") {
            let wasActive = runtime.active
            let previousSteers = runtime.run["steer_turns"]
            let previousUsers = runtime.run["user_turns"]
            let previousRun = runtime.run["run_id"]
            runtime.apply(event)
            if runtime.needsSnapshot { try? await write(["type": "runtime_subscribe", "session_id": .string(sessionID)]); return }
            if type == "runtime_snapshot" || wasActive != runtime.active || previousRun != runtime.run["run_id"] || previousSteers != runtime.run["steer_turns"] || previousUsers != runtime.run["user_turns"] { queue.scheduleRefresh() }
            let userIDs = Set((runtime.run["user_turns"].array + [runtime.run["request_user_turn"]]).map { $0["turn_id"].string })
            pending.removeAll { userIDs.contains($0["turn_id"].string) }
            if wasActive && !runtime.active || type == "runtime_snapshot" && !runtime.active {
                await loadHistory()
                pending.removeAll { p in history.contains { $0["turn_id"] == p["turn_id"] } }
            }
        }
    }
    func control(_ type: String, extra: [String: JSONValue] = [:]) async {
        var value: JSONValue = ["type": .string(type), "session_id": .string(sessionID), "run_id": runtime.run["run_id"], "control_id": .string(UUID().uuidString.lowercased())]
        for (k, v) in extra { value[k] = v }
        do { try await reliableSend(value) } catch { self.error = error.localizedDescription }
    }
    func mutateTurn(_ turn: JSONValue, type: String, text: String? = nil) async {
        var value: JSONValue = ["type": .string(type), "invocation_id": .string(UUID().uuidString.lowercased()), "session_id": .string(sessionID), "turn_id": turn["turn_id"]]
        if let text { value["text"] = .string(text) }
        if !modelID.isEmpty { value["model_id"] = .string(modelID) }
        do { try await reliableSend(value) } catch { self.error = error.localizedDescription }
    }
    var visibleTurns: [JSONValue] {
        var turns = history
        let users = runtime.run["user_turns"].array.isEmpty ? [runtime.run["request_user_turn"]].filter { !$0.isNull } : runtime.run["user_turns"].array
        for user in users + pending where !turns.contains(where: { $0["turn_id"] == user["turn_id"] && $0["role"] == "user" }) { turns.append(user) }
        if !runtime.messages.isEmpty {
            let live: JSONValue = ["turn_id": runtime.run["turn_id"], "role": "assistant", "messages": .array(runtime.messages)]
            if let i = turns.firstIndex(where: { $0["turn_id"] == live["turn_id"] && $0["role"] == "assistant" }) { if runtime.active { turns[i] = live } }
            else { turns.append(live) }
        }
        return turns
    }
}


/// Wire answers differ for text questions and custom answers to a choice question.
struct UserInputDraft {
    var optionIDs: Set<String> = []
    var customSelected = false
    var text = ""

    static func questionID(_ question: JSONValue) -> String { question.text("id", "question_id") }
    mutating func select(_ optionID: String, question: JSONValue) {
        if question["kind"] == "multi_select" {
            if optionIDs.contains(optionID) { optionIDs.remove(optionID) }
            else {
                optionIDs.insert(optionID)
                if question["custom_exclusive"].bool { customSelected = false }
            }
        } else {
            optionIDs = optionIDs == [optionID] && question["required"] == false ? [] : [optionID]
            customSelected = false
        }
    }
    mutating func selectCustom(question: JSONValue) {
        guard question["allow_custom"].bool else { return }
        customSelected.toggle()
        if customSelected && (question["kind"] != "multi_select" || question["custom_exclusive"].bool) { optionIDs = [] }
    }
    func answer(for question: JSONValue) -> JSONValue? {
        let id = Self.questionID(question)
        guard !id.isEmpty else { return nil }
        let required = question["required"] != false
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if question["kind"] == "text" {
            if !text.isEmpty { return ["question_id": .string(id), "text": .string(text)] }
            return required ? nil : ["question_id": .string(id), "skipped": true]
        }
        let validIDs = Set(question["options"].array.map { $0["id"].string })
        let selected = optionIDs.intersection(validIDs).sorted()
        let custom = customSelected && question["allow_custom"].bool ? text : ""
        if customSelected && question["allow_custom"].bool && custom.isEmpty { return nil }
        if selected.isEmpty && custom.isEmpty { return required ? nil : ["question_id": .string(id), "skipped": true] }
        if question["kind"] != "multi_select" && selected.count + (custom.isEmpty ? 0 : 1) != 1 { return nil }
        if question["custom_exclusive"].bool && !selected.isEmpty && !custom.isEmpty { return nil }
        var answer: JSONValue = ["question_id": .string(id)]
        if !selected.isEmpty { answer["option_ids"] = .array(selected.map(JSONValue.string)) }
        if !custom.isEmpty { answer["custom_text"] = .string(custom) }
        return answer
    }
    static func answers(for questions: [JSONValue], drafts: [String: Self]) -> [JSONValue]? {
        guard !questions.isEmpty else { return nil }
        var answers: [JSONValue] = []
        for question in questions {
            guard let answer = drafts[questionID(question), default: Self()].answer(for: question) else { return nil }
            answers.append(answer)
        }
        return answers
    }
}

/// The list only needs run status, never a second copy of each transcript.
struct ConversationRunState {
    private var epoch = ""
    private var sequence: Double = 0
    private var hasSnapshot = false
    private var needsSnapshot = false
    private(set) var active = false

    /// Returns true once when a lost frame requires a fresh subscription snapshot.
    mutating func apply(_ event: JSONValue) -> Bool {
        let type = event["type"].string
        if type == "runtime_snapshot" {
            let snapshot = event["snapshot"]
            epoch = snapshot["epoch"].string.nonEmpty ?? event["epoch"].string
            sequence = snapshot["seq"].isNull ? event["seq"].number : snapshot["seq"].number
            active = RuntimeState.isActive(snapshot["current_run_view"]["status"].string)
            hasSnapshot = true; needsSnapshot = false
            return false
        }
        guard !needsSnapshot else { return false }
        if type == "runtime_dropped" { needsSnapshot = true; return true }
        guard type == "runtime_delta" else { return false }
        guard hasSnapshot, event["epoch"].string == epoch else { needsSnapshot = true; return true }
        let next = event["seq"].number
        guard next > sequence else { return false }
        guard next == sequence + 1 else { needsSnapshot = true; return true }
        sequence = next
        let delta = event["delta"]
        if delta.object.keys.contains("current_run_view") {
            active = RuntimeState.isActive(delta["current_run_view"]["status"].string)
        }
        if delta["run"].object.keys.contains("status") {
            active = RuntimeState.isActive(delta["run"]["status"].string)
        }
        return false
    }
}

@MainActor @Observable final class ConversationActivity {
    private(set) var running: Set<String> = []
    @ObservationIgnored private var generation = UUID()

    /// One read-only socket for the listed sessions. Cancelling it never aborts a run.
    func watch(api: APIClient?, botID: String, sessionIDs: [String]) async {
        let generation = UUID()
        self.generation = generation
        running = []
        guard let api, !api.isDemo, !botID.isEmpty, !sessionIDs.isEmpty else { return }
        let ids = Set(sessionIDs)
        var backoff = 1
        while !Task.isCancelled, self.generation == generation, !api.signedOut {
            do {
                let socket = try await api.socket("/bots/\(botID.pathComponent)/web/ws")
                defer { socket.cancel(with: .goingAway, reason: nil) }
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    for id in ids { try await subscribe(id, on: socket) }
                    let heartbeat = Task {
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(20)); try Task.checkCancellation() }
                            catch { return }
                            socket.sendPing { error in if error != nil { socket.cancel(with: .goingAway, reason: nil) } }
                        }
                    }
                    defer { heartbeat.cancel() }
                    var states: [String: ConversationRunState] = [:]
                    while !Task.isCancelled {
                        let frame = try await socket.receive()
                        let data: Data
                        switch frame {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: continue
                        }
                        guard self.generation == generation else { return }
                        let event = try JSONDecoder().decode(JSONValue.self, from: data)
                        let id = event["session_id"].string
                        guard ids.contains(id) else { continue }
                        var state = states[id] ?? ConversationRunState()
                        let refresh = state.apply(event)
                        states[id] = state
                        if state.active != running.contains(id) {
                            if state.active { running.insert(id) } else { running.remove(id) }
                        }
                        if event["type"] == "runtime_snapshot" { backoff = 1 }
                        if refresh { try await subscribe(id, on: socket) }
                    }
                } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
            } catch {
                guard !Task.isCancelled, self.generation == generation, !api.signedOut else { break }
                // Don't leave a stale spinner behind while the connection is offline.
                running = []
                do { try await Task.sleep(for: .seconds(backoff)) } catch { break }
                backoff = min(backoff * 2, 30)
            }
        }
        if self.generation == generation { running = [] }
    }

    private func subscribe(_ id: String, on socket: URLSessionWebSocketTask) async throws {
        let message: JSONValue = ["type": "runtime_subscribe", "session_id": .string(id)]
        try await socket.send(.string(String(decoding: try message.encoded, as: UTF8.self)))
    }
}
