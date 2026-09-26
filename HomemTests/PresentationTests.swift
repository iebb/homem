import XCTest
@testable import Homem

final class PresentationTests: XCTestCase {
    func testManagementRecordsKeepWireIdentifiersAndHumanNames() {
        let connectors = ResourceSpec.bot("b", "connectors", title: "Connected accounts")
        let account = connectors.record(["connection_id": "connection-42", "alias": "Personal calendar", "connector_type": "calendar"])
        XCTAssertEqual(account.id, "connection-42")
        XCTAssertEqual(account.title, "Personal calendar")
        let managers = ResourceSpec.bot("b", "channel-managers", title: "Channel managers")
        let manager = managers.record(["channel_identity_id": "identity-17", "channel_identity_display_name": "Review user"])
        XCTAssertEqual(manager.id, "identity-17")
        XCTAssertEqual(manager.title, "Review user")
        let grants = ResourceSpec.bot("b", "user-access", title: "Workspace access")
        let grant = grants.record(["id": "grant-9", "user_id": "user-7", "user_display_name": "Alice"])
        XCTAssertEqual(grant.id, "grant-9")
        XCTAssertEqual(grant.title, "Alice")
        let providerModels = ResourceSpec(title: "Models", path: "/speech-providers/provider/models", template: "/speech-providers/{id}/models", detailTemplate: "/speech-models/{id}", detailCollectionPath: "/speech-models")
        XCTAssertEqual(providerModels.itemPath(Record(value: ["id": "voice-model"])), "/speech-models/voice-model")
    }
    func testManagementReferencesUseTheOwningAgentAndProviderType() {
        XCTAssertEqual(ResourceFormReferences.source(for: "owner_user_id", path: "/bots/review/owner"), "/bots/review/user-access/candidates")
        XCTAssertEqual(ResourceFormReferences.source(for: "target_id", path: "/bots/review/workspace-targets/primary"), "/bots/review/workspace-targets")
        XCTAssertEqual(ResourceFormReferences.source(for: "provider_id", path: "/speech-models"), "/speech-providers")
        XCTAssertEqual(ResourceFormReferences.source(for: "tts_model_id", path: "/bots/review/settings"), "/speech-models")
        XCTAssertEqual(ResourceFormReferences.source(for: "default_bot_agent_id", path: "/bots/review/settings"), "/bots/review/agents")
        XCTAssertNil(ResourceFormReferences.source(for: "message", path: "/bots/review/hooks/test"))
    }
    func testActivityGroupingPreservesOrderAndPendingRequests() {
        let messages: [JSONValue] = [
            ["type": "tool", "name": "read_file"],
            ["type": "tool", "name": "exec", "approval": ["status": "pending"]],
            ["type": "text", "content": "Done"],
            ["type": "tool", "name": "update_schedule"]
        ]
        let groups = MessageGroup.group(messages)
        XCTAssertEqual(groups.map(\.messages.count), [2, 1, 1])
        XCTAssertEqual(groups.flatMap(\.messages), messages)
        XCTAssertEqual(groups[0].messages[1]["approval"]["status"], "pending")
        XCTAssertEqual(ToolPresentation.title("update_schedule"), "Schedule")
        XCTAssertEqual(ToolPresentation.title("some_private_tool_id"), "Tool activity")
    }
    func testTranslationsAreBundledAndPreserveUserContent() throws {
        for (language, expected) in [("zh-Hans", "智能体"), ("es", "Agentes"), ("ja", "エージェント")] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            XCTAssertNotNil(Bundle(path: path))
            XCTAssertEqual(AppLocalization.text("Agents", language: language), expected)
            XCTAssertEqual(AppLocalization.text("Personal agent", language: language), "Personal agent")
            XCTAssertEqual(Record(value: ["display_name": "Max"]).title, "Max")
            XCTAssertFalse(AppLocalization.text("Message %@…", language: language).isEmpty)
            XCTAssertNotEqual(AppLocalization.text("Desktop unavailable", language: language), "Desktop unavailable")
        }
    }
    func testDesktopReadinessIncludesBrowserAndEnabledState() {
        var info: JSONValue = ["enabled": true, "available": true, "running": true]
        XCTAssertTrue(DesktopReadiness.ready(info))
        info["browser_available"] = false
        XCTAssertFalse(DesktopReadiness.ready(info))
        info["enabled"] = false
        XCTAssertNotNil(DesktopReadiness.blockingReason(info))
    }
    @MainActor func testPrivateAvatarCredentialsStayOnOriginalOrigin() throws {
        let api = APIClient(baseURL: URL(string: "https://private.example/api")!, token: "fixture-token")
        let own = try XCTUnwrap(api.avatarRequest(URL(string: "https://private.example/avatars/team.svg")!))
        XCTAssertEqual(own.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        for url in ["https://cdn.example/a.png", "http://private.example/a.png", "https://private.example:444/a.png", "data:image/png;base64,eA=="] {
            XCTAssertNil(try api.avatarRequest(URL(string: url)!))
        }
        XCTAssertEqual(JSONValue.object(["metadata": ["icon_url": "/icon.svg"]]).avatarURL, "/icon.svg")
    }
    func testAvatarRedirectsKeepCredentialsOnlyOnSameOrigin() throws {
        let source = URL(string: "https://memoh.example/avatars/a")!
        var request = URLRequest(url: URL(string: "https://memoh.example/avatars/b")!)
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        request.setValue("session=fixture", forHTTPHeaderField: "Cookie")
        request.setValue("fixture-team", forHTTPHeaderField: "X-Team-ID")
        XCTAssertEqual(AvatarRedirectDelegate.redirectedRequest(request, from: source)?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        request.url = URL(string: "https://cdn.example/avatar.png?signature=fixture")!
        let external = try XCTUnwrap(AvatarRedirectDelegate.redirectedRequest(request, from: source))
        XCTAssertEqual(external.url, request.url)
        XCTAssertEqual(external.allHTTPHeaderFields, ["Accept": "image/*"])
        request.url = URL(string: "http://memoh.example/avatar.png")!
        XCTAssertNil(AvatarRedirectDelegate.redirectedRequest(request, from: source))
        request.url = URL(string: "https://user:secret@cdn.example/avatar.png")!
        XCTAssertNil(AvatarRedirectDelegate.redirectedRequest(request, from: source))
    }
    func testSVGDataAvatarSupportsPercentEncoding() async throws {
        let data = try await AvatarImages.data(URL(string: "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%3E%3C/svg%3E")!)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("<svg"))
    }
}

@MainActor final class DesktopReadinessTests: XCTestCase {
    func testLegacyPrepareAndReadinessPolling() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://desktop.invalid/api")!, token: "fixture", session: URLSession(configuration: config))
        var infoCalls = 0
        var prepared = false
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            if request.url!.path.hasSuffix("/prepare") {
                prepared = true
                return (200, Data("data: {\"type\":\"progress\",\"step\":\"starting\"}\n\ndata: {\"type\":\"complete\"}\n\n".utf8))
            }
            infoCalls += 1
            let ready = infoCalls >= 3
            return (200, try JSONValue.object(["enabled": true, "available": .bool(ready), "running": .bool(ready), "prepare_supported": false]).encoded)
        }
        defer { StubURLProtocol.handler = nil }
        var states: [String] = []
        try await DesktopReadiness.prepare(api: api, base: "/bots/test/container/display") { states.append($0) }
        XCTAssertTrue(prepared)
        XCTAssertEqual(infoCalls, 3)
        XCTAssertTrue(states.contains("Starting desktop"))
    }
    func testDisabledDesktopDoesNotPrepareOrConnect() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://desktop.invalid/api")!, session: URLSession(configuration: config))
        var count = 0
        StubURLProtocol.handler = { _ in count += 1; return (200, Data(#"{"enabled":false}"#.utf8)) }
        defer { StubURLProtocol.handler = nil }
        let model = DesktopModel(api: api, botID: "test")
        await model.connect()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.status, "Disconnected")
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.track)
    }
}

final class UserInputAnswerTests: XCTestCase {
    let single: JSONValue = ["id": "q1", "kind": "single_select", "allow_custom": true, "options": [["id": "a", "label": "Plan A"], ["id": "b", "label": "Plan B"]]]
    func testCustomChoiceReplacesOptionAndNeverSendsBoth() throws {
        var draft = UserInputDraft()
        draft.select("a", question: single)
        draft.selectCustom(question: single)
        XCTAssertTrue(draft.optionIDs.isEmpty)
        XCTAssertNil(draft.answer(for: single))
        draft.text = "  自分の案 🌱  "
        XCTAssertEqual(draft.answer(for: single), ["question_id": "q1", "custom_text": "自分の案 🌱"])
        draft.select("b", question: single)
        XCTAssertFalse(draft.customSelected)
        XCTAssertEqual(draft.answer(for: single), ["question_id": "q1", "option_ids": ["b"]])
        draft.customSelected = true // Defensive validation rejects contradictory state too.
        XCTAssertNil(draft.answer(for: single))
    }
    func testTextQuestionsUseTextAndRequiredDefaultsToTrue() {
        let question: JSONValue = ["question_id": "free", "kind": "text"]
        var draft = UserInputDraft(); draft.text = " \n "
        XCTAssertNil(draft.answer(for: question))
        draft.text = "  My own answer  "
        XCTAssertEqual(draft.answer(for: question), ["question_id": "free", "text": "My own answer"])
        XCTAssertNil(UserInputDraft.answers(for: [single], drafts: [:]))
    }
    func testOptionalQuestionsSendExplicitSkipsAndEmptyCustomCannotSubmit() {
        var question = single; question["required"] = false
        var draft = UserInputDraft()
        XCTAssertEqual(draft.answer(for: question), ["question_id": "q1", "skipped": true])
        draft.selectCustom(question: question); draft.text = " \n "
        XCTAssertNil(draft.answer(for: question))
        draft.selectCustom(question: question)
        XCTAssertEqual(UserInputDraft.answers(for: [question], drafts: ["q1": draft]), [["question_id": "q1", "skipped": true]])
    }
    func testMultiSelectHonorsCustomExclusivity() {
        var question = single; question["kind"] = "multi_select"
        var draft = UserInputDraft()
        draft.select("a", question: question); draft.selectCustom(question: question); draft.text = "Also this"
        XCTAssertEqual(draft.answer(for: question), ["question_id": "q1", "option_ids": ["a"], "custom_text": "Also this"])
        question["custom_exclusive"] = true
        XCTAssertNil(draft.answer(for: question))
        draft.selectCustom(question: question); draft.selectCustom(question: question)
        XCTAssertTrue(draft.optionIDs.isEmpty)
        XCTAssertEqual(draft.answer(for: question), ["question_id": "q1", "custom_text": "Also this"])
        draft.select("b", question: question)
        XCTAssertFalse(draft.customSelected)
        XCTAssertEqual(draft.answer(for: question), ["question_id": "q1", "option_ids": ["b"]])
    }
}

final class ChatSplitLayoutTests: XCTestCase {
    func testIPadColumnsKeepBothPanesUsableAndNarrowWindowsStack() {
        XCTAssertFalse(ChatSplitLayout.usesColumns(width: 430))
        XCTAssertFalse(ChatSplitLayout.usesColumns(width: 600))
        XCTAssertTrue(ChatSplitLayout.usesColumns(width: 669))
        XCTAssertTrue(ChatSplitLayout.usesColumns(width: 700))
        XCTAssertTrue(ChatSplitLayout.usesColumns(width: 1032))
        for width: CGFloat in [676, 1008, 1352] {
            for proposed in [-1.0, 0.45, 2.0] {
                let fraction = ChatSplitLayout.columnFraction(proposed, available: width)
                XCTAssertGreaterThanOrEqual(width * fraction, 300 - 0.001)
                XCTAssertGreaterThanOrEqual(width * (1 - fraction), 300 - 0.001)
            }
        }
    }
    func testPortraitSplitKeepsChatVisibleWithKeyboardAndDividerLimits() {
        for height: CGFloat in [320, 460, 740] {
            for fraction in [-1.0, 0.44, 2.0] {
                let pane = ChatSplitLayout.paneHeight(available: height, fraction: fraction)
                XCTAssertGreaterThan(pane, 0)
                XCTAssertGreaterThanOrEqual(height - pane, 170)
                XCTAssertLessThanOrEqual(pane, height * 0.65)
            }
        }
        XCTAssertEqual(ChatSplitLayout.fraction(-1), 0.25)
        XCTAssertEqual(ChatSplitLayout.fraction(2), 0.65)
    }
}

final class WorkspaceGeometryTests: XCTestCase {
    func testActiveFoldKeepsPanesClearAndUnfoldingRestoresLayout() {
        let size = CGSize(width: 900, height: 650)
        for fold in [CGRect(x: 438, y: 0, width: 24, height: 650), CGRect(x: 0, y: 310, width: 900, height: 30)] {
            for count in 1...4 {
                for arrangement in WorkspaceArrangement.allCases {
                    let layout = WorkspaceGeometry.make(size: size, count: count, arrangement: arrangement, division: fold)
                    XCTAssertEqual(layout.frames.count, count)
                    for frame in layout.frames {
                        XCTAssertFalse(frame.intersects(fold))
                        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame))
                    }
                }
            }
        }
        let flat = WorkspaceGeometry.make(size: size, count: 3, arrangement: .automatic)
        let unfolded = WorkspaceGeometry.make(size: size, count: 3, arrangement: .automatic, division: .zero)
        XCTAssertEqual(flat.frames, unfolded.frames)
        let croppedFold = WorkspaceGeometry.make(size: size, count: 3, arrangement: .automatic, division: CGRect(x: 0, y: -100, width: 900, height: 30))
        XCTAssertEqual(flat.frames, croppedFold.frames)
    }
    func testLaptopPoseKeepsChatBelowFoldAndToolsAbove() {
        let fold = CGRect(x: 0, y: 320, width: 900, height: 24)
        let layout = WorkspaceGeometry.make(size: CGSize(width: 900, height: 680), count: 3, arrangement: .automatic, division: fold)
        XCTAssertGreaterThan(layout.frames[0].minY, fold.maxY)
        XCTAssertLessThan(layout.frames[1].maxY, fold.minY)
        XCTAssertLessThan(layout.frames[2].maxY, fold.minY)
        XCTAssertLessThan(layout.frames[1].maxX, layout.frames[2].minX)
        XCTAssertTrue(layout.dividers.isEmpty)
    }
    func testDynamicArrangementsKeepEveryPaneInsideCanvasWithoutOverlap() {
        for size in [CGSize(width: 430, height: 320), CGSize(width: 430, height: 740), CGSize(width: 466, height: 600), CGSize(width: 669, height: 850), CGSize(width: 951, height: 570), CGSize(width: 1032, height: 700)] {
            for count in 1...8 {
                for arrangement in WorkspaceArrangement.allCases {
                    let layout = WorkspaceGeometry.make(size: size, count: count, arrangement: arrangement)
                    XCTAssertEqual(layout.frames.count, count)
                    let canvas = CGRect(origin: .zero, size: layout.size).insetBy(dx: -0.001, dy: -0.001)
                    for (index, frame) in layout.frames.enumerated() {
                        XCTAssertTrue(canvas.contains(frame), "\(arrangement) pane \(index)")
                        XCTAssertGreaterThan(frame.width, 0)
                        XCTAssertGreaterThan(frame.height, 0)
                        for other in layout.frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
                    }
                }
            }
        }
    }
    func testAutomaticThreePaneIPadKeepsChatFullHeightAndToolsOnRight() {
        let layout = WorkspaceGeometry.make(size: CGSize(width: 1032, height: 700), count: 3, arrangement: .automatic)
        XCTAssertEqual(layout.frames[0].height, 700)
        XCTAssertEqual(layout.frames[1].minX, layout.frames[2].minX)
        XCTAssertLessThan(layout.frames[0].maxX, layout.frames[1].minX)
        XCTAssertLessThan(layout.frames[1].maxY, layout.frames[2].minY)
        XCTAssertEqual(layout.dividers.count, 2)
    }
}

final class WorkspaceDockingTests: XCTestCase {
    func testEdgeDropsChooseHorizontalAndVerticalLayoutsWhenTheyFit() throws {
        var workspace = WorkspaceSnapshot()
        workspace.panes = [WorkspacePane(tool: .files)]
        let order = workspace.orderedIDs, size = CGSize(width: 900, height: 650)
        let layout = WorkspaceGeometry.make(size: size, count: 2, arrangement: .automatic)
        let target = layout.frames[0], source = order[1]
        let right = try XCTUnwrap(PaneDropProposal.make(source: source, location: CGPoint(x: target.maxX - 2, y: target.midY), workspace: workspace, layout: layout, viewport: size, division: nil)?.docking)
        let horizontal = try XCTUnwrap(right.geometry(size: size, order: order))
        XCTAssertGreaterThan(horizontal.frames[1].minX, horizontal.frames[0].maxX)
        let top = try XCTUnwrap(PaneDropProposal.make(source: source, location: CGPoint(x: target.midX, y: target.minY + 2), workspace: workspace, layout: layout, viewport: size, division: nil)?.docking)
        let vertical = try XCTUnwrap(top.geometry(size: size, order: order))
        XCTAssertLessThan(vertical.frames[1].maxY, vertical.frames[0].minY)
        XCTAssertNil(right.geometry(size: CGSize(width: 466, height: 650), order: order))
        let fold = CGRect(x: 438, y: 0, width: 24, height: 650)
        XCTAssertNil(PaneDropProposal.make(source: source, location: CGPoint(x: target.maxX - 2, y: target.midY), workspace: workspace, layout: layout, viewport: size, division: fold)?.docking)
        XCTAssertNil(PaneDropProposal.make(source: source, location: CGPoint(x: -20, y: -20), workspace: workspace, layout: layout, viewport: size, division: nil))
    }
    func testNestedDockingResizesPersistsAndCollapsesWhenPaneCloses() throws {
        var workspace = WorkspaceSnapshot()
        workspace.panes = [WorkspacePane(tool: .files), WorkspacePane(tool: .terminal)]
        let ids = workspace.orderedIDs, size = CGSize(width: 900, height: 650)
        let initial = WorkspaceGeometry.make(size: size, count: 3, arrangement: .automatic)
        let root = try XCTUnwrap(WorkspaceDockNode.matching(ids: ids, frames: initial.frames))
        workspace.docking = try XCTUnwrap(root.removing(ids[2])).inserting(ids[2], at: ids[0], edge: .bottom)
        let layout = try XCTUnwrap(workspace.docking?.geometry(size: size, order: ids))
        XCTAssertEqual(Set(workspace.docking!.ids), Set(ids))
        XCTAssertEqual(layout.frames[0].minX, layout.frames[2].minX)
        XCTAssertLessThan(layout.frames[0].maxY, layout.frames[2].minY)
        XCTAssertEqual(layout.frames[1].height, size.height)
        workspace.docking?.setFraction(0.6, at: [false])
        let resized = try XCTUnwrap(workspace.docking?.geometry(size: size, order: ids))
        XCTAssertGreaterThan(resized.frames[0].height, layout.frames[0].height)
        XCTAssertEqual(resized.frames[1], layout.frames[1])
        let data = try JSONEncoder().encode(workspace)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSnapshot.self, from: data), workspace)
        workspace.remove(ids[2])
        XCTAssertEqual(workspace.docking?.ids.count, 2)
        XCTAssertNotNil(workspace.docking?.geometry(size: size, order: workspace.orderedIDs))
        workspace.arrangement = .rows
        XCTAssertNil(workspace.docking)
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        oldJSON.removeValue(forKey: "docking")
        XCTAssertNil(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: oldJSON)).docking)
    }
}
