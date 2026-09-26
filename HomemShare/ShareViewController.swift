import UIKit
import SwiftUI
import Observation

final class ShareViewController: UIViewController {
    private var model: ShareModel?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || view.window == nil { model?.cancel() }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let model = ShareModel(providers: providers)
        self.model = model
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            model.cancel()
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host); view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

@MainActor @Observable final class ShareModel {
    let providers: [NSItemProvider]
    let directory: URL
    let accounts: [SavedAccount]
    var accountID: String
    var teamID = ""
    var teams: [JSONValue] = []
    var bots: [Record] = []
    var botID = ""
    var files: [SharedFile] = []
    var uploaded = Set<URL>()
    var destination = ""
    var loading = false
    var saving = false
    var complete = false
    var error: String?
    var client: ShareUploadClient?
    private var selectionVersion = UUID()
    private var uploadTask: Task<Void, Never>?
    private var cancelled = false
    private var folderCreated = false
    init(providers: [NSItemProvider]) {
        self.providers = providers
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HomemShare-" + UUID().uuidString, isDirectory: true)
        let saved = SharedAccountDirectory.restore()
        accounts = saved.accounts
        accountID = saved.activeID.flatMap { id in saved.accounts.contains { $0.id == id } ? id : nil } ?? saved.accounts.first?.id ?? ""
    }
    var canSave: Bool { !loading && !saving && !complete && !files.isEmpty && !botID.isEmpty && client != nil }
    var selectionLocked: Bool { saving || !uploaded.isEmpty || complete }
    func prepare() async {
        guard files.isEmpty, !cancelled else { return }
        loading = true
        do {
            guard !providers.isEmpty, providers.count <= 20 else { throw ClientError.message("Share up to 20 files at a time.".localized) }
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var result: [SharedFile] = []
            for provider in providers {
                try Task.checkCancellation()
                result.append(try await SharedFiles.load(provider, into: directory))
                guard !cancelled else { return }
            }
            files = result
            await selectAccount()
        } catch { if !cancelled { self.error = error.localizedDescription; loading = false } }
    }
    func selectAccount() async {
        guard !selectionLocked else { return }
        let version = UUID(); selectionVersion = version
        client?.cancel(); client = nil; bots = []; teams = []; botID = ""; teamID = ""
        loading = true; error = nil; resetDestination()
        defer { if selectionVersion == version { loading = false } }
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        do {
            let next = try ShareUploadClient(account: account)
            client = next; teamID = next.teamID
            if account.official {
                let response = try await next.call("/teams", platform: true)
                guard selectionVersion == version, !cancelled else { return }
                teams = OfficialIdentity.teams(response)
            }
            let response = try await next.call("/bots")
            guard selectionVersion == version, !cancelled else { return }
            bots = response.items.map(Record.init)
        } catch { if selectionVersion == version, !cancelled { self.error = error.localizedDescription } }
    }
    func selectTeam() async {
        guard let client, !selectionLocked else { return }
        let version = UUID(); selectionVersion = version
        client.teamID = teamID; botID = ""; bots = []; loading = true; error = nil; resetDestination()
        defer { if selectionVersion == version { loading = false } }
        do {
            let response = try await client.call("/bots")
            guard selectionVersion == version, !cancelled else { return }
            bots = response.items.map(Record.init)
        } catch { if selectionVersion == version, !cancelled { self.error = error.localizedDescription } }
    }
    func resetDestination() { if uploaded.isEmpty { destination = ""; folderCreated = false } }
    func save() {
        guard canSave, let client else { return }
        saving = true; error = nil
        let selectedBot = botID
        if destination.isEmpty {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmm"
            destination = "/data/Shared-" + formatter.string(from: .now) + "-" + UUID().uuidString.prefix(8)
        }
        uploadTask = Task {
            defer { saving = false }
            do {
                if !folderCreated {
                    _ = try await client.call("/bots/\(selectedBot.pathComponent)/container/fs/mkdir", method: "POST", body: ["path": .string(destination)])
                    folderCreated = true
                }
                for file in files where !uploaded.contains(file.id) {
                    try Task.checkCancellation()
                    try await client.upload(file, botID: selectedBot, destination: destination + "/" + file.name, directory: directory)
                    uploaded.insert(file.id)
                }
                guard !cancelled else { return }
                complete = true
            } catch { if !cancelled { self.error = error.localizedDescription } }
        }
    }
    func cancel() {
        cancelled = true; selectionVersion = UUID(); uploadTask?.cancel(); client?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct ShareView: View {
    @Bindable var model: ShareModel
    let close: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                if model.complete {
                    Section {
                        Label("Saved to workspace".localized, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                        Text(model.bots.first { $0.id == model.botID }?.title ?? "")
                        Text(model.destination).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Find these files in the bot’s Files tab.".localized).font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        DisclosureGroup(model.files.count == 1 ? model.files[0].name : AppLocalization.format("%lld files", model.files.count)) {
                            ForEach(model.files) { file in
                                HStack {
                                    Label(file.name, systemImage: "doc").lineLimit(2)
                                    Spacer()
                                    if model.uploaded.contains(file.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                    else { Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    if model.accounts.isEmpty {
                        Section { Text("Open Homem and sign in to an account, then share your files again.".localized).foregroundStyle(.secondary) }
                    } else {
                        Section {
                            Picker("Account".localized, selection: $model.accountID) {
                                ForEach(model.accounts) { account in
                                    Text(account.name + " · " + account.host).tag(account.id)
                                }
                            }.disabled(model.selectionLocked || model.loading)
                                .onChange(of: model.accountID) { _, _ in Task { await model.selectAccount() } }
                            if !model.teams.isEmpty {
                                Picker("Workspace".localized, selection: $model.teamID) {
                                    ForEach(Array(model.teams.enumerated()), id: \.offset) { _, team in
                                        Text(team.text("name", "slug").nonEmpty ?? "Workspace".localized).tag(team["team_id"].string)
                                    }
                                }.disabled(model.selectionLocked || model.loading)
                                    .onChange(of: model.teamID) { old, new in
                                        if !model.loading, !old.isEmpty, !new.isEmpty, old != new { Task { await model.selectTeam() } }
                                    }
                            }
                        }
                        Section("Choose an agent".localized) {
                            ForEach(model.bots) { bot in
                                Button {
                                    model.botID = bot.id; model.resetDestination()
                                } label: {
                                    HStack(spacing: 12) {
                                        ShareAvatar(name: bot.title, source: bot.value.avatarURL, client: model.client)
                                        Text(bot.title).foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: model.botID == bot.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(model.botID == bot.id ? Color.accentColor : Color.secondary)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(model.selectionLocked)
                            }
                            if !model.loading && model.bots.isEmpty && model.error == nil {
                                Text("No agents in this workspace.".localized).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if model.loading { ProgressView().frame(maxWidth: .infinity) }
                    if let error = model.error {
                        Section {
                            Text(error).foregroundStyle(.red)
                            if !model.saving && model.uploaded.isEmpty {
                                Button("Try again".localized) {
                                    Task { if model.files.isEmpty { await model.prepare() } else { await model.selectAccount() } }
                                }
                            }
                        }
                    }
                    if !model.files.isEmpty && !model.accounts.isEmpty {
                        Section {
                            Button { model.save() } label: {
                                HStack {
                                    Spacer()
                                    if model.saving {
                                        ProgressView()
                                        Text(AppLocalization.format("Saving %lld of %lld…", min(model.uploaded.count + 1, model.files.count), model.files.count))
                                    } else { Text((model.uploaded.isEmpty ? "Save to workspace" : "Retry remaining files").localized).fontWeight(.semibold) }
                                    Spacer()
                                }
                            }.disabled(!model.canSave)
                        } footer: {
                            Text("Files are saved in a new folder. Existing files are kept.".localized)
                        }
                    }
                }
            }.navigationTitle("Save to Homem".localized).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if model.complete {
                        ToolbarItem(placement: .confirmationAction) { Button("Done".localized, action: close) }
                    } else {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel".localized, action: close) }
                    }
                }
        }.task { await model.prepare() }
    }
}

private struct ShareAvatar: View {
    let name: String
    let source: String
    let client: ShareUploadClient?
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Text(String(name.prefix(1))).font(.headline).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.secondary.opacity(0.12)) }
        }.frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
            .task(id: source) {
                guard !source.isEmpty, let data = try? await client?.avatarData(source) else { return }
                image = UIImage(data: data)
            }
    }
}
