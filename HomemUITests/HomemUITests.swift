import XCTest

final class HomemUITests: XCTestCase {
    @MainActor func testCustomServerSignInOpensWorkspace() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-onboarding"]; app.launch()
        func connectFixture() {
            let custom = app.buttons["Use another server"]
            if !custom.isHittable { app.swipeUp() }
            custom.tap()
            let address = app.textFields["serverAddress"]
            XCTAssertTrue(address.waitForExistence(timeout: 5))
            address.tap()
            if let current = address.value as? String, current.hasPrefix("http") { address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)) }
            address.typeText("http://127.0.0.1:18765/api")
            let username = app.textFields["Username"]
            username.tap(); username.typeText("fixture")
            let password = app.secureTextFields["Password"]
            password.tap(); password.typeText("fixture-password")
            app.swipeUp()
            app.buttons["connectServer"].tap()
        }
        connectFixture()
        XCTAssertTrue(app.buttons["workspacePicker"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["allowDataSharing"].exists)
        selectTab("Settings", in: app)
        XCTAssertFalse(app.buttons["AI data sharing"].exists)
        capture(app, "Connected workspace settings")
    }
    @MainActor func testWorkspaceToolbarAndAddAccountCanBeCancelled() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        let workspace = app.buttons["workspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        app.buttons["manageAccounts"].tap()
        XCTAssertTrue(app.buttons["addAccount"].waitForExistence(timeout: 5))
        app.buttons["addAccount"].tap()
        XCTAssertTrue(app.buttons["officialSignIn"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["exploreDemo"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["addAccount"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        capture(app, "Workspace toolbar")
    }
    @MainActor func testOfficialEmailIsPrimaryAndCustomServerRemainsAvailable() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-onboarding"]; app.launch()
        let official = app.buttons["officialSignIn"]
        XCTAssertTrue(official.waitForExistence(timeout: 10))
        if !official.isHittable { app.swipeUp() }
        official.tap()
        let email = app.textFields["officialEmail"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        let send = app.buttons["sendOfficialCode"]
        XCTAssertFalse(send.isEnabled)
        email.tap(); email.typeText("not-an-email")
        XCTAssertFalse(send.isEnabled)
        // Clear without sending any mail or touching a production account.
        email.tap(); email.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        email.typeText("person@example.com")
        XCTAssertTrue(send.isEnabled)
        capture(app, "Official email sign-in")
        app.buttons["Cancel"].tap()
        let custom = app.buttons["Use another server"]
        if !custom.isHittable { app.swipeUp() }
        custom.tap()
        app.swipeUp()
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Use an access token"].exists)
        capture(app, "Third-party server sign-in")
    }
    @MainActor func testOnboardingAndScreenshots() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-onboarding"]; app.launch()
        XCTAssertTrue(app.staticTexts["Memoh, on your iPhone."].waitForExistence(timeout: 10))
        capture(app, "Onboarding")
        let demo = app.buttons["exploreDemo"]
        if !demo.isHittable { app.swipeUp() }
        demo.tap()
        XCTAssertTrue(app.buttons["conversation_welcome"].waitForExistence(timeout: 5))
        capture(app, "Conversations")
        selectTab("Agents", in: app)
        XCTAssertTrue(app.buttons["createAgent"].waitForExistence(timeout: 5))
        capture(app, "Agent overview")
        selectTab("Library", in: app)
        capture(app, "Library")
        app.buttons["Schedules"].tap()
        XCTAssertTrue(app.staticTexts["Morning perspective"].waitForExistence(timeout: 5))
        capture(app, "Schedules")
    }
    @MainActor func testNewChatComposerAndKeyboardDismissal() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        XCTAssertTrue(app.buttons["New conversation"].waitForExistence(timeout: 10))
        app.buttons["New conversation"].tap()
        let message = app.textFields["newChatMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["startConversation"].isEnabled)
        XCTAssertFalse(app.textFields["Acp Runtime Id"].exists)
        XCTAssertTrue(app.buttons["Attach"].exists)
        app.buttons["newChatRunLocation"].tap()
        XCTAssertTrue(app.buttons["Studio Mac"].waitForExistence(timeout: 3))
        capture(app, "Workspace icon dropdown")
        app.buttons["Studio Mac"].tap()
        let agentMenu = app.navigationBars["New chat"].buttons["agentPickerMenu"]
        XCTAssertEqual(agentMenu.value as? String, "Atlas")
        agentMenu.tap()
        capture(app, "Agent avatar dropdown")
        app.buttons["Mika"].tap()
        XCTAssertEqual(agentMenu.value as? String, "Mika")
        XCTAssertTrue(app.buttons["newChatRunLocation"].label.contains("Agent default"))
        capture(app, "Simple new chat")
        message.tap(); message.typeText("Plan a calm afternoon")
        app.buttons["startConversation"].tap()
        let composer = app.textFields["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Plan a calm afternoon"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This is a local demo reply.")).firstMatch.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("A follow-up")
        XCTAssertTrue(app.buttons["hideChatKeyboard"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Done"].exists)
        capture(app, "Keyboard composer")
        app.buttons["hideChatKeyboard"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }
    @MainActor func testDeleteAlertNamesConversationAndCancelPreservesIt() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        let conversation = app.buttons["conversation_research"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let alert = app.alerts["Delete conversation?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["“A weekend in Kyoto” will be permanently deleted."].exists)
        capture(app, "Centered delete confirmation")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(conversation.exists)
    }
    @MainActor func testThemePreferencesPersist() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        selectTab("Settings", in: app)
        app.swipeUp()
        let appearance = app.buttons["appearancePicker"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap(); app.buttons["Dark"].tap()
        app.buttons["accentPicker"].tap(); app.buttons["Rose"].tap()
        app.terminate(); app.launch()
        selectTab("Settings", in: app); app.swipeUp()
        XCTAssertTrue(app.buttons["appearancePicker"].label.contains("Dark"))
        XCTAssertTrue(app.buttons["accentPicker"].label.contains("Rose"))
        selectTab("Chats", in: app); app.buttons["New conversation"].tap()
        XCTAssertTrue(app.textFields["newChatMessage"].waitForExistence(timeout: 5))
        app.textFields["newChatMessage"].tap(); app.textFields["newChatMessage"].typeText("A little color")
        capture(app, "Dark Rose new chat")
        app.buttons["Cancel"].tap()
        selectTab("Settings", in: app)
        app.buttons["appearancePicker"].tap(); app.buttons["System"].tap()
        app.buttons["accentPicker"].tap(); app.buttons["System"].tap()
    }
    @MainActor func testChineseLocalization() throws { try localizedFlow("zh-Hans", tabs: ["聊天", "智能体", "资料库", "设置"], files: "文件", desktop: "桌面", newChat: "新聊天", signIn: "登录 Memoh", email: "邮箱地址") }
    @MainActor func testSpanishLocalization() throws { try localizedFlow("es", tabs: ["Chats", "Agentes", "Biblioteca", "Ajustes"], files: "Archivos", desktop: "Escritorio", newChat: "Nuevo chat", signIn: "Iniciar sesión en Memoh", email: "Correo electrónico") }
    @MainActor func testJapaneseLocalization() throws { try localizedFlow("ja", tabs: ["チャット", "エージェント", "ライブラリ", "設定"], files: "ファイル", desktop: "デスクトップ", newChat: "新しいチャット", signIn: "Memohにログイン", email: "メールアドレス") }
    @MainActor private func localizedFlow(_ language: String, tabs: [String], files: String, desktop: String, newChat: String, signIn: String, email: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        app.launch()
        XCTAssertTrue(app.buttons["conversation_welcome"].waitForExistence(timeout: 10))
        selectTab(tabs[1], in: app)
        app.staticTexts["Atlas"].firstMatch.tap()
        XCTAssertTrue(app.buttons["workspaceTool_files"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["workspaceTool_files"].label, files)
        XCTAssertEqual(app.buttons["workspaceTool_desktop"].label, desktop)
        capture(app, "\(language) agent details")
        app.buttons["workspaceTool_desktop"].tap()
        XCTAssertTrue(app.navigationBars[desktop].waitForExistence(timeout: 5))
        selectTab(tabs[0], in: app)
        app.buttons["newConversation"].tap()
        XCTAssertTrue(app.navigationBars[newChat].waitForExistence(timeout: 5))
        capture(app, "\(language) new chat")
        app.terminate()
        app.launchArguments = ["--ui-onboarding", "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        app.launch()
        let login = app.buttons["officialSignIn"]
        XCTAssertTrue(login.waitForExistence(timeout: 10))
        XCTAssertEqual(login.label, signIn)
        login.tap()
        XCTAssertTrue(app.textFields["officialEmail"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["officialEmail"].placeholderValue, email)
        capture(app, "\(language) email sign-in")
    }
    @MainActor func testCompactToolActivity() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--ui-tool-activity", "-AppleLanguages", "(en)"]; app.launch()
        app.buttons["conversation_welcome"].tap()
        let activity = app.buttons["toolActivity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertTrue(activity.label.contains("3 actions"))
        XCTAssertFalse(app.staticTexts["update_schedule"].exists)
        capture(app, "Compact activity summary")
        activity.tap()
        XCTAssertTrue(app.staticTexts["Schedule"].waitForExistence(timeout: 5))
        capture(app, "Expanded activity")
    }
    @MainActor private func selectTab(_ name: String, in app: XCUIApplication) {
        let compactTab = app.tabBars.buttons[name]
        if compactTab.exists { compactTab.tap() }
        else { app.buttons[name].firstMatch.tap() } // iPad uses a floating tab control.
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testDemoConversationAndWorkspace() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        XCTAssertTrue(app.buttons["conversation_welcome"].waitForExistence(timeout: 10))
        app.buttons["conversation_welcome"].tap()
        let input = app.textFields["messageComposer"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("Hello from iOS")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["Hello from iOS"].waitForExistence(timeout: 5))
        let chat = XCTAttachment(screenshot: app.screenshot()); chat.name = "Native chat"; chat.lifetime = .keepAlways; add(chat)
        selectTab("Agents", in: app)
        XCTAssertTrue(app.buttons["createAgent"].waitForExistence(timeout: 5))
        let agents = XCTAttachment(screenshot: app.screenshot()); agents.name = "Agents"; agents.lifetime = .keepAlways; add(agents)
        app.staticTexts["Atlas"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["A dedicated workspace, tools, and memories. All yours."].exists)
        capture(app, "Workspace tools")
        app.buttons["Files"].tap()
        XCTAssertTrue(app.staticTexts["AGENTS.md"].waitForExistence(timeout: 5))
        app.staticTexts["AGENTS.md"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews.firstMatch.value as? String ?? "").contains("workspace of your own"))
    }
    @MainActor func testCreateMemoryAndScheduleNavigation() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        selectTab("Library", in: app)
        app.buttons["Memories"].tap()
        XCTAssertTrue(app.staticTexts["Prefers thoughtful answers with concrete examples."].waitForExistence(timeout: 5))
        app.buttons["Add Memories"].tap()
        let message = app.textFields["Message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5)); message.tap(); message.typeText("Remember this native app test")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Remember this native app test"].waitForExistence(timeout: 5))
        let library = XCTAttachment(screenshot: app.screenshot()); library.name = "Created memory"; library.lifetime = .keepAlways; add(library)
        selectTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Providers"].waitForExistence(timeout: 5))
        app.buttons["Providers"].tap()
        XCTAssertTrue(app.staticTexts["Example provider"].waitForExistence(timeout: 5))
    }
}
