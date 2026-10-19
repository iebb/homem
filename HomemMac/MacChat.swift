import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MacChat: View {
    let destination: ChatDestination
    @State private var model: ChatModel
    @State private var attachments: [JSONValue] = []
    @State private var importing = false
    @State private var locations: [RunLocation] = []
    @State private var voice = VoiceRecorder()
    @FocusState private var composing: Bool
    init(api: APIClient, destination: ChatDestination) {
        self.destination = destination
        _model = State(initialValue: ChatModel(api: api, botID: destination.botID, sessionID: destination.sessionID))
    }
    var body: some View {
        @Bindable var chat = model
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if model.hasMore { Button("Load Earlier Messages") { Task { await model.loadHistory(older: true) } }.disabled(model.loading) }
                        ForEach(model.visibleTurns, id: \.chatTurnID) { turn in
                            MacTurn(turn: turn, model: model, name: destination.botName)
                                .contextMenu {
                                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(turn["role"] == "user" ? turn["text"].string : turn["messages"].array.map { $0["content"].string }.joined(separator: "\n"), forType: .string) }
                                    if !model.active { Button("Retry from Here") { Task { await model.mutateTurn(turn, type: "retry_message") } } }
                                }
                        }
                        if model.active { HStack { ProgressView().controlSize(.mini); Text(model.runtime.run["status"] == "waiting_decision" ? "Waiting for your response" : "Working…").foregroundStyle(.secondary).font(.caption) } }
                        if let error = model.error { MacError(message: error) { Task { await model.loadHistory() } } }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(24).frame(maxWidth: 820).frame(maxWidth: .infinity)
                }.defaultScrollAnchor(.bottom)
                    .onChange(of: model.latestTurnID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: composing) { _, focused in if focused { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            if !model.queue.items.isEmpty || model.queue.error != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.queue.items) { item in
                        HStack {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            Text(item.text).lineLimit(2)
                            Spacer()
                            if item.editable { Button("Remove") { Task { await model.queue.remove(item) } }.controlSize(.mini).disabled(!model.queue.busy.isEmpty || model.queue.submitting) }
                        }
                    }
                    if let error = model.queue.error { Text(error).foregroundStyle(.red) }
                }.font(.caption).padding(12).background(.bar)
            }
            VStack(spacing: 8) {
                if !attachments.isEmpty {
                    HStack {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, file in
                            HStack { Text(file["name"].string).lineLimit(1); Button { attachments.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }.font(.caption)
                        }; Spacer()
                    }
                }
                VStack(spacing: 2) {
                    TextEditor(text: $chat.draft).font(.system(size: 14)).scrollContentBackground(.hidden)
                        .frame(height: 70).padding(.horizontal, 6).padding(.top, 6)
                        .focused($composing).accessibilityLabel("Message").accessibilityIdentifier("nativeChatComposer")
                        .overlay(alignment: .topLeading) { if model.draft.isEmpty { Text("Message \(destination.botName)…").foregroundStyle(.tertiary).padding(.top, 14).padding(.leading, 12).allowsHitTesting(false) } }
                    HStack(spacing: 8) {
                        Button { importing = true } label: { Image(systemName: "paperclip") }.buttonStyle(.plain).help("Attach files").disabled(attachments.count >= 5)
                        Button {
                            if voice.recording { if let url = voice.finish() { attach(url); try? FileManager.default.removeItem(at: url) } }
                            else { Task { await voice.start() } }
                        } label: { Image(systemName: voice.recording ? "stop.circle.fill" : "mic") }.buttonStyle(.plain).help("Record voice message")
                        Spacer()
                        Picker("Model", selection: $chat.modelID) {
                            Text("Agent Default").tag("")
                            ForEach(model.models) { Text($0.title).tag($0.id) }
                        }.labelsHidden().frame(minWidth: 100, maxWidth: 180).controlSize(.small)
                        Menu {
                            Picker("Reasoning", selection: $chat.effort) { Text("Default").tag(""); ForEach(["low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) } }
                        } label: { Image(systemName: "brain") }.menuStyle(.borderlessButton).frame(width: 22).help("Reasoning effort: \(model.effort.nonEmpty?.capitalized ?? "Default")")
                        if model.active {
                            Button { Task { await model.control("abort") } } label: { Image(systemName: "stop.fill") }.help("Stop response")
                        }
                        Button(action: send) { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderedProminent).controlSize(.small).help("Send (⌘ Return)")
                            .keyboardShortcut(composing ? KeyboardShortcut(.return, modifiers: .command) : nil)
                            .disabled(model.queue.submitting || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                    }.padding(.horizontal, 12).padding(.bottom, 10)
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
                HStack {
                    if !locations.isEmpty {
                        Picker("Run on", selection: $chat.workspaceTargetID) { Text("Default Workspace").tag(""); ForEach(locations) { Text($0.name).tag($0.id) } }.labelsHidden().controlSize(.mini).frame(maxWidth: 200)
                    } else { Label("Memoh workspace", systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Circle().fill(model.connection == "Connected" ? .green : .orange).frame(width: 5, height: 5)
                    Text(model.connection).font(.caption2).foregroundStyle(.secondary)
                }
                if let error = voice.error { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(.horizontal, 20).padding(.bottom, 14).padding(.top, 8).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
        .task {
            await model.start()
            locations = ((try? await model.api.call(model.prefix + "/workspace-targets"))?.items ?? []).map(RunLocation.init).filter(\.available)
        }
        .onDisappear { model.stop(); voice.cancel() }
        .onChange(of: model.draft) { _, _ in model.saveDraft() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            do { for url in try result.get() { attach(url) } } catch { model.error = error.localizedDescription }
        }
    }
    private func attach(_ url: URL) { do { attachments.append(try ChatAttachment.read(url, existingCount: attachments.count)) } catch { model.error = error.localizedDescription } }
    private func send() {
        let files = attachments
        Task { if await model.send(attachments: files) { if attachments == files { attachments = [] }; model.saveDraft() } }
    }
}

struct MacTurn: View {
    let turn: JSONValue
    let model: ChatModel
    let name: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if turn["role"] == "user" {
                HStack { Spacer(minLength: 40); MacMarkdown(text: turn["text"].string).padding(14).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14)) }
            } else {
                HStack { MacAvatar(name: name, size: 22); Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
            }
            ForEach(turn["attachments"].array, id: \.self) { item in Label(item["name"].string, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(turn["messages"].array.enumerated()), id: \.offset) { _, message in
                MacMessage(message: message, model: model)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct MacMessage: View {
    let message: JSONValue
    let model: ChatModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch message["type"].string {
            case "reasoning": DisclosureGroup("Thinking") { MacMarkdown(text: message["content"].string).foregroundStyle(.secondary) }.font(.callout)
            case "tool":
                DisclosureGroup {
                    if !message["input"].isNull { MacCode(text: ToolCodeContent(message["input"]).text, language: "json") }
                    if !message["output"].isNull { MacCode(text: ToolCodeContent(message["output"]).text, language: "json") }
                } label: { Label(message["name"].string.nonEmpty ?? "Tool activity", systemImage: message["running"].bool ? "gearshape" : "checkmark").font(.caption).foregroundStyle(.secondary) }
            case "error": Text(message["content"].string).foregroundStyle(.red)
            default: if !message["content"].string.isEmpty { MacMarkdown(text: message["content"].string) }
            }
            if message["approval"]["status"] == "pending" { MacApproval(approval: message["approval"], model: model) }
            if message["user_input"]["status"] == "pending" { MacQuestions(input: message["user_input"], model: model).id(message["user_input"]["user_input_id"]) }
        }
    }
}
struct MacApproval: View {
    let approval: JSONValue
    let model: ChatModel
    var body: some View {
        GroupBox("Permission Requested") {
            if approval["can_approve"].bool {
                if approval["options"].array.isEmpty { HStack { Button("Allow Once") { respond("approve") }; Button("Decline") { respond("reject") } } }
                else { ForEach(approval["options"].array, id: \.self) { option in Button(option.text("name", "id")) { respond(option["kind"].string.hasPrefix("reject") ? "reject" : "approve", option: option["id"].string) } } }
            } else { Text("A workspace manager must approve this action.").font(.caption) }
        }
    }
    private func respond(_ decision: String, option: String = "") { Task { await model.control("tool_approval_response", extra: ["decision_id": approval["approval_id"], "decision": .string(decision), "option_id": .string(option)]) } }
}
struct MacQuestions: View {
    let input: JSONValue
    let model: ChatModel
    @State private var drafts: [String: UserInputDraft] = [:]
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(input["questions"].array, id: \.self) { question in
                    let id = UserInputDraft.questionID(question)
                    Text(question.text("text", "question", "title", "prompt")).fontWeight(.medium)
                    ForEach(question["options"].array, id: \.self) { option in
                        Button { drafts[id, default: UserInputDraft()].select(option["id"].string, question: question) } label: {
                            Label(option.text("label", "title", "id"), systemImage: drafts[id, default: UserInputDraft()].optionIDs.contains(option["id"].string) ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.plain)
                    }
                    if question["allow_custom"].bool && question["kind"] != "text" {
                        Toggle("Write My Own Answer", isOn: Binding(get: { drafts[id, default: UserInputDraft()].customSelected }, set: { enabled in drafts[id, default: UserInputDraft()].customSelected = enabled; if enabled && question["kind"] != "multi_select" { drafts[id]?.optionIDs = [] } }))
                    }
                    if question["kind"] == "text" || drafts[id, default: UserInputDraft()].customSelected {
                        TextField("Your answer", text: Binding(get: { drafts[id, default: UserInputDraft()].text }, set: { drafts[id, default: UserInputDraft()].text = $0 })).textFieldStyle(.roundedBorder)
                    }
                }
                Button("Send Answers") { if let answers = UserInputDraft.answers(for: input["questions"].array, drafts: drafts) { Task { await model.control("user_input_response", extra: ["decision_id": input["user_input_id"], "answers": .array(answers)]) } } }
                    .disabled(!input["can_respond"].bool || UserInputDraft.answers(for: input["questions"].array, drafts: drafts) == nil)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
}
struct MacMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownSegment.parse(text).enumerated()), id: \.offset) { _, segment in
                if segment.isCode { MacCode(text: segment.text, language: segment.language) }
                else { Text((try? AttributedString(markdown: segment.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(segment.text)).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}
struct MacCode: View {
    let text: String
    var language: String?
    @Environment(\.colorScheme) private var scheme
    @State private var highlighted = AttributedString()
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(language ?? "Code"); Spacer(); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }.buttonStyle(.plain) }.font(.caption).foregroundStyle(.secondary).padding(10)
            Divider()
            ScrollView(.horizontal) { Text(highlighted.characters.isEmpty ? AttributedString(text) : highlighted).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .task(id: text + String(describing: scheme)) { highlighted = await CodeHighlighting.render(text, language: language, dark: scheme == .dark) }
    }
}
struct MacError: View {
    var message: String
    var retry: (() -> Void)?
    var body: some View {
        HStack { Label(message, systemImage: "exclamationmark.circle").font(.callout).textSelection(.enabled); if let retry { Button("Retry", action: retry) } }.foregroundStyle(.red).padding(12)
    }
}
