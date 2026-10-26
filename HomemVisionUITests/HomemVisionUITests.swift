import XCTest

final class HomemVisionUITests: XCTestCase {
    @MainActor func testResourceMetricsStayCollapsedUntilRequested() throws {
        let app = XCUIApplication()
        app.launchFixture(scenario: "resource-metrics", useAccessToken: true)
        XCTAssertTrue(app.buttons["Agents"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["Agents"].firstMatch.tap()
        let resources = app.buttons["agentResources_atlas"]
        let terminal = app.buttons["agentTool_atlas_terminal"]
        let desktop = app.buttons["agentTool_atlas_desktop"]
        XCTAssertTrue(resources.waitForExistence(timeout: 10))
        XCTAssertEqual(resources.value as? String, "Collapsed")
        XCTAssertEqual(try app.fixtureRequestCount("/ui-api/bots/atlas/container/metrics"), 0)
        let terminalFrame = terminal.frame
        let desktopFrame = desktop.frame
        resources.tap()
        let cpu = app.otherElements["agentResource_atlas_CPU"]
        XCTAssertTrue(cpu.waitForExistence(timeout: 10))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "0.5"), object: cpu)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        XCTAssertEqual(try app.fixtureRequestCount("/ui-api/bots/atlas/container/metrics"), 1)
        capture(app, "Resource metrics opened on demand")
        app.buttons["closeAgentResources_atlas"].tap()
        XCTAssertEqual(resources.value as? String, "Collapsed")
        XCTAssertEqual(terminal.frame.minY, terminalFrame.minY, accuracy: 1)
        XCTAssertEqual(desktop.frame.minY, desktopFrame.minY, accuracy: 1)
        XCTAssertTrue(terminal.isHittable)
        XCTAssertTrue(desktop.isHittable)
        capture(app, "Stable workspace shortcuts with resource metrics collapsed")
    }
    @MainActor func testAccountSwitchKeepsExistingChatAndFilesConnected() throws {
        let app = XCUIApplication()
        app.launchFixture()
        XCTAssertTrue(app.buttons["conversation_welcome"].waitForExistence(timeout: 20))
        app.buttons["conversation_welcome"].tap()
        let composer = app.textFields["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        if let existing = composer.value as? String, !existing.isEmpty, existing != composer.placeholderValue {
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        composer.typeText("Still connected to the first account")
        let firstConnections = try app.fixtureRequestCount("connections:first")

        app.buttons["workspacePicker"].tap()
        app.buttons["manageAccounts"].tap()
        XCTAssertTrue(app.buttons["addAccount"].waitForExistence(timeout: 10))
        app.buttons["addAccount"].tap()
        app.signInToFixture(username: "fixture-two")
        XCTAssertTrue(app.buttons["conversation_welcome"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["conversation_welcome"].label.contains("Second account conversation"))
        XCTAssertTrue(composer.exists)
        XCTAssertEqual(composer.value as? String, "Still connected to the first account")
        XCTAssertFalse(app.staticTexts["Workspace unavailable"].exists)
        composer.tap()
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Verified native WebSocket response.")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(try app.fixtureRequestCount("messages:first"), 1)
        XCTAssertEqual(try app.fixtureRequestCount("messages:second"), 0)
        XCTAssertEqual(try app.fixtureRequestCount("connections:first"), firstConnections, "The first chat must keep its existing connection")

        // Open a tool from the old account while the launcher selects the new
        // one. Keep it visible while switching the launcher in both directions.
        app.buttons["spatialNewWindow"].firstMatch.tap()
        app.buttons["Files"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["AGENTS.md"].waitForExistence(timeout: 10))
        app.buttons["workspacePicker"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND NOT label CONTAINS %@", "switchAccount_", "Fixture User", "Second")).firstMatch.tap()
        XCTAssertTrue(app.buttons["conversation_research"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["AGENTS.md"].exists)
        XCTAssertTrue(composer.exists)
        app.buttons["workspacePicker"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "switchAccount_", "Second Fixture User")).firstMatch.tap()
        XCTAssertTrue(app.buttons["conversation_welcome"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["conversation_welcome"].label.contains("Second account conversation"))
        XCTAssertTrue(app.staticTexts["AGENTS.md"].exists)

        app.buttons["conversation_welcome"].tap()
        let secondChat = app.descendants(matching: .any).matching(identifier: "spatialContent_chat")
            .matching(NSPredicate(format: "value == %@", "Second Fixture User")).firstMatch
        XCTAssertTrue(secondChat.waitForExistence(timeout: 10))
        let secondComposer = secondChat.textFields["messageComposer"]
        XCTAssertTrue(secondComposer.waitForExistence(timeout: 10))
        secondComposer.tap(); secondComposer.typeText("A separate account connection")
        secondChat.buttons["sendMessage"].tap()
        XCTAssertTrue(secondChat.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Verified native WebSocket response.")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(try app.fixtureRequestCount("messages:first"), 1)
        XCTAssertEqual(try app.fixtureRequestCount("messages:second"), 1)
        XCTAssertEqual(app.textFields.matching(identifier: "messageComposer").count, 2)
        XCTAssertTrue(app.staticTexts["AGENTS.md"].exists)
        capture(app, "Two accounts with live native chat and file windows")

        let secondConnections = try app.fixtureRequestCount("connections:second")
        app.buttons["workspacePicker"].tap()
        app.buttons["manageAccounts"].tap()
        let firstAccount = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND NOT label CONTAINS %@", "savedAccount_", "Fixture User", "Second")).firstMatch
        XCTAssertTrue(firstAccount.waitForExistence(timeout: 10))
        firstAccount.press(forDuration: 1)
        app.buttons["Remove account"].tap()
        XCTAssertTrue(app.alerts["Remove account?"].waitForExistence(timeout: 5))
        app.alerts["Remove account?"].buttons["Remove account"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Workspace unavailable"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["AGENTS.md"].exists)
        XCTAssertEqual(app.textFields.matching(identifier: "messageComposer").count, 1)
        XCTAssertTrue(secondComposer.exists)
        secondComposer.tap(); secondComposer.typeText("Still connected after removing the other account")
        secondChat.buttons["sendMessage"].tap()
        let deliveryDeadline = Date().addingTimeInterval(10)
        while try app.fixtureRequestCount("messages:second") < 2, Date() < deliveryDeadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(try app.fixtureRequestCount("messages:second"), 2)
        XCTAssertEqual(try app.fixtureRequestCount("connections:second"), secondConnections)
        capture(app, "Removing one account leaves the other account's window connected")
    }

    @MainActor func testLoginTypingNeverSubmitsEmailOrCodesAutomatically() throws {
        let app = XCUIApplication()
        app.resetFixture()
        app.launchArguments = ["--ui-onboarding"]
        app.launchEnvironment["HOMEM_OFFICIAL_LOGIN_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["officialSignIn"].waitForExistence(timeout: 20))
        app.buttons["officialSignIn"].tap()
        let email = app.textFields["officialEmail"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        let send = app.buttons["sendOfficialCode"]
        XCTAssertFalse(send.isEnabled)
        email.tap(); email.typeText("person@example.com\n")
        XCTAssertTrue(email.exists, "Typing Return must not send a sign-in email on visionOS")
        XCTAssertFalse(app.textFields["officialCode"].exists)
        XCTAssertGreaterThanOrEqual(send.frame.height, 60)
        send.doubleTap()
        let code = app.textFields["officialCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        XCTAssertEqual(try app.fixtureRequestCount("/api/v1/auth/email-code/send"), 1)
        let verify = app.buttons["verifyOfficialCode"]
        XCTAssertFalse(verify.isEnabled)
        code.tap(); code.typeText("123456")
        XCTAssertEqual(code.value as? String, "123456")
        XCTAssertTrue(verify.isEnabled)
        XCTAssertEqual(code.label, "Email code")
        // A mistyped last digit can be corrected before any verification request.
        code.typeText(XCUIKeyboardKey.delete.rawValue + "5")
        XCTAssertEqual(code.value as? String, "123455")
        code.typeText(XCUIKeyboardKey.delete.rawValue + "6")
        XCTAssertEqual(try app.fixtureRequestCount("/api/v1/auth/email-code/verify"), 0)
        XCTAssertGreaterThanOrEqual(verify.frame.height, 60)
        XCTAssertGreaterThanOrEqual(app.buttons["changeOfficialEmail"].frame.height, 60)
        verify.tap()
        let mfa = app.textFields.matching(NSPredicate(format: "identifier == %@ AND label == %@", "officialCode", "Authenticator code")).firstMatch
        XCTAssertTrue(mfa.waitForExistence(timeout: 10))
        XCTAssertEqual(try app.fixtureRequestCount("/api/v1/auth/email-code/verify"), 1)
        mfa.tap(); mfa.typeText("654321")
        XCTAssertEqual(try app.fixtureRequestCount("/api/v1/auth/verify-mfa"), 0)
        XCTAssertFalse(app.buttons["Personal workspace"].exists)
        verify.tap()
        XCTAssertTrue(app.buttons["Personal workspace"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Team workspace"].exists)
        capture(app, "Deliberate code verification and workspace selection")
    }

    @MainActor func testCustomLoginKeepsTypingSeparateFromOtherLoginActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["customServerSignIn"].waitForExistence(timeout: 20))
        app.buttons["customServerSignIn"].tap()
        let username = app.textFields["serverUsername"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap(); username.typeText("typing only\n")
        XCTAssertTrue(username.exists)
        XCTAssertFalse(app.buttons["connectServer"].isEnabled)
        XCTAssertFalse(app.buttons["officialSignIn"].isHittable)
        XCTAssertFalse(app.buttons["exploreDemo"].exists)
        let method = app.buttons["serverLoginMethod"]
        XCTAssertGreaterThanOrEqual(method.frame.height, 60)
        method.tap()
        XCTAssertTrue(app.secureTextFields["serverToken"].waitForExistence(timeout: 5))
        XCTAssertFalse(username.exists)
        capture(app, "Separate custom-server sign-in")
    }

    @MainActor func testAddingAccountCanReturnFromEitherLoginMethod() {
        let app = XCUIApplication()
        app.launchFixture()
        app.buttons["workspacePicker"].tap()
        app.buttons["manageAccounts"].tap()
        XCTAssertTrue(app.buttons["addAccount"].waitForExistence(timeout: 10))
        app.buttons["addAccount"].tap()
        app.buttons["officialSignIn"].tap()
        XCTAssertTrue(app.textFields["officialEmail"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["customServerSignIn"].waitForExistence(timeout: 10))
        app.buttons["customServerSignIn"].tap()
        XCTAssertTrue(app.textFields["serverUsername"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["addAccount"].waitForExistence(timeout: 10))
        capture(app, "Account list after canceling custom login")
    }

    @MainActor func testChatAndFilesUseNativeWindowsWithoutSplitControls() throws {
        let app = XCUIApplication()
        app.launchFixture()
        let conversation = app.buttons["conversation_welcome"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 20))
        conversation.tap()
        XCTAssertTrue(app.textFields["messageComposer"].waitForExistence(timeout: 10))
        XCTAssertTrue(conversation.exists, "The launcher remains in its own window")
        XCTAssertFalse(app.buttons["chatSplitView"].exists)
        XCTAssertFalse(app.buttons["Switch pane"].exists)
        app.buttons["spatialNewWindow"].firstMatch.tap()
        app.buttons["Files"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "spatialContent_files").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["AGENTS.md"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Close pane"].exists)
        XCTAssertFalse(app.buttons["chatSplitView"].exists)
        XCTAssertTrue(app.textFields["messageComposer"].exists)
        capture(app, "Native chat and files windows")
    }

    @MainActor func testChatWindowsKeepIndependentSelections() {
        let app = XCUIApplication()
        app.launchFixture()
        XCTAssertTrue(app.buttons["conversation_welcome"].waitForExistence(timeout: 20))
        app.buttons["conversation_welcome"].tap()
        XCTAssertTrue(app.textFields["messageComposer"].waitForExistence(timeout: 10))
        app.buttons["conversation_research"].tap()
        let composers = app.textFields.matching(identifier: "messageComposer")
        let twoChats = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 2"), object: composers)
        XCTAssertEqual(XCTWaiter.wait(for: [twoChats], timeout: 10), .completed)
        XCTAssertTrue(app.navigationBars["A weekend in Kyoto"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["A place for your next idea"].exists)
        XCTAssertTrue(app.buttons["conversation_welcome"].exists)
        XCTAssertFalse(app.buttons["chatSplitView"].exists)
        capture(app, "Independent spatial conversations")
    }

    @MainActor func testNewConversationSendsItsFirstMessageInANativeWindow() {
        let app = XCUIApplication()
        app.launchFixture()
        XCTAssertTrue(app.buttons["newConversation"].waitForExistence(timeout: 20))
        app.buttons["newConversation"].tap()
        let message = app.textFields["newChatMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.tap(); message.typeText("Plan a calm afternoon")
        app.buttons["startConversation"].tap()
        XCTAssertTrue(app.textFields["messageComposer"].waitForExistence(timeout: 15))
        let replies = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Verified native WebSocket response."))
        XCTAssertTrue(replies.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(replies.count, 1)
        XCTAssertTrue(app.buttons["newConversation"].exists)
        XCTAssertFalse(app.buttons["chatSplitView"].exists)
        capture(app, "New conversation in its own window")
    }

    @MainActor func testVisionOnboardingUsesSpatialCopy() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-onboarding"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Memoh, in your space."].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["exploreDemo"].exists)
        XCTAssertTrue(app.buttons["officialSignIn"].exists)
        XCTAssertTrue(app.buttons["customServerSignIn"].exists)
        capture(app, "Vision Pro welcome")
    }

    @MainActor func testAgentToolShortcutsOpenNativeWindows() {
        let app = XCUIApplication()
        app.launchFixture()
        XCTAssertTrue(app.buttons["Agents"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["Agents"].firstMatch.tap()
        let terminal = app.buttons["agentTool_atlas_terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "spatialContent_terminal").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(terminal.exists, "Opening a tool must leave the launcher in place")
        app.buttons["agentDetails_atlas"].tap()
        let desktop = app.buttons["workspaceTool_desktop"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 10))
        desktop.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "spatialContent_desktop").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(desktop.exists, "Agent details must remain in their original window")
        XCTAssertFalse(app.buttons["chatSplitView"].exists)
        capture(app, "Native terminal and desktop windows")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        // visionOS does not support XCUIScreen's manual screenshots. Keep the
        // full accessibility hierarchy; use simctl io screenshot for visual QA.
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
