import Foundation

/// Small extension-safe client: shares authentication conventions with the app,
/// without loading chat, terminal, or desktop runtimes into the share process.
@MainActor final class ShareUploadClient {
    let account: SavedAccount
    let baseURL: URL
    let session: URLSession
    var teamID: String
    private var token: String
    private var official: OfficialSession?
    init(account: SavedAccount, session: URLSession? = nil) throws {
        guard let base = URL(string: account.server), ["http", "https"].contains(base.scheme), base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else { throw ClientError.invalidURL }
        self.account = account; self.baseURL = base
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 180
        self.session = session ?? URLSession(configuration: config, delegate: SafeRedirectDelegate(), delegateQueue: nil)
        if account.official {
            guard base == OfficialServer.apiURL, let saved = OfficialSession.restore(account: account.credentialKey) else {
                throw ClientError.message("Open Homem and sign in again, then share your files.".localized)
            }
            official = saved; teamID = saved.teamID; token = ""
            for cookie in saved.validCookies { self.session.configuration.httpCookieStorage?.setCookie(cookie) }
        } else {
            guard let saved = Keychain.read(account.credentialKey), !saved.isEmpty else {
                throw ClientError.message("Open Homem and sign in again, then share your files.".localized)
            }
            token = saved; teamID = ""
        }
    }
    func cancel() { session.invalidateAndCancel() }
    func request(_ path: String, method: String = "GET", body: JSONValue? = nil, platform: Bool = false) throws -> URLRequest {
        let base = platform ? OfficialServer.platformURL : baseURL
        guard !platform || account.official else { throw ClientError.invalidURL }
        var request = URLRequest(url: base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if account.official {
            request.setValue(OfficialServer.origin.absoluteString, forHTTPHeaderField: "Origin")
            if !platform { request.setValue(teamID, forHTTPHeaderField: "X-Team-ID") }
            let cookies = session.configuration.httpCookieStorage?.cookies(for: request.url!)?.filter(OfficialServer.accepts) ?? []
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: key) }
        } else { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try body.encoded; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    func call(_ path: String, method: String = "GET", body: JSONValue? = nil, platform: Bool = false) async throws -> JSONValue {
        try await perform(request(path, method: method, body: body, platform: platform))
    }
    func perform(_ request: URLRequest, file: URL? = nil, retry: Bool = true) async throws -> JSONValue {
        // Recheck removal before requests, so an open share sheet cannot reuse a removed login.
        guard Keychain.read(account.credentialKey) != nil else { throw ClientError.message("Open Homem and sign in again, then share your files.".localized) }
        let (data, response): (Data, URLResponse)
        if let file { (data, response) = try await session.upload(for: request, fromFile: file) }
        else { (data, response) = try await session.data(for: request) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        if account.official, Keychain.read(account.credentialKey) != nil, let official {
            // Keep the app's selected workspace unchanged when sharing to a different one.
            let saved = OfficialSession(cookies: session.configuration.httpCookieStorage?.cookies ?? [], teamID: OfficialSession.restore(account: account.credentialKey)?.teamID ?? official.teamID)
            try saved.save(account: account.credentialKey)
        }
        if http.statusCode == 401, retry, !account.official {
            let refreshed = try await perform(self.request("/auth/refresh", method: "POST"), retry: false)
            guard let next = refreshed["access_token"].string.nonEmpty else { throw ClientError.invalidResponse }
            guard Keychain.read(account.credentialKey) != nil else { throw ClientError.message("Open Homem and sign in again, then share your files.".localized) }
            try Keychain.save(next, account: account.credentialKey); token = next
            var renewed = request; renewed.setValue("Bearer " + next, forHTTPHeaderField: "Authorization")
            return try await perform(renewed, file: file, retry: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ClientError.message("Open Homem and sign in again, then share your files.".localized) }
            let value = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
            throw ClientError.http(http.statusCode, value.text("message", "error", "detail").nonEmpty ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        if data.isEmpty { return [:] }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    func upload(_ file: SharedFile, botID: String, destination: String, directory: URL) async throws {
        let boundary = "Homem-" + UUID().uuidString
        let body = try SharedFiles.multipart(file: file, destination: destination, boundary: boundary, directory: directory)
        defer { try? FileManager.default.removeItem(at: body) }
        var request = try request("/bots/\(botID.pathComponent)/container/fs/upload", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request, file: body)
    }
    func avatarData(_ source: String) async throws -> Data? {
        guard let url = URL(string: source, relativeTo: URL(string: "/", relativeTo: baseURL))?.absoluteURL,
              ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil else { return nil }
        if url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port {
            var request = try request("/users/me"); request.url = url
            let (data, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200 ? data : nil
        }
        // External/CDN avatars are fetched without the account's credentials.
        return try await URLSession.shared.data(from: url).0
    }
}
