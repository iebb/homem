import XCTest

extension XCUIApplication {
    func fixtureRequestCount(_ path: String) throws -> Int {
        let data = try Data(contentsOf: URL(string: "http://127.0.0.1:18765/ui/counts")!)
        let counts = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        return counts?[path] ?? 0
    }
    @MainActor func launchFixture(scenario: String = "", useAccessToken: Bool = false) {
        resetFixture(scenario: scenario)
        launchArguments.removeAll { $0 == "--ui-onboarding" }
        launchArguments.append("--ui-onboarding")
        if !launchArguments.contains("-AppleLanguages") {
            launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        }
        launch()
        signInToFixture(useAccessToken: useAccessToken)
        // Relaunch checks must restore the account created above, rather than
        // resetting onboarding and deleting it a second time.
        launchArguments.removeAll { $0 == "--ui-onboarding" }
    }
    @MainActor func signInToFixture(username fixtureUsername: String = "fixture", useAccessToken: Bool = false) {
        let custom = descendants(matching: .any).matching(identifier: "customServerSignIn").firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 20))
        if !custom.isHittable { swipeUp() }
        custom.tap()
        let address = textFields["serverAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        let url = "http://127.0.0.1:18765/ui-api"
        let current = address.value as? String ?? ""
        if current != url {
            if current.hasPrefix("http"), current != address.placeholderValue {
                address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            address.typeText(url)
        }
        if useAccessToken {
            buttons["serverLoginMethod"].tap()
            let token = secureTextFields["serverToken"]
            XCTAssertTrue(token.waitForExistence(timeout: 5))
            token.tap(); token.typeText(fixtureUsername == "fixture-two" ? "homem-local-fixture-second-token" : "homem-local-fixture-token")
        } else {
            let username = textFields["serverUsername"]
            if !username.isHittable { swipeUp() }
            username.tap(); username.typeText(fixtureUsername)
            let password = secureTextFields["serverPassword"]
            if !password.isHittable { swipeUp() }
            password.tap(); password.typeText("fixture-password")
        }
        let connect = buttons["connectServer"]
        if !connect.isHittable { swipeUp() }
        connect.tap()
        XCTAssertTrue(buttons["workspacePicker"].waitForExistence(timeout: 20))
    }
    func resetFixture(scenario: String = "") {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18765/ui/reset")!)
        request.httpMethod = "POST"
        request.httpBody = try! JSONSerialization.data(withJSONObject: ["scenario": scenario])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let ready = XCTestExpectation(description: "Reset local fixture")
        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            ready.fulfill()
        }.resume()
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
}
