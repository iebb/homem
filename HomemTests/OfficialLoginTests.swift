import XCTest
@testable import Homem

@MainActor final class OfficialLoginTests: XCTestCase {
    override func tearDown() { StubURLProtocol.responseHeaders = [:]; StubURLProtocol.handler = nil; super.tearDown() }
    func cookie(domain: String = "app.memoh.net", path: String = "/", secure: Bool = true, expires: Date = Date().addingTimeInterval(3600)) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: "session", .value: "fixture-session", .domain: domain, .path: path, .expires: expires]
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }
    func client(cookies: [HTTPCookie] = [], teamID: String = "") -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        return APIClient(baseURL: OfficialServer.apiURL, session: URLSession(configuration: config), officialSession: OfficialSession(cookies: cookies, teamID: teamID))
    }
    func testReloadUsesPlatformAccountAndWorkspaceAvatarsWithoutReplacingPermissions() async throws {
        let api = client(cookies: [cookie()], teamID: "team-1")
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/api/memoh/users/me": return (200, Data(#"{"username":"workspace-user","role":"admin"}"#.utf8))
            case "/api/memoh/bots": return (200, Data(#"{"items":[]}"#.utf8))
            case "/api/v1/users/me":
                return (200, Data(#"{"user":{"username":"account-name","avatar_url":"/fallback.png"},"user_profile":{"display_name":"Account","avatar_url":"/account.png"}}"#.utf8))
            case "/api/v1/teams":
                return (200, Data(#"{"teams":[{"team":{"team_id":"other","name":"Other","avatar_url":"/other.png"}},{"team":{"team_id":"team-1","name":"Workspace","avatar_url":"/workspace.svg"}}]}"#.utf8))
            default: XCTFail("Unexpected identity request"); return (404, Data())
            }
        }
        let suite = "homem-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let vault = AccountVault(defaults: defaults)
        defer { for account in vault.accounts { vault.remove(account) }; defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(vault: vault, restore: false); store.api = api
        api.credentialAccount = "test-" + UUID().uuidString
        await store.reload()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.accountName, "Account")
        XCTAssertEqual(store.accountAvatarURL, "/account.png")
        XCTAssertEqual(store.workspace.avatarURL, "/workspace.svg")
        XCTAssertEqual(store.workspaceName, "Workspace")
        XCTAssertTrue(store.canAdmin)
    }
    func testRuntimeDesktopUsesGatewayTicketOriginAndProtocol() async throws {
        let api = client(cookies: [cookie()], teamID: "team-1")
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/ws-tickets")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Team-ID"), "team-1")
            return (200, Data(#"{"ticket":"fixture-ticket"}"#.utf8))
        }
        let request = try await api.runtimeDisplayRequest(sessionID: "fixture-display", token: "fixture-token")
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "app.memoh.net")
        XCTAssertEqual(request.url?.path, "/api/runtime-gateway/v1/display/fixture-display")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "ticket", value: "fixture-ticket")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://app.memoh.net")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "memoh-runtime-token.Zml4dHVyZS10b2tlbg")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
    func testCookiesAreScopedAndRoundTripWithoutIdentityProviderCredentials() throws {
        let session = OfficialSession(cookies: [cookie(), cookie(domain: "github.com"), cookie(domain: "memoh.net.evil.example"), cookie(secure: false), cookie(expires: .distantPast)], teamID: "team-1")
        let restored = try JSONDecoder().decode(OfficialSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.validCookies.count, 1)
        XCTAssertFalse(restored.validCookies[0].isHTTPOnly)
        let api = client(cookies: restored.validCookies, teamID: restored.teamID)
        let request = try api.request("/bots")
        XCTAssertEqual(request.url?.absoluteString, "https://app.memoh.net/api/memoh/bots")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Team-ID"), "team-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=fixture-session")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        api.baseURL = URL(string: "https://third-party.example/api")!
        XCTAssertThrowsError(try api.request("/bots"))
        let custom = APIClient(baseURL: api.baseURL, token: "custom-token")
        XCTAssertNil(try custom.request("/bots").value(forHTTPHeaderField: "Cookie"))
    }
    func testEmailCodeSetsCookieAndLoadsNestedWorkspaceMemberships() async throws {
        let api = client(); let login = OfficialLogin(client: api)
        login.email = " person@example.com "
        var paths: [String] = []
        StubURLProtocol.handler = { request in
            paths.append(request.url!.path)
            StubURLProtocol.responseHeaders = [:]
            switch request.url!.path {
            case "/api/v1/auth/email-code/send":
                let body = try officialTestBody(request)
                XCTAssertEqual(body["email"], "person@example.com")
                return (200, Data(#"{"resend_after":90}"#.utf8))
            case "/api/v1/auth/email-code/verify":
                StubURLProtocol.responseHeaders = ["Set-Cookie": "session=verified; Path=/; Secure; HttpOnly"]
                return (200, Data("{}".utf8))
            case "/api/v1/users/me":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=verified")
                return (200, Data(#"{"user":{"id":"person"}}"#.utf8))
            case "/api/v1/teams":
                return (200, Data(#"{"teams":[{"team":{"team_id":"team-1","name":"My workspace","avatar_url":"https://cdn.example/workspace.png"},"role":"TEAM_ROLE_OWNER"}]}"#.utf8))
            default: XCTFail("Unexpected endpoint"); return (404, Data())
            }
        }
        try await login.sendCode()
        XCTAssertEqual(login.step, .code)
        XCTAssertGreaterThan(login.resendAfter.timeIntervalSinceNow, 80)
        do { try await login.sendCode(); XCTFail("Must respect resend cooldown") } catch {}
        login.code = "123456"; try await login.verifyCode()
        XCTAssertEqual(login.step, .workspaces)
        XCTAssertEqual(login.teams.first?["team_id"], "team-1")
        XCTAssertEqual(login.teams.first?["avatar_url"], "https://cdn.example/workspace.png")
        XCTAssertEqual(paths.count, 4)
        XCTAssertFalse(api.persistOfficialSession)
        XCTAssertTrue(api.session.configuration.httpCookieStorage?.cookies?.first?.isHTTPOnly == true)
    }
    func testMFAAndInvalidCodeNeverCompleteSignInPrematurely() async throws {
        let login = OfficialLogin(client: client()); login.email = "person@example.com"; login.step = .code; login.code = "111111"
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("email-code/verify") { return (200, Data(#"{"mfa_required":true,"mfa_token":"challenge"}"#.utf8)) }
            XCTAssertEqual(request.url!.path, "/api/v1/auth/verify-mfa")
            let body = try officialTestBody(request)
            XCTAssertEqual(body["mfa_token"], "challenge")
            XCTAssertEqual(body["totp_code"], "222222")
            return (401, Data(#"{"message":"Invalid code"}"#.utf8))
        }
        try await login.verifyCode(); XCTAssertEqual(login.step, .mfa)
        login.code = "222222"
        do { try await login.verifyCode(); XCTFail("Invalid MFA must fail") } catch {}
        XCTAssertEqual(login.step, .mfa); XCTAssertTrue(login.teams.isEmpty)
    }
    func testOfficialSocketUsesTicketAndTeamWithoutBearerRefresh() async throws {
        let api = client(cookies: [cookie()], teamID: "team-1")
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/ws-tickets")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Team-ID"), "team-1")
            return (200, Data(#"{"ticket":"one-time-ticket"}"#.utf8))
        }
        let request = try await api.socketRequest("/bots/bot/web/ws")
        let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.queryItems?.first(where: { $0.name == "ticket" })?.value, "one-time-ticket")
        XCTAssertEqual(url.queryItems?.first(where: { $0.name == "team_id" })?.value, "team-1")
        var requests = 0
        StubURLProtocol.handler = { _ in requests += 1; return (401, Data(#"{"message":"Session expired"}"#.utf8)) }
        do { _ = try await api.call("/bots"); XCTFail("Expected expired session") } catch {}
        XCTAssertEqual(requests, 1); XCTAssertTrue(api.unauthorized)
    }
}

private func officialTestBody(_ request: URLRequest) throws -> JSONValue {
    if let data = request.httpBody { return try JSONDecoder().decode(JSONValue.self, from: data) }
    guard let stream = request.httpBodyStream else { throw ClientError.invalidResponse }
    stream.open(); defer { stream.close() }
    var data = Data(); var bytes = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&bytes, maxLength: bytes.count)
        guard count >= 0 else { throw ClientError.invalidResponse }
        if count == 0 { break }
        data.append(contentsOf: bytes.prefix(count))
    }
    return try JSONDecoder().decode(JSONValue.self, from: data)
}


@MainActor final class AccountSwitchingTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    var vault: AccountVault!
    override func setUp() {
        super.setUp()
        suite = "homem-accounts-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        vault = AccountVault(defaults: defaults)
    }
    override func tearDown() {
        for account in vault.accounts { vault.remove(account) }
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }
    func account(_ name: String, server: String = "https://fixture.invalid/api", official: Bool = false) -> SavedAccount {
        SavedAccount(id: UUID().uuidString, server: server, identity: name, name: name, avatarURL: "", official: official)
    }
    func testLegacyLoginAndDraftAreImportedOnce() async throws {
        let base = URL(string: "https://legacy-\(UUID().uuidString.lowercased()).invalid/api")!
        let draftKey = "draft|\(base.absoluteString)|bot|session"
        try Keychain.save("legacy-token", account: base.absoluteString)
        try Keychain.save("unfinished message", account: draftKey)
        defer { try? Keychain.save(nil, account: base.absoluteString); try? Keychain.save(nil, account: draftKey); StubURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let api = APIClient(baseURL: base, token: "legacy-token", session: URLSession(configuration: config))
        StubURLProtocol.handler = { request in
            (200, Data((request.url!.path.hasSuffix("/bots") ? "{\"items\":[]}" : "{\"id\":\"legacy-user\",\"username\":\"Legacy\"}").utf8))
        }
        let store = AppStore(vault: vault, restore: false); store.api = api
        await store.reload()
        XCTAssertNil(store.error)
        XCTAssertEqual(vault.accounts.count, 1)
        XCTAssertEqual(Keychain.read(vault.accounts[0].credentialKey), "legacy-token")
        XCTAssertEqual(Keychain.read("draft|\(api.draftScope)|bot|session"), "unfinished message")
        XCTAssertNil(Keychain.read(base.absoluteString)); XCTAssertNil(Keychain.read(draftKey))
        await store.reload()
        XCTAssertEqual(vault.accounts.count, 1)
        store.signOut()
        XCTAssertNil(AppStore(vault: vault).api)
    }
    func testTokenRefreshOnlyUpdatesItsOwnAccount() async throws {
        let first = account("first"), second = account("second")
        try vault.save(first, secret: "expired"); try vault.save(second, secret: "second-token")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: first.server)!, token: "expired", session: URLSession(configuration: config))
        api.credentialAccount = first.credentialKey
        defer { StubURLProtocol.handler = nil }
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/auth/refresh") { return (200, Data(#"{"access_token":"refreshed"}"#.utf8)) }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed" ? (200, Data("{}".utf8)) : (401, Data("{}".utf8))
        }
        _ = try await api.call("/bots")
        XCTAssertEqual(Keychain.read(first.credentialKey), "refreshed")
        XCTAssertEqual(Keychain.read(second.credentialKey), "second-token")
    }
    func testSameServerAccountsKeepTokensAndDraftsSeparate() throws {
        let first = account("first"), second = account("second")
        try vault.save(first, secret: "first-token")
        try vault.save(second, secret: "second-token")
        let a = try vault.client(for: first), b = try vault.client(for: second)
        XCTAssertEqual(try a.request("/bots").value(forHTTPHeaderField: "Authorization"), "Bearer first-token")
        XCTAssertEqual(try b.request("/bots").value(forHTTPHeaderField: "Authorization"), "Bearer second-token")
        XCTAssertNotEqual(a.draftScope, b.draftScope)
        try Keychain.save("first draft", account: "draft|\(a.draftScope)|bot|session")
        try Keychain.save("second draft", account: "draft|\(b.draftScope)|bot|session")
        vault.activate(first.id)
        vault.remove(first)
        XCTAssertNil(vault.activeID)
        XCTAssertNil(Keychain.read(first.credentialKey))
        XCTAssertNil(Keychain.read("draft|\(a.draftScope)|bot|session"))
        XCTAssertEqual(Keychain.read(second.credentialKey), "second-token")
        XCTAssertEqual(Keychain.read("draft|\(b.draftScope)|bot|session"), "second draft")
        XCTAssertEqual(vault.accounts, [second])
    }
    func testOfficialAccountsRestoreIndependentCookiesAndWorkspaces() throws {
        let first = account("first", server: OfficialServer.apiURL.absoluteString, official: true)
        let second = account("second", server: OfficialServer.apiURL.absoluteString, official: true)
        for (item, team) in [(first, "team-one"), (second, "team-two")] {
            let cookie = HTTPCookie(properties: [.name: "session", .value: item.name, .domain: "app.memoh.net", .path: "/", .secure: "TRUE"])!
            let session = OfficialSession(cookies: [cookie], teamID: team)
            try vault.save(item, secret: JSONEncoder().encode(session).base64EncodedString())
        }
        let a = try vault.client(for: first), b = try vault.client(for: second)
        XCTAssertEqual(try a.request("/bots").value(forHTTPHeaderField: "Cookie"), "session=first")
        XCTAssertEqual(try b.request("/bots").value(forHTTPHeaderField: "Cookie"), "session=second")
        XCTAssertEqual(try a.request("/bots").value(forHTTPHeaderField: "X-Team-ID"), "team-one")
        XCTAssertEqual(try b.request("/bots").value(forHTTPHeaderField: "X-Team-ID"), "team-two")
        let scope = a.draftScope
        a.officialSession?.teamID = "other-workspace"
        XCTAssertNotEqual(scope, a.draftScope)
        XCTAssertNotEqual(a.draftScope, b.draftScope)
        XCTAssertEqual(a.credentialAccount, first.credentialKey)
        vault.activate(second.id)
        let restored = AppStore(vault: vault)
        XCTAssertEqual(restored.api?.officialSession?.teamID, "team-two")
        XCTAssertEqual(restored.activeAccountID, second.id)
    }
    func testSwitchResetsNavigationAndSignOutRemovesOnlySelectedAccount() async throws {
        let first = account("first"), second = account("second", server: "https://other.invalid/api")
        try vault.save(first, secret: "first-token"); try vault.save(second, secret: "second-token")
        vault.activate(first.id)
        let store = AppStore(vault: vault)
        let oldClient = try XCTUnwrap(store.api), oldConnection = store.connectionID
        // Cancel the load immediately: account selection itself must survive offline use.
        let task = Task { try await store.switchAccount(second) }
        task.cancel()
        try await task.value
        XCTAssertTrue(oldClient.signedOut)
        XCTAssertNotEqual(store.connectionID, oldConnection)
        XCTAssertEqual(store.activeAccountID, second.id)
        XCTAssertEqual(store.api?.baseURL.host, "other.invalid")
        XCTAssertEqual(store.savedAccounts.count, 2)
        store.signOut()
        XCTAssertNil(store.api)
        XCTAssertEqual(store.savedAccounts, [first])
        XCTAssertEqual(Keychain.read(first.credentialKey), "first-token")
        XCTAssertNil(Keychain.read(second.credentialKey))
        XCTAssertTrue(vault.migrated)
    }
    func testMarketplaceSelectsDarkAndDetailIconsAndRejectsInvalidDigests() {
        let card = String(repeating: "a", count: 64), dark = String(repeating: "b", count: 64), detail = String(repeating: "c", count: 64)
        let icon: JSONValue = ["card": ["digest": .string(card)], "dark": ["digest": .string(dark)], "detail": ["digest": .string(detail)]]
        XCTAssertEqual(MarketplaceIconSource.path(icon, dark: true), "supermarket/artifacts/icon/" + dark)
        XCTAssertEqual(MarketplaceIconSource.path(icon, dark: false), "supermarket/artifacts/icon/" + card)
        XCTAssertEqual(MarketplaceIconSource.path(icon, dark: false, detail: true), "supermarket/artifacts/icon/" + detail)
        XCTAssertEqual(MarketplaceIconSource.path(["card": ["digest": .string(card)]], dark: true), "supermarket/artifacts/icon/" + card)
        XCTAssertNil(MarketplaceIconSource.path(["card": ["digest": "../../bad"]], dark: false))
    }
}
