import SwiftUI

struct MacLogin: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var official = OfficialLogin()
    @State private var mode = 0
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 20) {
            MacAvatar(name: "Homem", size: 64)
            Text("Welcome to Homem").font(.largeTitle.weight(.semibold))
            Text("Your Memoh workspace, on your Mac.").foregroundStyle(.secondary)
            Picker("Connection", selection: $mode) { Text("Memoh Cloud").tag(0); Text("Self-hosted Server").tag(1) }.pickerStyle(.segmented)
            Group {
                if mode == 0 { cloud }
                else {
                    Form {
                        TextField("API Address", text: $address, prompt: Text("https://server.example/api"))
                        TextField("Username", text: $username)
                        SecureField("Password", text: $password)
                        SecureField("Access Token (optional)", text: $token)
                    }
                    Button("Connect") { run { try await store.connect(address: address, username: username, password: password, accessToken: token); dismiss() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(busy || address.isEmpty || (token.isEmpty && (username.isEmpty || password.isEmpty)))
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            if busy { ProgressView().controlSize(.small) }
            Text("Saved sign-ins sync through iCloud Keychain when it is enabled on your devices.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(36).frame(width: 500).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private var cloud: some View {
        switch official.step {
        case .email:
            TextField("Email", text: $official.email).textFieldStyle(.roundedBorder)
            Button("Send Sign-in Code") { run { try await official.sendCode() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!official.validEmail || busy)
        case .code, .mfa:
            Text(official.step == .mfa ? "Enter your authenticator code." : "Enter the six-digit code sent to your email.").font(.callout)
            TextField("Code", text: $official.code).textFieldStyle(.roundedBorder)
            HStack {
                Button("Change Email") { official.changeEmail() }
                Button("Continue") { run { try await official.verifyCode() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!official.validCode || busy)
            }
        case .workspaces:
            Text("Choose a workspace").font(.headline)
            ForEach(Array(official.teams.enumerated()), id: \.offset) { _, team in
                Button(team.text("name", "slug").nonEmpty ?? "Workspace") {
                    run { try await store.connectOfficial(client: official.client, teamID: team["team_id"].string, workspace: team); dismiss() }
                }.buttonStyle(.bordered).disabled(busy)
            }
            if official.teams.isEmpty { Text("No workspaces are available for this account.").foregroundStyle(.secondary) }
        }
    }
    private func run(_ action: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}

struct MacAccountSettings: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false
    @State private var removing: SavedAccount?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accounts").font(.title2.weight(.semibold))
            Text("Sign-ins sync with iCloud Keychain. Each open workspace window keeps its own account.").font(.callout).foregroundStyle(.secondary)
            List(store.savedAccounts) { account in
                HStack {
                    MacAvatar(name: account.name)
                    VStack(alignment: .leading) { Text(account.name); Text(account.server).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if account.id == store.activeAccountID { Text("Active").font(.caption).foregroundStyle(.secondary) }
                    else { Button("Switch") { Task { do { try await store.switchAccount(account) } catch { self.error = error.localizedDescription } } } }
                    Button { removing = account } label: { Image(systemName: "minus.circle") }.help("Remove account")
                }.padding(.vertical, 4)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            Button("Add Account…") { adding = true }
        }.padding(24)
        .sheet(isPresented: $adding) { MacLogin().environment(store).frame(width: 560, height: 580) }
        .alert("Remove Account?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let removing { store.removeAccount(removing) }; removing = nil }
        } message: { Text("This removes the saved sign-in from iCloud Keychain and closes its connections.") }
        .onAppear { store.refreshSyncedAccounts() }
    }
}

struct MacAgents: View {
    let api: APIClient
    @Environment(AppStore.self) private var store
    @State private var selection: String?
    @State private var editor: AgentEditor?
    @State private var deleting = false
    @State private var error: String?
    private var bot: Record? { store.bots.first { $0.id == selection } }
    private var canManage: Bool { store.canAdmin || bot?.value["current_user_permissions"].array.contains("manage") == true }
    private struct AgentEditor: Identifiable {
        var title: String
        var path: String
        var operation: APIOperation
        var initial: JSONValue = .null
        var id: String { path }
    }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(store.bots, selection: $selection) { bot in
                    HStack { MacAvatar(name: bot.title); Text(bot.title) }.padding(.vertical, 4).tag(bot.id)
                }
                if store.canAdmin {
                    Divider()
                    Button("Add Agent…", systemImage: "plus") {
                        if let operation = SchemaCatalog.shared.operation("/bots", "POST") { editor = AgentEditor(title: "Add Agent", path: "/bots", operation: operation) }
                    }.padding(12)
                }
            }.frame(minWidth: 220, idealWidth: 280)
            if let bot {
                Form {
                    Section("Agent") {
                        LabeledContent("Name", value: bot.title)
                        LabeledContent("Status", value: bot.value["is_active"] == false ? "Inactive" : "Available")
                        LabeledContent("Agent ID", value: bot.id).textSelection(.enabled)
                    }
                    Section("Settings") {
                        Button("Edit Agent…") {
                            if let operation = SchemaCatalog.shared.operation("/bots/{id}", "PUT") { editor = AgentEditor(title: bot.title, path: "/bots/\(bot.id.pathComponent)", operation: operation, initial: bot.value) }
                        }.disabled(!canManage)
                        Button("Conversation & Tool Settings…") {
                            Task {
                                do {
                                    let settings = try await api.call("/bots/\(bot.id.pathComponent)/settings")
                                    if let operation = SchemaCatalog.shared.operation("/bots/{bot_id}/settings", "PUT") { editor = AgentEditor(title: "Settings · \(bot.title)", path: "/bots/\(bot.id.pathComponent)/settings", operation: operation, initial: settings) }
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(!canManage)
                        Button("Use This Agent") { store.selectedBotID = bot.id }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                    if canManage { Button("Delete Agent…", role: .destructive) { deleting = true } }
                }.formStyle(.grouped).frame(minWidth: 320)
            } else { ContentUnavailableView("Select an agent", systemImage: "person.crop.circle") }
        }
        .onAppear { selection = store.selectedBot?.id }
        .onChange(of: selection) { _, _ in error = nil }
        .sheet(item: $editor) { item in
            MacResourceEditor(api: api, title: item.title, path: item.path, operation: item.operation, initial: item.initial) { Task { await store.reload() } }
        }
        .alert("Delete Agent?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let bot { Task { do { _ = try await api.call("/bots/\(bot.id.pathComponent)", method: "DELETE"); selection = nil; await store.reload() } catch { self.error = error.localizedDescription } } }
            }
        } message: { Text("This permanently removes the agent and its server data.") }
    }
}

struct MacNewConversation: View {
    let api: APIClient
    let botID: String
    let botName: String
    let onCreated: (ChatDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var agents: [ConversationAgent] = [.memoh]
    @State private var agentID = ""
    @State private var settings = JSONValue.null
    @State private var busy = false
    @State private var loadingAgents = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Conversation").font(.title2.weight(.semibold))
            Form {
                LabeledContent("Agent", value: botName)
                TextField("Title", text: $title, prompt: Text("New chat"))
                if agents.count > 1 { Picker("Runtime", selection: $agentID) { ForEach(agents) { Text($0.name).tag($0.id) } } }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { if busy || loadingAgents { ProgressView().controlSize(.small) }; Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Create") { create() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(busy || loadingAgents || botID.isEmpty) }
        }.padding(24).frame(width: 440)
        .task {
            defer { loadingAgents = false }
            if let response = try? await api.call("/bots/\(botID.pathComponent)/agents") { agents = [.memoh] + ConversationAgent.enabled(in: response) }
            settings = (try? await api.call("/bots/\(botID.pathComponent)/settings")) ?? .null
            let preferred = settings["default_bot_agent_id"].string
            agentID = agents.contains { $0.id == preferred } ? preferred : ""
        }
    }
    private func create() {
        guard !busy, !loadingAgents, !botID.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "New chat"
                let agent = agents.first { $0.id == agentID } ?? .memoh
                let session = try await api.call("/bots/\(botID.pathComponent)/sessions", method: "POST", body: agent.sessionBody(title: name, settings: settings))
                guard !session["id"].string.isEmpty else { throw ClientError.invalidResponse }
                onCreated(ChatDestination(botID: botID, sessionID: session["id"].string, title: name, botName: botName)); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
