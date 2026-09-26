import SwiftUI

struct SettingsView: View {
    @Environment(\.appAccent) private var accent
    @Environment(AppStore.self) private var store
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("color-scheme") private var colorScheme = "system"
    @Environment(\.openURL) private var openURL
    @State private var signOut = false
    @State private var accounts = false
    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AgentAvatar(name: store.accountName, avatarURL: store.accountAvatarURL, size: 48)
                    VStack(alignment: .leading, spacing: 4) { Text(store.accountName).font(.headline); Text(store.isDemo ? "Demo workspace".localized : store.api?.baseURL.host ?? "Connected server".localized).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
                Button("Accounts".localized, systemImage: "person.crop.circle") { accounts = true }
                NavigationLink("Profile".localized, systemImage: "person") { SettingsDocumentView(title: "Profile", path: "/users/me", template: "/users/me") }
                if store.api?.isOfficial != true { OperationButton(title: "Change password", path: "/users/me/password", template: "/users/me/password", method: "PUT") }
            }
            Section("Intelligence".localized) {
                ResourceLink(title: "Providers", icon: "network", spec: .global("/providers", title: "Providers"))
                NavigationLink("Models".localized, systemImage: "cpu") { ModelsView() }
                ResourceLink(title: "Memory providers", icon: "brain", spec: .global("/memory-providers", title: "Memory providers"))
                ResourceLink(title: "Search providers", icon: "magnifyingglass", spec: .global("/search-providers", title: "Search providers"))
                ResourceLink(title: "Fetch providers", icon: "globe", spec: .global("/fetch-providers", title: "Fetch providers"))
            }
            Section("Connections".localized) {
                ResourceLink(title: "Speech models", icon: "waveform", spec: .global("/speech-models", title: "Speech models"))
                ResourceLink(title: "Transcription models", icon: "text.bubble", spec: .global("/transcription-models", title: "Transcription models"))
                ResourceLink(title: "Video models", icon: "video", spec: .global("/video-models", title: "Video models"))
                ResourceLink(title: "Remote runtimes", icon: "server.rack", spec: .global("/users/me/runtimes", title: "Remote runtimes"))
                if store.canAdmin { ResourceLink(title: "People", icon: "person.2", spec: .global("/users", title: "People")) }
            }
            Section("Preferences".localized) {
                Link("Privacy policy".localized, destination: URL(string: "https://docs.kitta.co/homem/")!)
                Picker("Appearance".localized, selection: $appearance) { Text("System".localized).tag("system"); Text("Light".localized).tag("light"); Text("Dark".localized).tag("dark") }.accessibilityIdentifier("appearancePicker")
                Picker("Color scheme".localized, selection: $colorScheme) { ForEach(Theme.schemes, id: \.self) { Text(($0 == "memoh" ? "Memoh".localized : $0.capitalized).localized).tag($0) } }.accessibilityIdentifier("accentPicker")
                Button { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } } label: {
                    HStack { Text("App language".localized); Spacer(); Text(Locale.current.localizedString(forLanguageCode: Bundle.main.preferredLocalizations.first ?? "en") ?? "").foregroundStyle(.secondary) }
                }.accessibilityHint("Change the app language in iOS Settings.".localized)
                NavigationLink("More connections".localized, systemImage: "link") { ServerConnectionsView() }
                NavigationLink("About Homem".localized, systemImage: "info.circle") { AboutView() }
            }
            Section {
                Button(store.isDemo ? "Connect your server".localized : "Sign out".localized, role: store.isDemo ? nil : .destructive) { if store.isDemo { store.signOut() } else { signOut = true } }
            } footer: { Text("Homem 1.0 · Native Swift client for Memoh".localized) }
        }.navigationTitle("Settings".localized)
            .toolbar { ToolbarItem(placement: .topBarLeading) { WorkspacePickerMenu() }.adaptiveAvatarPlacement() }
            .sheet(isPresented: $accounts) { AccountsView() }
            .alert("Sign out of Memoh?".localized, isPresented: $signOut) { Button("Sign out".localized, role: .destructive) { store.signOut() } }
    }
}

struct AboutView: View {
    @Environment(\.appAccent) private var accent
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) { Image(systemName: "house.and.flag.fill").font(.largeTitle).foregroundStyle(accent); Text("Homem").font(.largeTitle.bold()); Text("An independent app for Memoh.".localized).foregroundStyle(.secondary) }.padding(.vertical)
                LabeledContent("Version".localized, value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                LabeledContent("Bundle ID".localized, value: "ad.neko.homem")
            }
            Section("Open source".localized) {
                Link("Memoh · AGPL-3.0", destination: URL(string: "https://github.com/felinics/Memoh")!)
                Link("HighlightSwift · MIT", destination: URL(string: "https://github.com/appstefan/HighlightSwift")!)
                Link("SwiftTerm · MIT", destination: URL(string: "https://github.com/migueldeicaza/SwiftTerm")!)
                Link("L10n-swift · MIT", destination: URL(string: "https://github.com/Decybel07/L10n-swift")!)
                Link("WebRTC · BSD", destination: URL(string: "https://webrtc.org")!)
                NavigationLink("License notices".localized) { LicenseNoticesView() }
                Text("API baseline: 51bb207 (17 September 2026). Feature availability depends on your server, runtime, and permissions.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("About".localized)
    }
}

struct LicenseNoticesView: View {
    let documents = ["THIRD_PARTY_NOTICES", "AGPL-3.0", "SwiftTerm-LICENSE", "WebRTC-LICENSE", "L10n-swift-LICENSE", "HighlightSwift-LICENSE", "highlight.js-LICENSE"]
    var body: some View {
        List(documents, id: \.self) { name in
            NavigationLink(name) {
                ScrollView {
                    Text(Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "See the source distribution for this license.")
                        .font(.footnote.monospaced()).textSelection(.enabled).padding()
                }.navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            }
        }.navigationTitle("Licenses".localized)
    }
}

@MainActor @Observable final class MarketplaceCatalog {
    let api: APIClient
    var records: [Record] = []
    var error: String?
    var loading = false
    var hasMore = true
    var nextPage = 1
    var query = ""
    var loadedQuery: String?
    private var generation = UUID()
    init(api: APIClient) { self.api = api }
    func search(_ text: String, debounce: Bool = true) async {
        let request = UUID(); generation = request
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        records = []; error = nil; nextPage = 1; hasMore = true; loading = false; loadedQuery = nil
        if debounce {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        guard request == generation, !Task.isCancelled else { return }
        await loadMore()
    }
    func loadMore() async {
        guard !loading, hasMore else { return }
        let request = generation, page = nextPage
        loading = true; error = nil
        defer { if request == generation { loading = false } }
        do {
            let value = try await api.call("/supermarket/apps", query: ["q": query, "page": String(page), "limit": "30"])
            guard request == generation, !Task.isCancelled else { return }
            let incoming = value.items.map { item -> Record in
                var item = item
                if !item["app_id"].string.isEmpty { item["id"] = .string(item["registry_id"].string + "/" + item["app_id"].string) }
                return Record(value: item)
            }
            var existing = Set(records.map(\.id))
            let added = incoming.filter { existing.insert($0.id).inserted }
            records.append(contentsOf: added)
            loadedQuery = query
            nextPage = page + 1
            let limit = value["limit"].number > 0 ? Int(value["limit"].number) : 30
            hasMore = !added.isEmpty && (value["total"].isNull ? incoming.count >= limit : page * limit < Int(value["total"].number))
        } catch { if request == generation && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct MarketplaceView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let api = store.api { MarketplaceList(catalog: MarketplaceCatalog(api: api)).id(store.connectionID) }
    }
}

private struct MarketplaceList: View {
    @State var catalog: MarketplaceCatalog
    @State private var search = ""
    var body: some View {
        List {
            ForEach(catalog.records) { record in
                NavigationLink { MarketplaceDetailView(record: record) } label: {
                    HStack(spacing: 14) {
                        MarketplaceIcon(value: record.value, size: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.title).font(.headline)
                            Text(record.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.padding(.vertical, 4)
                }.onAppear {
                    if catalog.records.suffix(5).contains(where: { $0.id == record.id }), catalog.error == nil {
                        Task { await catalog.loadMore() }
                    }
                }
            }
            if let error = catalog.error { ErrorBanner(message: error) { Task { await catalog.loadMore() } } }
            else if catalog.hasMore {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .onAppear { if !catalog.records.isEmpty { Task { await catalog.loadMore() } } }
            } else if catalog.records.isEmpty {
                Text("No results".localized).foregroundStyle(.secondary)
            }
        }.navigationTitle("Supermarket".localized)
            .searchable(text: $search, prompt: "Search Supermarket".localized)
            .task(id: search) { if catalog.loadedQuery != search.trimmingCharacters(in: .whitespacesAndNewlines) { await catalog.search(search) } }
            .refreshable { await catalog.search(search, debounce: false) }
    }
}

struct MarketplaceDetailView: View {
    @Environment(AppStore.self) private var store
    var record: Record
    @State private var install = false
    @State private var descriptor: JSONValue = .null
    @State private var error: String?
    var body: some View {
        List {
            HStack(spacing: 16) {
                MarketplaceIcon(value: descriptor.isNull ? record.value : descriptor, size: 48, detail: true)
                Text(record.title).font(.title2.bold())
            }.padding(.vertical, 8)
            JSONDetails(value: descriptor.isNull ? record.value : descriptor)
            if let error { ErrorBanner(message: error) }
            Section("Install into".localized) { BotPicker(); Button("Install app".localized) { install = true }.disabled(store.selectedBot == nil || descriptor["revision"].string.isEmpty) }
        }.navigationTitle(record.title).navigationBarTitleDisplayMode(.inline)
            .task {
                do { descriptor = try await store.api?.call("/supermarket/registries/\(record.value["registry_id"].string.pathComponent)/apps/\(record.value["app_id"].string.pathComponent)") ?? .null } catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $install) {
                if let bot = store.selectedBot, let op = SchemaCatalog.shared.operation("/bots/{bot_id}/apps", "POST") {
                    SchemaEditor(title: "Install app", path: "/bots/\(bot.id.pathComponent)/apps", operation: op, initial: ["registry_id": descriptor["registry_id"], "app_id": descriptor["app_id"], "revision": descriptor["revision"]])
                }
            }
    }
}


struct MarketplaceIcon: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let value: JSONValue
    var size: CGFloat
    var detail = false
    private var source: String {
        guard let path = MarketplaceIconSource.path(value["icon"], dark: colorScheme == .dark, detail: detail),
              let base = store.api?.baseURL else { return "" }
        return base.appendingPathComponent(path).absoluteString
    }
    var body: some View {
        AgentAvatar(name: value.text("name", "title"), avatarURL: source, size: size, symbol: "bolt")
    }
}

enum MarketplaceIconSource {
    static func path(_ icon: JSONValue, dark: Bool, detail: Bool = false) -> String? {
        let variants = (dark ? ["dark"] : []) + (detail ? ["detail", "card"] : ["card", "detail"])
        for variant in variants {
            let digest = icon[variant]["digest"].string
            if digest.count == 64 && digest.allSatisfy({ "0123456789abcdef".contains($0) }) {
                return "supermarket/artifacts/icon/" + digest
            }
        }
        return nil
    }
}
