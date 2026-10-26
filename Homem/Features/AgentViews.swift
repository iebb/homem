import SwiftUI

struct AgentsView: View {
    @Environment(\.appAccent) private var accent
    @Environment(AppStore.self) private var store
    @State private var create = false
    @State private var search = ""
    @ScaledMetric(relativeTo: .body) private var cardHeight = Theme.agentCardMinimumHeight
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error = store.error { ErrorBanner(message: error) { Task { await store.reload() } } }
                HStack {
                    Text(AppLocalization.format("Active · %lld", store.bots.filter { $0.value["is_active"].bool }.count)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(AppLocalization.format("Agents · %lld", store.bots.count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(store.bots.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { bot in
                        AgentCard(bot: bot, height: cardHeight)
                    }
                    #if !os(visionOS) && !targetEnvironment(macCatalyst)
                    createButton.frame(height: cardHeight, alignment: .top).modifier(DetailSurface())
                    #endif
                }
                #if os(visionOS) || targetEnvironment(macCatalyst)
                createButton.frame(maxWidth: 360).modifier(DetailSurface())
                #endif
            }.padding(22).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.background(Theme.canvas).navigationTitle("Agents".localized)
            .searchable(text: $search, prompt: "Find an agent")
            .toolbar {
                #if !targetEnvironment(macCatalyst)
                ToolbarItem(placement: .topBarLeading) { WorkspacePickerMenu() }.adaptiveAvatarPlacement()
                #endif
                ToolbarItem(placement: .topBarTrailing) { Button { create = true } label: { Image(systemName: "plus") }.accessibilityLabel("Create agent".localized) }
            }
            .refreshable { await store.reload() }
            .sheet(isPresented: $create, onDismiss: { Task { await store.reload() } }) {
                if let op = SchemaCatalog.shared.operation("/bots", "POST") { SchemaEditor(title: "Create an agent", path: "/bots", operation: op) }
            }
    }
    private var createButton: some View {
        Button { create = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus").font(.title2).frame(width: 44, height: 44)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                Text("Create an agent".localized).font(.headline)
                Spacer()
                Image(systemName: "arrow.right").font(.subheadline)
            }.foregroundStyle(accent).padding(Theme.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).spatialHoverEffect().accessibilityIdentifier("createAgent")
    }
}

struct AgentCard: View {
    @Environment(\.appAccent) private var accent
    let bot: Record
    let height: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
            NavigationLink { AgentDetailView(bot: bot) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 14) {
                        AgentAvatar(name: bot.title, avatarURL: bot.value.avatarURL, size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bot.title).font(.title3.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            StatusIndicator(text: bot.value["is_active"].bool ? "Active" : "Paused", color: bot.value["is_active"].bool ? .green : .secondary)
                        }.frame(minHeight: 52, alignment: .leading)
                        Spacer(minLength: 4)
                        Color.clear.frame(width: Theme.controlSize, height: Theme.controlSize)
                    }
                    if let description = bot.value["metadata"]["description"].string.nonEmpty {
                        Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).padding(.top, 12)
                    }
                    #if !os(visionOS) && !targetEnvironment(macCatalyst)
                    Spacer(minLength: 0)
                    #endif
                }.padding(.horizontal, Theme.gutter).padding(.top, Theme.gutter).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    #if !os(visionOS) && !targetEnvironment(macCatalyst)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    #endif
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("agentDetails_" + bot.id)
                AgentResourceSummary(botID: bot.id)
                    .padding(.top, Theme.gutter).padding(.trailing, Theme.gutter)
            }
            Divider().padding(.horizontal, Theme.gutter)
            HStack(spacing: 4) {
                ForEach([WorkspaceTool.files, .terminal, .desktop]) { tool in
                    WorkspaceToolLink(tool: tool, botID: bot.id) {
                        VStack(spacing: 5) {
                            Image(systemName: tool.symbol).font(.system(size: 17))
                            Text(tool.title.localized).font(.caption.weight(.medium)).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: Theme.controlSize).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(accent)
                        .spatialHoverEffect()
                        .accessibilityIdentifier("agentTool_" + bot.id + "_" + tool.rawValue)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }.frame(maxWidth: .infinity)
            .modifier(AgentCardSize(height: height))
            .modifier(DetailSurface())
    }
}

private struct AgentCardSize: ViewModifier {
    let height: CGFloat
    func body(content: Content) -> some View {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        content.frame(minHeight: height, alignment: .top)
        #else
        content.frame(height: height, alignment: .top)
        #endif
    }
}

struct AgentDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let bot: Record
    @State private var edit = false
    @State private var delete = false
    @State private var error: String?
    @State private var selectedTool: WorkspaceTool?
    private var current: Record { store.bots.first { $0.id == bot.id } ?? bot }
    private var base: String { "/bots/\(bot.id.pathComponent)" }
    private var manage: Bool { current.value["current_user_permissions"].array.contains("manage") || store.canAdmin }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        AgentAvatar(name: current.title, avatarURL: current.value.avatarURL, size: 56)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(current.title).font(.title2.bold())
                            StatusIndicator(text: current.value["is_active"].bool ? "Active" : "Paused", color: current.value["is_active"].bool ? .green : .secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    if let description = current.value["metadata"]["description"].string.nonEmpty {
                        Text(description).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Divider()
                    WorkspaceShortcuts(selection: $selectedTool)
                }.padding(.vertical, 4)
            }
            Section {
                ResourceLink(title: "Conversations", icon: "bubble.left.and.bubble.right", spec: .bot(bot.id, "sessions", title: "Conversations", detail: "/bots/{bot_id}/sessions/{session_id}"))
                ResourceLink(title: "Memories", icon: "brain", spec: .memory(bot.id))
                ResourceLink(title: "Schedules", icon: "clock", spec: .schedules(bot.id))
            }
            if manage {
                Section("Settings".localized) {
                    NavigationLink { AgentSettingsView(botID: bot.id) } label: { Label("Model & behavior".localized, systemImage: "slider.horizontal.3") }
                    ResourceLink(title: "Agents", icon: "cpu", spec: .bot(bot.id, "agents", title: "Agent runtimes"))
                    NavigationLink { ChannelsView(botID: bot.id) } label: { Label("Channels".localized, systemImage: "antenna.radiowaves.left.and.right") }
                    ResourceLink(title: "Connected tools", icon: "point.3.connected.trianglepath.dotted", spec: .mcp(bot.id))
                    ResourceLink(title: "Skills", icon: "sparkles", spec: .skills(bot.id))
                    ResourceLink(title: "Apps", icon: "square.stack.3d.up", spec: .apps(bot.id))
                    NavigationLink("Computers".localized, systemImage: "desktopcomputer") { WorkspaceComputersView(botID: bot.id) }
                    ResourceLink(title: "Connected accounts", icon: "link", spec: .bot(bot.id, "connectors", title: "Connected accounts", detail: "/bots/{bot_id}/connectors/{connection_id}"))
                    NavigationLink("Automation".localized, systemImage: "bolt") { AgentAutomationView(botID: bot.id) }
                }
            }
            Section("Insights".localized) {
                NavigationLink("Health checks".localized, systemImage: "heart.text.clipboard") { ReadOnlyDocumentView(title: "Health checks", path: base + "/checks") }
                NavigationLink("Token usage".localized, systemImage: "chart.bar") { TokenUsageView(botID: bot.id) }
                NavigationLink("Schedule history".localized, systemImage: "clock.arrow.circlepath") { ReadOnlyDocumentView(title: "Schedule history", path: base + "/schedule/logs") }
                NavigationLink("Compaction history".localized, systemImage: "archivebox") { ReadOnlyDocumentView(title: "Compaction history", path: base + "/compaction/logs") }
            }
            if manage {
                Section {
                    NavigationLink("Backups".localized, systemImage: "externaldrive") { BackupView(botID: bot.id) }
                    NavigationLink { WorkspaceView(botID: bot.id, name: current.title) } label: { Label("Workspace settings".localized, systemImage: "shippingbox") }
                    NavigationLink("Access & permissions".localized, systemImage: "lock.shield") { AccessSettingsView(botID: bot.id) }
                    Button(current.value["is_active"].bool ? "Pause agent".localized : "Resume agent".localized) { Task { await toggle() } }
                    Button("Delete agent".localized, role: .destructive) { delete = true }
                }
            }
            if let error { ErrorBanner(message: error) }
        }.navigationTitle(current.title).navigationBarTitleDisplayMode(.inline)
            .modifier(WorkspaceToolPresentation(selection: $selectedTool, botID: bot.id))
            .toolbar { if manage { Button("Edit".localized) { edit = true } } }
            .sheet(isPresented: $edit, onDismiss: { Task { await store.reload() } }) { if let op = SchemaCatalog.shared.operation("/bots/{id}", "PUT") { SchemaEditor(title: "Edit agent", path: base, operation: op, initial: current.value) } }
            .alert(AppLocalization.format("Delete %@?", current.title), isPresented: $delete) { Button("Delete agent".localized, role: .destructive) { Task { do { _ = try await store.api?.call(base, method: "DELETE"); await store.reload(); dismiss() } catch { self.error = error.localizedDescription } } } } message: { Text("This permanently removes the agent and its associated data. Export a backup first if needed.".localized) }
    }
    func toggle() async { do { _ = try await store.api?.call(base, method: "PUT", body: ["is_active": .bool(!current.value["is_active"].bool)]); await store.reload() } catch { self.error = error.localizedDescription } }
}

struct SettingsDocumentView: View {
    @Environment(AppStore.self) private var store
    var title: String
    var path: String
    var template: String
    @State private var value: JSONValue = .null
    @State private var error: String?
    @State private var edit = false
    var body: some View {
        List { if !value.isNull { JSONDetails(value: value) }; if let error { ErrorBanner(message: error) { Task { await load() } } } }
            .navigationTitle(title.localized).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Edit".localized) { edit = true }.disabled(value.isNull) }
            .task { await load() }.refreshable { await load() }
            .sheet(isPresented: $edit, onDismiss: { Task { await load() } }) {
                if let op = SchemaCatalog.shared.operation(template, "PUT") { SchemaEditor(title: title, path: path, operation: op, initial: value) }
            }
    }
    func load() async { do { value = try await store.api?.call(path) ?? .null; error = nil } catch { self.error = error.localizedDescription } }
}

struct ChannelsView: View {
    @Environment(AppStore.self) private var store
    var botID: String
    @State private var channels: [Record] = []
    @State private var error: String?
    var body: some View {
        List {
            Section { Text("Connect your agent to the places you already talk. Configuration fields are defined by each channel adapter.".localized).foregroundStyle(.secondary).font(.subheadline) }
            ForEach(channels) { channel in
                let platform = channel.value.text("type", "platform", "id")
                NavigationLink(channel.title) { ChannelDetailView(botID: botID, platform: platform, metadata: channel.value) }
            }
            if let error { ErrorBanner(message: error) }
        }.navigationTitle("Channels".localized).task { do { channels = try await store.api?.call("/channels").items.map(Record.init) ?? [] } catch { self.error = error.localizedDescription } }
    }
}

struct ChannelDetailView: View {
    @Environment(AppStore.self) private var store
    var botID: String
    var platform: String
    var metadata: JSONValue
    @State private var config: JSONValue = [:]
    @State private var error: String?
    @State private var edit = false
    @State private var busy = false
    var path: String { "/bots/\(botID.pathComponent)/channel/\(platform.pathComponent)" }
    var body: some View {
        List {
            Section("Channel".localized) { JSONDetails(value: metadata) }
            if !config.object.isEmpty { Section("Configuration".localized) { JSONDetails(value: config) } }
            if let error { ErrorBanner(message: error) }
            Section { Button("Configure channel".localized) { edit = true }; Toggle("Enabled".localized, isOn: Binding(get: { !config["disabled"].bool }, set: { enabled in Task { await setEnabled(enabled) } })).disabled(busy || config.object.isEmpty) }
        }.navigationTitle(platform.fieldLabel).task { await load() }
            .sheet(isPresented: $edit, onDismiss: { Task { await load() } }) { ChannelConfigEditor(path: path, platform: platform, metadata: metadata, initial: config) }
    }
    func setEnabled(_ enabled: Bool) async {
        busy = true; defer { busy = false }
        do { _ = try await store.api?.call(path + "/status", method: "PATCH", body: ["disabled": .bool(!enabled)]); await load() }
        catch { self.error = error.localizedDescription }
    }
    func load() async { do { config = try await store.api?.call(path) ?? [:]; error = nil } catch { self.error = error.localizedDescription } }
}

struct ChannelConfigEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var path: String
    var platform: String
    var metadata: JSONValue
    var initial: JSONValue
    @State private var credentials: JSONValue = [:]
    @State private var disabled = false
    @State private var busy = false
    @State private var error: String?
    var fields: [String] { metadata["config_schema"]["fields"].object.keys.sorted { metadata["config_schema"]["fields"][$0]["order"].number < metadata["config_schema"]["fields"][$1]["order"].number } }
    var body: some View {
        NavigationStack {
            Form {
                Section { Toggle("Enabled".localized, isOn: Binding(get: { !disabled }, set: { disabled = !$0 })) }
                Section("Connection".localized) {
                    if fields.isEmpty { JSONInput(value: $credentials) }
                    ForEach(fields, id: \.self) { key in
                        let field = metadata["config_schema"]["fields"][key]
                        if field["type"] == "secret" {
                            SecureField(field["title"].string.nonEmpty ?? key.fieldLabel.localized, text: Binding(get: { credentials[key].string }, set: { credentials[key] = .string($0) })).textInputAutocapitalization(.never).autocorrectionDisabled()
                        } else {
                            SchemaField(name: key, schema: converted(field), required: field["required"].bool, value: Binding(get: { credentials[key] }, set: { credentials[key] = $0 }))
                        }
                    }
                }
                if let error { ErrorBanner(message: error) }
            }.navigationTitle(platform.fieldLabel).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel".localized) { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save".localized) { Task { await save() } }.disabled(busy) } }
                .onAppear { credentials = initial["credentials"].isNull ? [:] : initial["credentials"]; disabled = initial["disabled"].bool }
        }
    }
    func converted(_ field: JSONValue) -> JSONValue { var value = field; if value["type"] == "bool" { value["type"] = "boolean" }; if value["type"] == "enum" { value["type"] = "string" }; return value }
    func save() async {
        busy = true; defer { busy = false }
        do {
            for key in fields {
                let field = metadata["config_schema"]["fields"][key]
                if field["required"].bool && (credentials[key].isNull || credentials[key] == "") { throw ClientError.message(AppLocalization.format("%@ is required.", key.fieldLabel.localized)) }
                if field["type"] != "secret" { try SchemaCatalog.shared.validate(credentials[key], schema: converted(field), name: key) }
            }
            _ = try await store.api?.call(path, method: "PUT", body: ["credentials": credentials, "disabled": .bool(disabled)])
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}


/// Compact used / limit readouts; missing samples never masquerade as zero usage.
struct AgentResourceSummary: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    let botID: String
    @State private var expanded = false
    @State private var snapshot: JSONValue = .null
    private var metrics: JSONValue { snapshot["metrics"] }
    private var limits: JSONValue {
        let applied = snapshot["resource_limits"]["applied"]
        return applied.isNull ? snapshot["resource_limits"]["desired"] : applied
    }
    private var cpuUsed: String {
        let cpu = metrics["cpu"]
        guard !cpu.isNull else { return "—" }
        let cores = cpu["usage_nanocores"].isNull ? cpu["usage_percent"].number / 100 : cpu["usage_nanocores"].number / 1_000_000_000
        return cores.formatted(.number.precision(.fractionLength(0...2)))
    }
    private var cpuLimit: String {
        let value = limits["cpu_millicores"]
        guard !value.isNull else { return "—" }
        return value.number > 0 ? (value.number / 1000).formatted(.number.precision(.fractionLength(0...2))) : "∞"
    }
    private var memoryLimit: JSONValue {
        let actual = metrics["memory"]["limit_bytes"]
        return actual.isNull ? limits["memory_bytes"] : actual
    }
    var body: some View {
        Button { expanded = true } label: {
            Image(systemName: "chart.bar")
                .font(.body).frame(width: Theme.controlSize, height: Theme.controlSize).contentShape(Rectangle())
        }.buttonStyle(.plain).spatialHoverEffect()
            .accessibilityLabel("Resource metrics".localized)
            .accessibilityValue((expanded ? "Expanded" : "Collapsed").localized)
            .accessibilityIdentifier("agentResources_" + botID)
            .popover(isPresented: $expanded) {
                details.presentationCompactAdaptation(.popover)
            }
    }
    private var details: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack {
                Text("Resource metrics".localized).font(.headline).foregroundStyle(.primary)
                Spacer()
                Button("Done".localized) { expanded = false }
                    .accessibilityIdentifier("closeAgentResources_" + botID)
            }.padding(.bottom, 10)
            resource("CPU", symbol: "cpu", used: cpuUsed, limit: cpuLimit)
            resource("RAM", symbol: "memorychip", used: bytes(metrics["memory"]["usage_bytes"]), limit: bytes(memoryLimit, limit: true))
            resource("Storage", symbol: "internaldrive", used: bytes(metrics["storage"]["used_bytes"]), limit: bytes(limits["storage_bytes"], limit: true))
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .frame(width: 270).padding(18)
            .task(id: scenePhase) {
                guard scenePhase == .active, let api = store.api else { return }
                repeat {
                    let value = try? await api.call("/bots/\(botID.pathComponent)/container/metrics")
                    guard !Task.isCancelled else { return }
                    snapshot = value ?? .null
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                } while !Task.isCancelled
            }
    }
    private func resource(_ name: String, symbol: String, used: String, limit: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).frame(width: 12)
            Text(name.localized)
            Spacer(minLength: 12)
            if used == "—" {
                Text(name == "CPU" && limit != "—" && limit != "∞" ? AppLocalization.format("%@ cores", limit) : limit)
            } else {
                Text(used).foregroundStyle(.primary) + Text(" / " + limit)
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityIdentifier("agentResource_" + botID + "_" + name)
            .accessibilityLabel(name.localized)
            .accessibilityValue(used == "—" ? AppLocalization.format("Limit: %@", limit) : AppLocalization.format("%@ used · %@ limit", used, limit))
    }
    private func bytes(_ value: JSONValue, limit: Bool = false) -> String {
        guard !value.isNull else { return "—" }
        if limit && value.number <= 0 { return "∞" }
        return ByteCountFormatter.string(fromByteCount: Int64(max(0, min(value.number, Double(Int64.max / 2)))), countStyle: .memory)
    }
}

struct AgentSettingsView: View {
    @Environment(AppStore.self) private var store
    let botID: String
    @State private var original: JSONValue = .null
    @State private var draft: JSONValue = .null
    @State private var catalogs: [String: [JSONValue]] = [:]
    @State private var catalogErrors: [String: String] = [:]
    @State private var loadingChoices = false
    @State private var saving = false
    @State private var error: String?
    private var schema: JSONValue { SchemaCatalog.shared.schema("/bots/{bot_id}/settings", "PUT") }
    private var keys: Set<String> { Set(schema["properties"].object.keys) }
    private var changes: JSONValue { AgentSettingsFields.changes(from: original, to: draft, allowed: keys) }
    var body: some View {
        Form {
            if original.isNull {
                if error == nil { ProgressView() }
            } else {
                ForEach(AgentSettingsFields.groups, id: \.0) { group in
                    Section(group.0.localized) {
                        ForEach(group.1.filter { keys.contains($0) }, id: \.self) { key in settingsField(key) }
                    }
                }
                // Preserve forward compatibility without presenting server metadata as editable settings.
                let known = Set(AgentSettingsFields.groups.flatMap(\.1))
                let remaining = keys.subtracting(known).filter { !original[$0].isNull }.sorted()
                if !remaining.isEmpty { Section("Other settings".localized) { ForEach(remaining, id: \.self) { settingsField($0) } } }
            }
            if let error { ErrorBanner(message: error) }
            if original.isNull && error != nil { Button("Retry".localized) { Task { await load() } } }
        }
        .navigationTitle("Agent settings".localized).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: {
                    if saving { ProgressView() } else { Text("Save".localized).fontWeight(.semibold) }
                }.disabled(saving || changes.object.isEmpty)
            }
            if !changes.object.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { draft = original; error = nil } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel("Discard changes".localized).disabled(saving)
                }
            }
        }
        .disabled(saving)
        .task { if original.isNull { await load() } }
    }
    @ViewBuilder private func settingsField(_ key: String) -> some View {
        let label = AgentSettingsFields.label(key).localized
        if let source = AgentSettingsFields.source(key, botID: botID) {
            let rows = (catalogs[source] ?? []).map { row in
                var named = row
                if let providerSource = AgentSettingsFields.providerSource(source),
                   let provider = catalogs[providerSource]?.first(where: { $0["id"] == row["provider_id"] }),
                   let providerName = provider.text("name", "display_name", "provider").nonEmpty {
                    named["display_name"] = .string(row.displayTitle + " · " + providerName)
                    if provider["enable"] == false { named["enable"] = false }
                }
                return named
            }
            let options = AgentSettingsFields.options(rows, key: key, selected: draft[key].string)
            NavigationLink {
                AgentSettingPicker(title: label, options: options, selected: Binding(get: { draft[key].string }, set: { draft[key] = .string($0) }), loading: loadingChoices, error: catalogErrors[source], retry: { Task { await loadChoices() } })
            } label: {
                LabeledContent(label) {
                    Text(draft[key].string.isEmpty ? "None".localized : options.first { $0.id == draft[key].string }?.title ?? (loadingChoices ? "Loading…".localized : "Unavailable selection".localized))
                        .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                }
            }.accessibilityIdentifier("agentSetting_" + key)
        } else {
            let fieldSchema = SchemaCatalog.shared.resolve(schema["properties"][key])
            SchemaField(name: key, schema: fieldSchema, required: false, value: Binding(get: { draft[key] }, set: { draft[key] = $0 }), displayName: label, showDescription: false)
                .accessibilityIdentifier("agentSetting_" + key)
        }
    }
    private func load() async {
        guard let api = store.api else { return }
        do {
            let value = try await api.call("/bots/\(botID.pathComponent)/settings")
            original = value; draft = value; error = nil
            await loadChoices()
        } catch { self.error = error.localizedDescription }
    }
    private func loadChoices() async {
        guard let api = store.api, !loadingChoices else { return }
        loadingChoices = true; defer { loadingChoices = false }
        let references = Set(keys.compactMap { AgentSettingsFields.source($0, botID: botID) })
        let sources = references.union(references.compactMap(AgentSettingsFields.providerSource))
        await withTaskGroup(of: (String, [JSONValue]?, String?).self) { group in
            for source in sources {
                group.addTask {
                    do { return (source, try await api.call(source).items, nil) }
                    catch { return (source, nil, error.localizedDescription) }
                }
            }
            for await (source, rows, failure) in group {
                if let rows { catalogs[source] = rows }
                catalogErrors[source] = failure
            }
        }
    }
    private func save() async {
        guard let api = store.api else { return }
        let patch = changes
        guard !patch.object.isEmpty else { return }
        saving = true; error = nil; defer { saving = false }
        do {
            try SchemaCatalog.shared.validate(patch, schema: schema)
            let result = try await api.call("/bots/\(botID.pathComponent)/settings", method: "PUT", body: patch)
            // Some compatible servers return no document for successful writes.
            if result.object.isEmpty { for (key, value) in patch.object { original[key] = value }; draft = original }
            else { original = result; draft = result }
        } catch { self.error = error.localizedDescription }
    }
}

private struct AgentSettingPicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let options: [Record]
    @Binding var selected: String
    let loading: Bool
    let error: String?
    let retry: () -> Void
    @State private var search = ""
    var body: some View {
        List {
            Section { choice("None".localized, id: "") }
            if !selected.isEmpty && !options.contains(where: { $0.id == selected }) {
                Section { Label("Unavailable selection".localized, systemImage: "checkmark").foregroundStyle(.secondary) }
            }
            Section {
                ForEach(options.filter { search.isEmpty || ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(search) }) { option in
                    choice(option.title, id: option.id, subtitle: option.value.text("provider", "model_id", "runtime"), disabled: option.value["enable"] == false || option.value["enabled"] == false)
                }
            }
            if loading { ProgressView() }
            else if let error { ErrorBanner(message: error, retry: retry) }
            else if options.isEmpty { Text("No options available".localized).foregroundStyle(.secondary) }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).searchable(text: $search)
    }
    private func choice(_ name: String, id: String, subtitle: String = "", disabled: Bool = false) -> some View {
        Button {
            selected = id; dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).foregroundStyle(.primary)
                    if disabled { Text("Disabled".localized).font(.caption).foregroundStyle(.secondary) }
                    else if !subtitle.isEmpty && subtitle != name { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected == id { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
        }.disabled(disabled && selected != id)
    }
}
