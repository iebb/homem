import SwiftUI
import Observation

@MainActor @Observable final class AppStore {
    private let vault: AccountVault
    var savedAccounts: [SavedAccount]
    var activeAccountID: String?
    var connectionID = UUID()
    @ObservationIgnored private var agentWorkspaces: [String: AgentWorkspaceState] = [:]
    func chatWorkspace(for botID: String) -> AgentWorkspaceState {
        let scope = api?.draftScope ?? "disconnected"
        let key = scope + "|" + botID
        if let existing = agentWorkspaces[key] { return existing }
        let state = AgentWorkspaceState(scope: scope, botID: botID)
        agentWorkspaces[key] = state
        return state
    }
    var modelCatalogRevision = 0
    var workspaces: [JSONValue] = []
    var api: APIClient?
    var bots: [Record] = []
    var profile: JSONValue = .null
    var accountProfile: JSONValue = .null
    var accountName: String { accountProfile.text("display_name", "username").nonEmpty ?? profile.text("display_name", "username").nonEmpty ?? "Your account".localized }
    var accountAvatarURL: String { accountProfile.avatarURL.nonEmpty ?? profile.avatarURL }
    var workspace: JSONValue = .null
    var workspaceName: String { workspace.text("name", "slug").nonEmpty ?? (isDemo ? "Demo workspace".localized : api?.isOfficial == true ? "Memoh workspace".localized : api?.baseURL.host ?? "Workspace".localized) }
    var error: String?
    var loading = false
    var selectedBotID: String = ""
    var isDemo: Bool { api?.isDemo == true }
    var canAdmin: Bool { profile["role"].string == "admin" }
    var selectedBot: Record? { bots.first { $0.id == selectedBotID } ?? bots.first }
    init(vault: AccountVault = AccountVault(), restore: Bool = true) {
        self.vault = vault; savedAccounts = vault.accounts; activeAccountID = vault.activeID
        guard restore else { return }
        if ProcessInfo.processInfo.arguments.contains("--ui-onboarding") { return }
        if ProcessInfo.processInfo.arguments.contains("--demo") { enterDemo() }
        else if let id = activeAccountID, let account = savedAccounts.first(where: { $0.id == id }) {
            api = try? vault.client(for: account)
        }
        else if !vault.migrated, let base = vault.defaults.string(forKey: "serverURL"), let url = try? APIClient.normalizedURL(base) {
            if url == OfficialServer.apiURL, let session = OfficialSession.restore() {
                api = APIClient(baseURL: url, officialSession: session)
                api?.persistOfficialSession = true
            } else if let token = Keychain.read(base) { api = APIClient(baseURL: url, token: token) }
        }
    }
    func enterDemo() {
        activeAccountID = nil
        workspace = .null; accountProfile = .null
        api = APIClient(baseURL: URL(string: "https://demo.invalid/api")!, isDemo: true)
        if ProcessInfo.processInfo.arguments.contains("--ui-tool-activity") {
            api!.demo.collections["messages/welcome"] = [["turn_id": "tools", "role": "assistant", "messages": [
                ["id": 1, "type": "tool", "name": "read_file", "input": ["path": "/data/notes.txt"], "output": "Read notes."],
                ["id": 2, "type": "tool", "name": "web_search", "input": ["query": "weather"], "output": "Found results."],
                ["id": 3, "type": "tool", "name": "update_schedule", "input": ["name": "Morning"], "output": "Schedule updated."],
                ["id": 4, "type": "text", "content": "Your schedule is up to date."]
            ]]]
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-code") {
            api!.demo.collections["messages/welcome"] = [["turn_id": "code", "role": "assistant", "messages": [
                ["id": 1, "type": "text", "content": "Here’s a small example using `greeting`:\n```swift\nstruct Greeting {\n    let name = \"Memoh\"\n\n    func message() -> String {\n        return \"Hello, \\(name)!\"\n    }\n}\n```"],
                ["id": 2, "type": "tool", "name": "write_file", "input": ["path": "/data/greeting.swift", "overwrite": true], "output": ["saved": true, "bytes": 128], "diff": "--- greeting.swift\n+++ greeting.swift\n@@ -1 +1 @@\n-print(\"Hi\")\n+print(\"Hello, Memoh!\")"]
            ]]]
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-user-input") {
            api!.demo.collections["messages/welcome"] = [["turn_id": "question", "role": "assistant", "messages": [
                ["id": 1, "type": "tool", "name": "ask_user", "user_input": [
                    "user_input_id": "preview-question", "status": "pending", "can_respond": true,
                    "questions": [["id": "plan", "text": "How would you like to continue?", "kind": "single_select", "allow_custom": true,
                        "options": [["id": "continue", "label": "Use the suggested plan", "description": "Continue with the current approach."],
                                    ["id": "review", "label": "Review the details first"]]]]
                ]]
            ]]]
        }
        bots = api!.demo.collections["/bots", default: []].map(Record.init)
        profile = api!.demo.documents["/users/me"] ?? .null
        selectedBotID = bots.first?.id ?? ""
    }
    func connect(address: String, username: String, password: String, accessToken: String) async throws {
        let url = try APIClient.normalizedURL(address)
        let client = APIClient(baseURL: url, token: accessToken.trimmingCharacters(in: .whitespacesAndNewlines))
        if client.token.isEmpty {
            let login = try await client.call("/auth/login", method: "POST", body: ["username": .string(username), "password": .string(password)])
            client.token = login["access_token"].string
            guard !client.token.isEmpty else { throw ClientError.invalidResponse }
        }
        let user = try await client.call("/users/me")
        try Task.checkCancellation()
        try saveAccount(client, user: user, account: user)
        replaceClient(client)
        profile = user
    }
    func reload() async {
        guard let api else { return }
        loading = true; defer { loading = false }
        do {
            async let botResult = api.call("/bots")
            async let userResult = api.call("/users/me")
            let (botValue, user) = try await (botResult, userResult)
            guard self.api === api else { return }
            bots = botValue.items.map(Record.init); profile = user
            if !bots.contains(where: { $0.id == selectedBotID }) { selectedBotID = bots.first?.id ?? "" }
            error = nil
            if api.isOfficial { await loadOfficialIdentity(api) }
            guard self.api === api else { return }
            // Import the existing single login once; refresh display metadata on later loads.
            try saveAccount(api, user: profile, account: api.isOfficial ? accountProfile : profile, preferredID: activeAccountID)
        } catch { if self.api === api && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func loadOfficialIdentity(_ client: APIClient) async {
        async let account = try? client.platformCall("/users/me")
        async let teams = try? client.platformCall("/teams")
        let (user, result) = await (account, teams)
        guard api === client else { return }
        if let user { accountProfile = OfficialIdentity.account(user) }
        if let result {
            workspaces = OfficialIdentity.teams(result)
            workspace = workspaces.first { $0["team_id"].string == client.officialSession?.teamID } ?? .null
        }
        DebugDiagnostics.record("Identity avatars: account=\(!accountAvatarURL.isEmpty), workspace=\(!workspace.avatarURL.isEmpty)")
    }
    func connectOfficial(client: APIClient, teamID: String, workspace: JSONValue = .null, preferredID: String? = nil, replacing: APIClient? = nil) async throws {
        guard client.isOfficial, !teamID.isEmpty else { throw ClientError.invalidResponse }
        client.officialSession?.teamID = teamID
        async let userResult = client.call("/users/me")
        async let botResult = client.call("/bots")
        async let identityResult = client.platformCall("/users/me")
        let (user, botValue, identity) = try await (userResult, botResult, identityResult)
        let account = OfficialIdentity.account(identity)
        try Task.checkCancellation()
        if let replacing, api !== replacing { throw CancellationError() }
        try saveAccount(client, user: user, account: account, preferredID: preferredID)
        client.unauthorized = false; client.persistOfficialSession = true
        replaceClient(client)
        self.workspace = workspace; accountProfile = account; profile = user
        bots = botValue.items.map(Record.init); selectedBotID = bots.first?.id ?? ""
        await loadOfficialIdentity(client)
    }
    private func saveAccount(_ client: APIClient, user: JSONValue, account: JSONValue, preferredID: String? = nil) throws {
        guard !client.isDemo else { return }
        let previous = savedAccounts.first { $0.id == preferredID }
        let identity = account.text("id", "user_id", "email", "username").nonEmpty ?? previous?.identity ?? user.text("id", "user_id", "username")
        let server = client.baseURL.absoluteString
        let match = savedAccounts.first { !$0.identity.isEmpty && $0.identity == identity && $0.server == server && $0.official == client.isOfficial }
        let id = preferredID ?? match?.id ?? UUID().uuidString
        let record = SavedAccount(id: id, server: server, identity: identity, name: account.text("display_name", "username", "email").nonEmpty ?? user.text("display_name", "username").nonEmpty ?? client.baseURL.host ?? "Memoh", avatarURL: account.avatarURL.nonEmpty ?? user.avatarURL, official: client.isOfficial)
        let secret: String
        if let session = client.officialSession {
            let saved = OfficialSession(cookies: client.session.configuration.httpCookieStorage?.cookies ?? [], teamID: session.teamID)
            guard !saved.validCookies.isEmpty else { throw ClientError.message("Sign in to Memoh again to continue.".localized) }
            secret = try JSONEncoder().encode(saved).base64EncodedString()
        } else { secret = client.token }
        let legacyKey = client === api && client.credentialAccount == nil ? (client.isOfficial ? OfficialServer.keychainAccount : server) : nil
        try vault.save(record, secret: secret)
        client.credentialAccount = record.credentialKey
        activeAccountID = id; vault.activate(id); savedAccounts = vault.accounts
        if let legacyKey {
            Keychain.migrateDrafts(from: server, to: client.draftScope)
            try? Keychain.save(nil, account: legacyKey)
        }
    }
    private func replaceClient(_ client: APIClient?) {
        DesktopPictureInPicture.stopActive(disconnect: true)
        api?.invalidate()
        api = client; bots = []; profile = .null; accountProfile = .null; workspace = .null; workspaces = []
        selectedBotID = ""; error = nil; connectionID = UUID()
    }
    func avatarClient(for account: SavedAccount) throws -> APIClient { try vault.client(for: account) }
    func switchAccount(_ account: SavedAccount) async throws {
        guard account.id != activeAccountID || api == nil else { return }
        let client = try vault.client(for: account)
        activeAccountID = account.id; vault.activate(account.id)
        replaceClient(client)
        accountProfile = ["display_name": .string(account.name), "avatar_url": .string(account.avatarURL)]
        await reload()
    }
    func switchWorkspace(_ team: JSONValue) async throws {
        guard let current = api, let session = current.officialSession, team["team_id"].string != session.teamID else { return }
        let credentials = OfficialSession(cookies: current.session.configuration.httpCookieStorage?.cookies ?? [], teamID: team["team_id"].string)
        let client = APIClient(baseURL: OfficialServer.apiURL, officialSession: credentials)
        try await connectOfficial(client: client, teamID: team["team_id"].string, workspace: team, preferredID: activeAccountID, replacing: current)
    }
    func removeAccount(_ account: SavedAccount) {
        let active = account.id == activeAccountID
        vault.remove(account); savedAccounts = vault.accounts
        if active { activeAccountID = nil; replaceClient(nil) }
    }
    func signOut() {
        if let account = savedAccounts.first(where: { $0.id == activeAccountID }) { removeAccount(account) }
        else { replaceClient(nil) }
    }
}
