import SwiftUI
import UniformTypeIdentifiers

struct ConversationsView: View {
    var macSection: Binding<HomeSection>? = nil
    @Environment(\.workspaceSceneID) private var workspaceSceneID
    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var activity = ConversationActivity()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.appAccent) private var accent
    @Environment(AppStore.self) private var store
    @State private var sessions: [Record] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var cursor = ""
    @State private var selection: ChatDestination?
    @State private var newChat = false
    @State private var rename: Record?
    @State private var newTitle = ""
    @State private var deletion: Record?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var macNavigationPath = NavigationPath()
    private var showsChats: Bool { (macSection?.wrappedValue ?? .chats) == .chats }
    private var currentConversation: ChatDestination? {
        guard let selection else { return nil }
        return store.chatWorkspace(for: selection.botID, windowID: workspaceSceneID).snapshot.conversation ?? selection
    }
    private var macDetailTitle: String {
        showsChats ? (currentConversation?.title ?? "") : (macSection?.wrappedValue.title.localized ?? "")
    }
    private var activityScope: String {
        store.connectionID.uuidString + "|" + (store.selectedBot?.id ?? "") + "|"
            + sessions.map(\.id).sorted().joined(separator: ",") + "|" + String(scenePhase == .background)
    }
    private var needsCompactBackControl: Bool {
        #if HOMEM_DUO_SDK
        if #available(iOS 27.1, *) { return sizeClass != .regular }
        #endif
        return false
    }
    private var usesSidebar: Bool {
        #if os(visionOS)
        false
        #else
        sizeClass == .regular
        #endif
    }
    private var conversationSelection: Binding<ChatDestination?> {
        Binding(get: {
            showsChats ? selection : nil
        }, set: { value in
            selection = value
            if value != nil { macSection?.wrappedValue = .chats }
        })
    }
    var body: some View {
        navigation
        .task(id: activityScope) {
            await activity.watch(api: scenePhase == .background ? nil : store.api,
                                 botID: store.selectedBot?.id ?? "", sessionIDs: sessions.map(\.id))
        }
        .task(id: store.selectedBot?.id) {
            sessions = []; cursor = ""; error = nil; search = ""
            if selection?.botID != store.selectedBot?.id {
                // Preserve the saved pane layout without automatically opening its chat.
                // A newly created conversation already selects its matching bot and
                // should still open immediately after sending the first message.
                selection = nil
                compactColumn = .sidebar
                columnVisibility = .all
            }
            await load()
        }
    }
    private var navigation: some View {
        #if os(visionOS)
        NavigationStack { conversationList }
            .accessibilityIdentifier("conversationLauncher")
        #else
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            conversationList
        } detail: {
            #if targetEnvironment(macCatalyst)
            NavigationStack(path: $macNavigationPath) {
                ZStack {
                    // Keep the chat alive while browsing another section, including
                    // its draft, attachments, pane layout, and active connection.
                    conversationDetail
                        .environment(\.homeChatVisible, showsChats)
                        .environment(\.homeSectionTitle, macSection?.wrappedValue.title.localized ?? "")
                        .opacity(showsChats ? 1 : 0)
                        .allowsHitTesting(showsChats)
                        .accessibilityHidden(!showsChats)
                    switch macSection?.wrappedValue ?? .chats {
                    case .chats: EmptyView()
                    case .agents: AgentsView()
                    case .library: LibraryView()
                    case .settings: SettingsView()
                    }
                }.navigationTitle(macDetailTitle)
            }
            #else
            conversationDetail
            #endif
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.expandChatWorkspace, { columnVisibility = .detailOnly })
        .onChange(of: selection) { _, value in
            if sizeClass != .regular { compactColumn = value == nil ? .sidebar : .detail }
            if value == nil { columnVisibility = .all }
        }
        .onChange(of: compactColumn) { _, column in
            if column == .sidebar { columnVisibility = .all }
        }
        .onChange(of: sizeClass) { _, value in
            if value == .compact { columnVisibility = .automatic }
        }
        #if targetEnvironment(macCatalyst)
        .background { WorkspaceWindowTitle(title: macDetailTitle.isEmpty ? "Homem" : "\(macDetailTitle) · Homem").frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true) }
        .modifier(WorkspaceWindowFocus(botID: store.selectedBot?.id ?? "", conversation: showsChats ? currentConversation : nil))
        .onChange(of: macSection?.wrappedValue) { _, _ in
            columnVisibility = .all
            macNavigationPath = NavigationPath()
        }
        #endif
        #endif
    }
    @ViewBuilder private var conversationDetail: some View {
        if let selection {
            ChatScreen(destination: selection, showsAgentSwitcher: true).id(selection.botID)
                .navigationBarBackButtonHidden(needsCompactBackControl)
                .toolbar {
                    if needsCompactBackControl {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                self.selection = nil
                                compactColumn = .sidebar
                                columnVisibility = .all
                            } label: { Image(systemName: "chevron.backward") }
                                .accessibilityLabel("Chats".localized)
                                .accessibilityIdentifier("backToConversations")
                        }.adaptiveAvatarPlacement()
                    }
                }
        } else {
            EmptyState(title: "Choose a conversation", symbol: "bubble.left.and.bubble.right", detail: "Choose a conversation or start a new one.")
                .toolbar {
                    if sizeClass == .regular && showsChats {
                        ToolbarItem(placement: .topBarTrailing) {
                            AgentPickerMenu(selection: Binding(get: { store.selectedBot?.id ?? "" }, set: { store.selectedBotID = $0 }))
                        }.adaptiveAvatarPlacement()
                    }
                }
        }
    }
    private var conversationList: some View {
        List(selection: conversationSelection) {
            #if targetEnvironment(macCatalyst)
            if let macSection {
                Section {
                    ForEach(HomeSection.allCases) { section in
                        Button { macSection.wrappedValue = section } label: {
                            Label(section.title.localized, systemImage: section.symbol)
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowBackground(RoundedRectangle(cornerRadius: 8).fill(macSection.wrappedValue == section ? accent.opacity(0.13) : .clear))
                            .accessibilityValue(macSection.wrappedValue == section ? "Selected".localized : "")
                            .accessibilityIdentifier("homeSection_" + section.rawValue)
                            .keyboardShortcut(section.shortcut, modifiers: .command)
                    }
                }
            }
            #endif
            if let error = error ?? store.error { ErrorBanner(message: error) { Task { await load() } } }
            Section {
                ForEach(sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { session in
                    let destination = ChatDestination(botID: store.selectedBot?.id ?? "", sessionID: session.id, title: session.title, botName: store.selectedBot?.title ?? "Agent")
                    conversationLink(destination) {
                        HStack(alignment: .top, spacing: 12) {
                            AgentAvatar(name: store.selectedBot?.title ?? "", avatarURL: store.selectedBot?.value.avatarURL ?? "", size: conversationAvatarSize)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(session.title).font(conversationTitleFont).lineLimit(2)
                                    if activity.running.contains(session.id) {
                                        Spacer(minLength: 0)
                                        ProgressView().controlSize(.small).tint(accent)
                                            .frame(width: 18, height: 20)
                                            .accessibilityLabel("Working…".localized)
                                            .accessibilityIdentifier("conversationRunning_" + session.id)
                                    }
                                }
                                HStack(spacing: 6) {
                                    ChatAgentIndicator(type: .session(session.value))
                                    if session.value["session_mode"] == "schedule" || session.value["type"] == "schedule" {
                                        Image(systemName: "clock").accessibilityLabel("Schedule".localized)
                                    }
                                    if let date = session.value["updated_at"].string.wireDate {
                                        Spacer(minLength: 4)
                                        Text(date, format: .dateTime.month(.abbreviated).day()).monospacedDigit()
                                    }
                                }.font(.caption).foregroundStyle(.secondary)

                            }
                        }.padding(.vertical, usesSidebar ? 4 : 8)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
                    .accessibilityIdentifier("conversation_" + session.id)
                    .contextMenu {
                        #if os(visionOS)
                        Button("Open in new window".localized, systemImage: "macwindow.badge.plus") {
                            openChat(destination)
                        }
                        #endif
                        Button("Rename".localized, systemImage: "pencil") { rename = session; newTitle = session.title }; Button("Delete".localized, systemImage: "trash", role: .destructive) { deletion = session } }
                    .swipeActions(allowsFullSwipe: false) { Button("Delete".localized) { deletion = session }.tint(.red) }
                }
                if !cursor.isEmpty { Button("Load more conversations".localized) { Task { await load(more: true) } } }
                if sessions.isEmpty && !loading && error == nil { Text("Start a new conversation.".localized).foregroundStyle(.secondary).padding(.vertical) }
            } header: {
                if !usesSidebar || macSection != nil { Text("Recent".localized) }
            }
        }
            .modifier(ConversationListStyle(isSidebar: usesSidebar))
            .scrollContentBackground(.hidden).background(Theme.canvas)
            #if !os(visionOS)
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
            #endif
            .navigationTitle(macSection == nil ? "Chats".localized : "Homem")
            .navigationBarTitleDisplayMode(usesSidebar ? .inline : .large)
            .searchable(text: $search, placement: usesSidebar ? .sidebar : .navigationBarDrawer(displayMode: .automatic), prompt: Text("Find a conversation".localized))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { WorkspacePickerMenu() }.adaptiveAvatarPlacement()
                ToolbarItem(placement: .topBarTrailing) { composeButton }
                if !usesSidebar {
                    ToolbarItem(placement: .topBarTrailing) {
                        AgentPickerMenu(selection: Binding(get: { store.selectedBot?.id ?? "" }, set: { store.selectedBotID = $0 }))
                    }.adaptiveAvatarPlacement()
                }
            }
            .refreshable { await store.reload(); await load() }
            .overlay { if loading && sessions.isEmpty { ProgressView() } }
            .sheet(isPresented: $newChat, onDismiss: { Task { await load() } }) {
                NewConversationView(botID: store.selectedBot?.id ?? "") { route in
                    store.selectedBotID = route.botID
                    #if os(visionOS)
                    openChat(route)
                    #else
                    macSection?.wrappedValue = .chats
                    selection = route
                    #endif
                }
            }
            .alert("Rename conversation".localized, isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
                TextField("Title".localized, text: $newTitle)
                Button("Save".localized) { if let record = rename { Task { await update(record, method: "PATCH", body: ["title": .string(newTitle)]) } } }
                Button("Cancel".localized, role: .cancel) { rename = nil }
            }
            .alert("Delete conversation?".localized, isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) {
                record in
                Button("Delete".localized, role: .destructive) { Task { await update(record, method: "DELETE") } }
                Button("Cancel".localized, role: .cancel) { deletion = nil }
            } message: { record in
                Text(AppLocalization.format("“%@” will be permanently deleted.", record.title))
            }
    }
    private var conversationAvatarSize: CGFloat {
        #if os(visionOS)
        44
        #else
        30
        #endif
    }
    private var conversationTitleFont: Font {
        #if os(visionOS)
        .headline
        #else
        usesSidebar ? .subheadline.weight(.medium) : .body.weight(.semibold)
        #endif
    }
    @ViewBuilder private func conversationLink<Label: View>(_ destination: ChatDestination, @ViewBuilder label: () -> Label) -> some View {
        #if os(visionOS)
        Button { openChat(destination) } label: { label() }
        #else
        NavigationLink(value: destination, label: label)
        #endif
    }
    #if os(visionOS)
    private func openChat(_ destination: ChatDestination) {
        if let route = store.chatWindowRoute(for: destination) {
            openWindow(id: "workspace-tool", value: route)
        }
    }
    #endif
    private var composeButton: some View {
        Button { newChat = true } label: { Image(systemName: "square.and.pencil").frame(width: Theme.controlSize, height: Theme.controlSize) }
            .buttonStyle(.plain).foregroundStyle(accent)
            .accessibilityLabel("New conversation".localized).accessibilityIdentifier("newConversation").disabled(store.bots.isEmpty)
    }
    func load(more: Bool = false) async {
        guard let bot = store.selectedBot, let api = store.api else { return }
        let botID = bot.id
        loading = true; defer { if store.selectedBot?.id == botID { loading = false } }
        do {
            var query = ["types": "chat,discuss,acp_agent,schedule", "limit": "50"]
            if more { query["cursor"] = cursor }
            let value = try await api.call("/bots/\(bot.id.pathComponent)/sessions", query: query)
            guard store.selectedBot?.id == botID else { return }
            let incoming = value.items.map(Record.init)
            sessions = more ? sessions + incoming.filter { r in !sessions.contains { $0.id == r.id } } : incoming
            cursor = value["next_cursor"].string; error = nil
        } catch { if store.selectedBot?.id == botID && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func update(_ record: Record, method: String, body: JSONValue? = nil) async {
        guard let botID = record.value["bot_id"].string.nonEmpty ?? store.selectedBot?.id else { return }
        var updated = false
        do { _ = try await store.api?.call("/bots/\(botID.pathComponent)/sessions/\(record.id.pathComponent)", method: method, body: body); updated = true; await load() }
        catch { self.error = error.localizedDescription }
        if updated && method == "DELETE", let botID = record.value["bot_id"].string.nonEmpty ?? store.selectedBot?.id {
            let workspace = store.chatWorkspace(for: botID, windowID: workspaceSceneID)
            if workspace.snapshot.conversation?.sessionID == record.id { workspace.snapshot.conversation = nil; selection = nil }
            for index in workspace.snapshot.panes.indices where workspace.snapshot.panes[index].conversation?.sessionID == record.id {
                workspace.snapshot.panes[index].conversation = nil
            }
        }
        rename = nil; deletion = nil
    }
}

/// Let the system provide sidebar selection, insets, and compact window behavior.
private struct ConversationListStyle: ViewModifier {
    var isSidebar: Bool
    @ViewBuilder func body(content: Content) -> some View {
        #if os(visionOS)
        content.listStyle(.insetGrouped)
        #else
        if isSidebar { content.listStyle(.sidebar) }
        else { content.listStyle(.plain) }
        #endif
    }
}

struct ChatScreen: View {
    @Environment(\.workspaceSceneID) private var workspaceSceneID
    @Environment(AppStore.self) private var store
    let destination: ChatDestination
    var showsAgentSwitcher = false
    var onFirstMessageQueued: (() -> Void)? = nil
    var body: some View {
        if let api = store.api {
            AgentChatWorkspace(workspace: store.chatWorkspace(for: destination.botID, windowID: workspaceSceneID), api: api, destination: destination, showsAgentSwitcher: showsAgentSwitcher, onFirstMessageQueued: onFirstMessageQueued)
                .id(destination.botID)
        }
    }
}

private struct AgentChatWorkspace: View {
    @Environment(AppStore.self) private var store
    @Environment(\.expandChatWorkspace) private var expandWorkspace
    @Bindable var workspace: AgentWorkspaceState
    let api: APIClient
    let destination: ChatDestination
    let showsAgentSwitcher: Bool
    let onFirstMessageQueued: (() -> Void)?
    @State private var prepared = false
    @State private var titlesVisible = true
    @AppStorage("keepWorkspaceTitleBarsVisible") private var keepTitlesVisible = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.homeChatVisible) private var homeChatVisible
    @Environment(\.homeSectionTitle) private var homeSectionTitle
    private var route: ChatDestination { workspace.snapshot.conversation ?? destination }
    var body: some View {
        content
        .background { Theme.canvas.ignoresSafeArea(.container, edges: .bottom) }
        .navigationTitle(homeChatVisible ? route.title : homeSectionTitle).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
        #if !os(visionOS)
        .toolbar(workspace.snapshot.panes.isEmpty ? .visible : .hidden, for: .tabBar)
        #endif
        .toolbar(.visible, for: .navigationBar)
        #if !os(visionOS)
        .onChange(of: keepTitlesVisible) { _, pinned in if pinned { titlesVisible = true } }
        .onChange(of: voiceOverEnabled) { _, enabled in if enabled { titlesVisible = true } }
        .onChange(of: workspace.snapshot.panes.isEmpty) { _, _ in titlesVisible = true }
        #endif
        .toolbar {
            if homeChatVisible {
                #if !os(visionOS)
                ToolbarItem(placement: .topBarTrailing) { paneMenu }
                #endif
                if showsAgentSwitcher {
                    ToolbarItem(placement: .topBarTrailing) {
                        AgentPickerMenu(selection: Binding(get: { destination.botID }, set: { store.selectedBotID = $0 }))
                    }.adaptiveAvatarPlacement()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink("Workspace".localized, systemImage: "folder") { WorkspaceView(botID: destination.botID, name: destination.botName) }
                        NavigationLink("Conversation settings".localized, systemImage: "slider.horizontal.3") { ConversationSettingsView(botID: route.botID, sessionID: route.sessionID) }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        #if os(visionOS)
        .ornament(attachmentAnchor: .scene(.bottom)) {
            SpatialWindowMenu(botID: route.botID, conversation: route)
            .labelStyle(.titleAndIcon)
            .controlSize(.large)
            .padding(12)
            .glassBackgroundEffect(in: Capsule())
        }
        #endif
        .onAppear {
            if !prepared { workspace.snapshot.conversation = destination; prepared = true }
        }
        .onChange(of: destination) { _, value in workspace.snapshot.conversation = value }
    }
    private var content: some View {
        #if os(visionOS)
        // Native windows own their content. Never instantiate saved split panes
        // (or their terminal/desktop connections) on visionOS.
        chat
        #else
        WorkspaceCanvas(workspace: $workspace.snapshot, titlesVisible: $titlesVisible, autoHideTitles: !keepTitlesVisible && !voiceOverEnabled, api: api, botID: destination.botID, botName: destination.botName) { chat }
        #endif
    }
    private var chat: some View {
        let currentRoute = route
        return ChatContent(model: ChatModel(api: api, botID: currentRoute.botID, sessionID: currentRoute.sessionID), destination: currentRoute, allowsWorkspace: false,
                           onFirstMessageQueued: {
                               if workspace.snapshot.conversation?.sessionID == currentRoute.sessionID { workspace.snapshot.conversation?.firstMessage = nil }
                               onFirstMessageQueued?()
                           }).id(currentRoute.sessionID)
    }
    #if !os(visionOS)
    private var paneMenu: some View {
        Menu {
            #if targetEnvironment(macCatalyst)
            Section("New window".localized) {
                WorkspaceWindowButtons(botID: route.botID, conversation: route)
            }
            #endif
            Section("Add pane".localized) {
                ForEach(ChatWorkspaceTool.allCases) { tool in
                    Button(tool.title.localized, systemImage: tool.symbol) {
                        workspace.snapshot.panes.append(WorkspacePane(tool: tool, botID: destination.botID))
                        expandWorkspace()
                    }.accessibilityIdentifier("addPane_" + tool.rawValue)
                }
            }
            if !workspace.snapshot.panes.isEmpty {
                Toggle("Keep pane bars visible".localized, isOn: $keepTitlesVisible)
                Picker("Arrange panes".localized, selection: $workspace.snapshot.arrangement) {
                    ForEach(WorkspaceArrangement.allCases) { item in Text(item.title.localized).tag(item) }
                }
                Button("Chat only".localized, systemImage: "bubble.left") {
                    workspace.snapshot.panes = []
                    workspace.snapshot.primaryIndex = 0
                    workspace.snapshot.docking = nil
                }
            }
        } label: {
            Image(systemName: "rectangle.badge.plus")
        }
        #if targetEnvironment(macCatalyst)
        .accessibilityLabel("Workspace".localized)
        #else
        .accessibilityLabel("Add pane".localized)
        #endif
        .accessibilityIdentifier("chatSplitView")
    }
    #endif
}

private struct IdentifiedChat: Identifiable { let route: ChatDestination; var id: String { route.sessionID } }

struct ChatContent: View {
    @Environment(\.workspaceSceneID) private var workspaceSceneID
    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @Environment(\.expandChatWorkspace) private var expandWorkspace
    @State var model: ChatModel
    let destination: ChatDestination
    var allowsWorkspace = true
    var onFirstMessageQueued: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var attachments: [JSONValue] = []
    @State private var filePicker = false
    @State private var editTurn: JSONValue?
    @State private var editText = ""
    @State private var forked: ChatDestination?
    @FocusState private var composerFocused: Bool
    @State private var voice = VoiceRecorder()
    @State private var sentFirstMessage = false
    private var presentedCanvas: some View {
        #if os(visionOS)
        transcript
        #else
        transcript.sheet(item: Binding(get: { forked.map(IdentifiedChat.init) }, set: { forked = $0?.route })) { item in
            NavigationStack { ChatScreen(destination: item.route) }
        }
        #endif
    }
    var body: some View {
        presentedCanvas
        .task {
            if !sentFirstMessage, let first = destination.firstMessage ?? store.takeWindowDraft(for: destination, windowID: workspaceSceneID) {
                sentFirstMessage = true
                model.workspaceTargetID = first.targetID
                model.draft = first.text
                // Queue before connecting, so navigation or reconnects cannot send twice.
                _ = await model.send(attachments: first.attachments)
                onFirstMessageQueued?()
            }
            await model.start()
        }.onDisappear { model.stop(); voice.cancel() }
        .task(id: model.draft) { do { try await Task.sleep(for: .milliseconds(600)); model.saveDraft() } catch {} }
        .onChange(of: store.modelCatalogRevision) { _, _ in Task { await model.loadModels() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.stop() }; if phase == .active { Task { await model.start() } } }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            do { for url in try result.get() { try attach(url) } } catch { model.error = error.localizedDescription }
        }
        .alert("Edit message".localized, isPresented: Binding(get: { editTurn != nil }, set: { if !$0 { editTurn = nil } })) {
            TextField("Message".localized, text: $editText)
            Button("Send".localized) { if let turn = editTurn { Task { await model.mutateTurn(turn, type: "edit_message", text: editText) } } }
            Button("Cancel".localized, role: .cancel) { editTurn = nil }
        }
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    HStack { AgentAvatar(name: destination.botName, avatarURL: store.bots.first { $0.id == destination.botID }?.value.avatarURL ?? "", size: 34); VStack(alignment: .leading, spacing: 3) { Text(destination.botName).font(.subheadline.weight(.semibold)); Text(model.connection.localized).font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(.bottom, 8)
                    if model.hasMore { Button("Load earlier messages".localized) { Task { await model.loadHistory(older: true) } }.disabled(model.loading).frame(maxWidth: .infinity) }
                    if model.history.isEmpty && !model.loading && !model.active { EmptyState(title: "What’s on your mind?", symbol: "sparkle", detail: "Ask a question, share a file, or start with an idea.").padding(.top, 30) }
                    ForEach(model.visibleTurns, id: \.chatTurnID) { turn in
                        TurnView(turn: turn, agentName: destination.botName, model: model)
                            .contextMenu {
                                Button("Copy".localized, systemImage: "doc.on.doc") { UIPasteboard.general.string = turn["role"] == "user" ? turn["text"].string : turn["messages"].array.map { $0["content"].string }.joined(separator: "\n") }
                                if turn["role"] == "assistant" { Button("Read aloud".localized, systemImage: "speaker.wave.2") { voice.speak(turn["messages"].array.filter { $0["type"] == "text" }.map { $0["content"].string }.joined(separator: "\n")) } }
                                if !model.active {
                                    Button("Retry from here".localized, systemImage: "arrow.clockwise") { Task { await model.mutateTurn(turn, type: "retry_message") } }
                                    if turn["role"] == "user" { Button("Edit message".localized, systemImage: "pencil") { editTurn = turn; editText = turn["text"].string } }
                                    if turn["runtime_forkable"].bool { Button("Fork conversation".localized, systemImage: "arrow.triangle.branch") { Task { await fork(turn) } } }
                                }
                            }
                    }
                    if model.active { HStack(spacing: 8) { Image(systemName: "sparkle").foregroundStyle(accent).symbolEffect(.pulse, options: .repeating); Text(model.runtime.run["status"] == "waiting_decision" ? "Waiting for your response".localized : "Working…".localized).font(.caption).foregroundStyle(.secondary) } }
                    if let error = model.error { ErrorBanner(message: error) { Task { await model.loadHistory() } } }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(22).frame(maxWidth: 840).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .dismissKeyboardOnScroll()
            .onChange(of: model.latestTurnID) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: composerFocused) { _, focused in if focused { proxy.scrollTo("bottom", anchor: .bottom) } }
            composer
            }
        }
    }
    private var hasComposerInput: Bool { !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    private var composer: some View {
        VStack(spacing: 10) {
            if !model.queue.items.isEmpty || model.queue.error != nil { ChatQueueView(queue: model.queue) }
            if voice.recording {
                HStack { Label("Recording · up to 5 minutes".localized, systemImage: "record.circle").font(.caption).foregroundStyle(.red); Spacer(); Button("Cancel".localized) { voice.cancel() }; Button("Attach".localized) { if let url = voice.finish() { do { try attach(url); try? FileManager.default.removeItem(at: url) } catch { model.error = error.localizedDescription } } } }.font(.caption)
            }
            if let error = voice.error { Text(error).font(.caption).foregroundStyle(.red) }
            if !attachments.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(Array(attachments.enumerated()), id: \.offset) { i, item in Button { attachments.remove(at: i) } label: { Label(item["name"].string, systemImage: "xmark.circle.fill").font(.caption).padding(8).background(.quaternary, in: Capsule()) } } } }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Menu {
                    Button("Attach a file".localized, systemImage: "paperclip") { filePicker = true }
                    Button("Record voice message".localized, systemImage: "mic") { Task { await voice.start() } }.disabled(voice.recording)
                } label: { Image(systemName: "plus").font(.title3).frame(width: Theme.controlSize, height: Theme.controlSize) }
                    .buttonStyle(.plain).spatialHoverEffect().accessibilityLabel("Add attachment".localized)
                TextField(AppLocalization.format("Message %@…", destination.botName), text: $model.draft, axis: .vertical).lineLimit(1...7).padding(.vertical, 10).focused($composerFocused).accessibilityIdentifier("messageComposer")
                if model.active {
                    Menu {
                        Button("Stop response".localized, role: .destructive) { Task { await model.control("abort") } }
                        if hasComposerInput, model.queue.steerSupported {
                            Button("Steer current response".localized) { Task { _ = await model.enqueue(kind: .steer, attachments: attachments) } }
                                .disabled(model.queue.submitting)
                        }
                    } label: { Image(systemName: "stop.circle").font(.title2).frame(width: Theme.controlSize, height: Theme.controlSize) }.accessibilityLabel("Response controls".localized)
                }
                if !model.active || hasComposerInput {
                    Button {
                        let sentAttachments = attachments
                        Task {
                            if await model.send(attachments: sentAttachments) {
                                if attachments == sentAttachments { attachments = [] }
                                if model.draft.isEmpty { composerFocused = false }
                            }
                        }
                    } label: {
                        Group {
                            if model.queue.submitting { ProgressView().tint(.white) }
                            else { Image(systemName: model.active ? "text.badge.plus" : "arrow.up").font(.body.weight(.semibold)) }
                        }.foregroundStyle(.white).frame(width: Theme.controlSize, height: Theme.controlSize).background(accent, in: Circle())
                    }.disabled(!hasComposerInput || model.queue.submitting)
                        .buttonStyle(.plain)
                        .accessibilityLabel((model.active ? "Queue message" : "Send message").localized).accessibilityIdentifier("sendMessage").spatialHoverEffect()
                }
            }.padding(.horizontal, 10).padding(.vertical, 5).background(Theme.surface, in: RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.separator, lineWidth: 0.5))
            HStack {
                Menu {
                    Picker("Model".localized, selection: $model.modelID) { Text("Agent default".localized).tag(""); ForEach(model.models) { Text($0.title).tag($0.id) } }
                    Picker("Reasoning".localized, selection: $model.effort) { ForEach(["", "none", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0.isEmpty ? "Default reasoning".localized : $0.capitalized.localized).tag($0) } }
                } label: { Label(model.models.first { $0.id == model.modelID }?.title ?? "Agent default".localized, systemImage: "sparkle").font(.caption).padding(.vertical, 6) }
                    .buttonStyle(.plain).spatialHoverEffect()
                Spacer()
                if !model.effort.isEmpty { Text(model.effort.capitalized.localized).font(.caption).foregroundStyle(.secondary) }
                if composerFocused {
                    Button { composerFocused = false } label: { Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 32) }
                        .accessibilityLabel("Hide keyboard".localized).accessibilityIdentifier("hideChatKeyboard")
                }
            }.padding(.horizontal, 6)
        }.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: 840).frame(maxWidth: .infinity)
            // A solid semantic surface avoids material changing color above the
            // keyboard and joins the home-indicator area without a second band.
            .background(Theme.canvas)
    }
    func attach(_ url: URL) throws {
        attachments.append(try ChatAttachment.read(url, existingCount: attachments.count))
    }

    func fork(_ turn: JSONValue) async {
        do {
            let value = try await model.api.call(model.sessionPath + "/fork", method: "POST", body: ["turn_id": turn["turn_id"]])
            let destination = ChatDestination(botID: self.destination.botID, sessionID: value["id"].string, title: value["title"].string, botName: self.destination.botName)
            #if os(visionOS)
            if let route = store.chatWindowRoute(for: destination) { openWindow(id: "workspace-tool", value: route) }
            #else
            forked = destination
            #endif
        } catch { model.error = error.localizedDescription }
    }
}

struct TurnView: View {
    @Environment(\.appAccent) private var accent
    @Environment(AppStore.self) private var store
    let turn: JSONValue
    let agentName: String
    let model: ChatModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if turn["role"] == "user" {
                    Spacer(minLength: 0)
                    AgentAvatar(name: store.accountName, avatarURL: store.accountAvatarURL, size: 30)
                        .accessibilityHidden(false)
                        .accessibilityLabel("You".localized)
                } else if turn["role"] == "system" {
                    Label("Workspace".localized, systemImage: "square.stack.3d.up")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    AgentAvatar(name: agentName, avatarURL: store.bots.first { $0.id == model.botID }?.value.avatarURL ?? "", size: 30)
                        .accessibilityHidden(true)
                    Text(agentName).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
            }
            if turn["role"] == "user" { MarkdownContent(text: turn["text"].string).frame(maxWidth: .infinity, alignment: .leading).padding(16).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18)) }
            ForEach(Array(turn["attachments"].array.enumerated()), id: \.offset) { _, item in AttachmentView(item: item, model: model) }
            MessageSequence(messages: turn["messages"].array, model: model)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MessageBlockView: View {
    let message: JSONValue
    let model: ChatModel
    var body: some View {
        switch message["type"].string {
        case "text": MarkdownContent(text: message["content"].string)
        case "reasoning": DisclosureGroup { MarkdownContent(text: message["content"].string).foregroundStyle(.secondary) } label: { Label("Thinking".localized, systemImage: "sparkles").font(.subheadline).foregroundStyle(.secondary) }
        case "tool": ToolActivityView(messages: [message], model: model)
        case "attachments": ForEach(Array(message["attachments"].array.enumerated()), id: \.offset) { _, item in AttachmentView(item: item, model: model) }
        case "error": ErrorBanner(message: message["content"].string)
        default: if !message["content"].string.isEmpty { Text(message["content"].string).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

struct MarkdownContent: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownSegment.parse(text).enumerated()), id: \.offset) { _, part in
                if part.isCode {
                    CodeBlockView(code: part.text, language: part.language)
                } else {
                    Text(inlineMarkdown(part.text.trimmingCharacters(in: .newlines))).textSelection(.enabled).lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private func inlineMarkdown(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(.body, design: .monospaced)
            result[run.range].backgroundColor = Color(.tertiarySystemFill)
        }
        return result
    }
}

struct ApprovalView: View {
    let approval: JSONValue
    let model: ChatModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Permission requested".localized, systemImage: "hand.raised").font(.subheadline.weight(.semibold))
            if approval["can_approve"].bool {
                if approval["options"].array.isEmpty {
                    HStack { Button("Allow once".localized) { respond("approve") }.buttonStyle(.borderedProminent); Button("Decline".localized, role: .destructive) { respond("reject") }.buttonStyle(.bordered) }
                } else { ForEach(approval["options"].array, id: \.self) { option in Button(option["name"].string.nonEmpty ?? option["id"].string) { respond(option["kind"].string.hasPrefix("reject") ? "reject" : "approve", option: option["id"].string) }.buttonStyle(.bordered) } }
            } else { Text("A workspace manager must approve this action.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    func respond(_ decision: String, option: String = "") { Task { await model.control("tool_approval_response", extra: ["decision_id": approval["approval_id"], "decision": .string(decision), "option_id": .string(option)]) } }
}

struct UserInputView: View {
    @Environment(\.appAccent) private var accent
    let input: JSONValue
    let model: ChatModel
    @State private var drafts: [String: UserInputDraft] = [:]
    @State private var submitting = false
    @FocusState private var focusedQuestion: String?
    private var questions: [JSONValue] { input["questions"].array }
    private var answers: [JSONValue]? { UserInputDraft.answers(for: questions, drafts: drafts) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(questions, id: \.self) { question in
                let id = UserInputDraft.questionID(question)
                let draft = drafts[id, default: UserInputDraft()]
                VStack(alignment: .leading, spacing: 10) {
                    Text(question.text("text", "question", "title", "prompt"))
                        .font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if question["kind"] != "text" {
                        VStack(spacing: 6) {
                            ForEach(question["options"].array, id: \.self) { option in
                                choice(option.text("label", "title", "id"), detail: option["description"].string,
                                       selected: draft.optionIDs.contains(option["id"].string), multiple: question["kind"] == "multi_select") {
                                    drafts[id, default: UserInputDraft()].select(option["id"].string, question: question)
                                    if !drafts[id, default: UserInputDraft()].customSelected { focusedQuestion = nil }
                                }.accessibilityIdentifier("answerOption_" + id + "_" + option["id"].string)
                            }
                            if question["allow_custom"].bool {
                                choice("Write my own answer".localized, selected: draft.customSelected, multiple: question["kind"] == "multi_select") {
                                    drafts[id, default: UserInputDraft()].selectCustom(question: question)
                                    focusedQuestion = drafts[id, default: UserInputDraft()].customSelected ? id : nil
                                }.accessibilityIdentifier("customAnswer_" + id)
                            }
                        }
                    }
                    if question["kind"] == "text" || draft.customSelected {
                        TextField(question["placeholder"].string.nonEmpty ?? "Your answer".localized,
                                  text: Binding(get: { drafts[id, default: UserInputDraft()].text }, set: { drafts[id, default: UserInputDraft()].text = $0 }), axis: .vertical)
                            .font(.body).lineLimit(2...6).focused($focusedQuestion, equals: id)
                            .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.3), lineWidth: 1))
                            .accessibilityIdentifier("answerText_" + id)
                    }
                }
            }
            Button {
                guard let answers, !submitting else { return }
                focusedQuestion = nil
                submitting = true
                Task {
                    defer { submitting = false }
                    await model.control("user_input_response", extra: ["decision_id": input["user_input_id"], "answers": .array(answers)])
                }
            } label: {
                HStack(spacing: 8) {
                    if submitting { ProgressView().tint(.white) }
                    Text("Send answers".localized).fontWeight(.semibold)
                }.frame(maxWidth: .infinity).padding(.vertical, 4)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!input["can_respond"].bool || answers == nil || submitting)
                .accessibilityIdentifier("sendUserInputAnswers")
        }.padding(.vertical, 8)
            .disabled(!input["can_respond"].bool || submitting)
            .onChange(of: input["user_input_id"]) { _, _ in drafts = [:]; focusedQuestion = nil }
    }
    private func choice(_ title: String, detail: String = "", selected: Bool, multiple: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: multiple ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 20)).foregroundStyle(selected ? accent : .secondary).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(selected ? accent.opacity(0.08) : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? accent.opacity(0.45) : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(selected ? "Selected".localized : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AttachmentView: View {
    let item: JSONValue
    let model: ChatModel
    @State private var downloaded: URL?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading) {
            if let downloaded { ShareLink(item: downloaded) { Label(item["name"].string.nonEmpty ?? "Attachment", systemImage: "square.and.arrow.up") } }
            else { Button { Task { await download() } } label: { Label(item["name"].string.nonEmpty ?? "Attachment", systemImage: "paperclip") } }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.font(.subheadline)
    }
    func download() async {
        do {
            let data: Data
            if let encoded = item["base64"].string.split(separator: ",", maxSplits: 1).last, let d = Data(base64Encoded: String(encoded)) { data = d }
            else if !item["path"].string.isEmpty { data = try await model.api.perform(model.api.request(model.prefix + "/container/fs/download", query: ["path": item["path"].string])) }
            else if let url = URL(string: item["url"].string), ["https", "http"].contains(url.scheme ?? "") { let (d, response) = try await URLSession.shared.data(from: url); guard let h = response as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { throw ClientError.invalidResponse }; data = d }
            else { throw ClientError.message("This attachment has no downloadable content.".localized) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent((item["name"].string as NSString).lastPathComponent.nonEmpty ?? "attachment")
            try data.write(to: url, options: .atomic); downloaded = url
        } catch { self.error = error.localizedDescription }
    }
}
