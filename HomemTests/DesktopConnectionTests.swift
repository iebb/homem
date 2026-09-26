import XCTest
import WebRTC
import CoreGraphics
@testable import Homem

/// A real local WebRTC peer answers through the HTTP test transport. No production session is used.
@MainActor final class DesktopConnectionTests: XCTestCase {
    func testViewOnlyBlocksRemoteInputAndReleasesHeldPointer() async throws {
        let api = APIClient(baseURL: OfficialServer.apiURL, officialSession: OfficialSession(cookies: []))
        let connection = RecoverableDesktopFixture()
        let model = DesktopModel(api: api, botID: "fixture", waitForNetwork: {}) { _, _ in connection }
        model.setViewOnly(true)
        await model.connect()
        try await waitUntil { model.hasVideo }
        model.pointer(CGPoint(x: 1, y: 1), mask: 1)
        model.key(65)
        try await Task.sleep(for: .milliseconds(40))
        var packets = await connection.sent
        XCTAssertTrue(packets.isEmpty)
        XCTAssertEqual(model.status, "Connected")

        model.setViewOnly(false)
        model.pointer(CGPoint(x: 1, y: 1), mask: 1)
        try await Task.sleep(for: .milliseconds(40))
        model.setViewOnly(true)
        model.key(66)
        model.pointer(CGPoint(x: 0, y: 0), mask: 4)
        try await Task.sleep(for: .milliseconds(40))
        packets = await connection.sent
        XCTAssertEqual(packets, [RFBClient.pointer(x: 1, y: 1, mask: 1), RFBClient.pointer(x: 1, y: 1, mask: 0)])
        model.disconnect()
        XCTAssertTrue(model.viewOnly)
    }
    func testRapidTypingPreservesRepeatedKeysAndShortcutOrdering() async throws {
        let api = APIClient(baseURL: OfficialServer.apiURL, officialSession: OfficialSession(cookies: []))
        let connection = RecoverableDesktopFixture(sendDelay: .milliseconds(2))
        let model = DesktopModel(api: api, botID: "fixture", waitForNetwork: {}) { _, _ in connection }
        await model.connect()
        try await waitUntil { model.hasVideo }
        let text = "bookkeeper 114514!!\r\n中文\t日本語 café"
        model.type(text)
        model.key(0xffff, modifiers: [0xffe3, 0xffe9])
        let codes = RemoteKeyInput.codes(text)
        let expected = codes.flatMap { [RFBClient.key($0, down: true), RFBClient.key($0, down: false)] }
            + [RFBClient.key(0xffe3, down: true), RFBClient.key(0xffe9, down: true),
               RFBClient.key(0xffff, down: true), RFBClient.key(0xffff, down: false),
               RFBClient.key(0xffe9, down: false), RFBClient.key(0xffe3, down: false)]
        let deadline = Date().addingTimeInterval(3)
        while await connection.sent.count < codes.count + 1, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let packets = await connection.sent
        XCTAssertEqual(packets.reduce(Data(), +), expected.reduce(Data(), +))
        XCTAssertEqual(RemoteKeyInput.codes("\r\n\t\u{1b}中"), [0xff0d, 0xff09, 0xff1b, 0x01004e2d])
        model.disconnect()
    }

    func testNativeKeyboardCommitsCompositionOnceAndDeletesOnEmptyInput() {
        let view = RemoteKeyboardView()
        var texts: [String] = []
        var keys: [UInt32] = []
        view.onText = { texts.append($0) }
        view.onKey = { key, _ in keys.append(key) }
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        view.flushCommittedText()
        XCTAssertTrue(texts.isEmpty, "Do not send unfinished IME candidates")
        view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        view.unmarkText()
        view.flushCommittedText()
        XCTAssertEqual(texts, ["日本"])
        XCTAssertEqual(view.text, "")
        view.deleteBackward()
        XCTAssertEqual(keys, [0xff08])
        view.text = "hello!!\n中文"
        view.textViewDidChange(view)
        XCTAssertEqual(texts, ["日本", "hello!!\n中文"])
        XCTAssertEqual(view.text, "")
    }

    func testOfficialDesktopRecoversAfterNetworkDropAndStopsWhenDismissed() async throws {
        let api = APIClient(baseURL: OfficialServer.apiURL, officialSession: OfficialSession(cookies: []))
        var connections = [RecoverableDesktopFixture]()
        let model = DesktopModel(api: api, botID: "fixture", waitForNetwork: {}) { _, _ in
            let connection = RecoverableDesktopFixture()
            connections.append(connection)
            return connection
        }
        await model.connect()
        try await waitUntil { model.hasVideo }
        XCTAssertEqual(model.status, "Connected")
        await connections[0].drop()
        try await waitUntil { connections.count == 2 && model.status == "Connected" }
        XCTAssertNil(model.error)
        model.disconnect()
        let count = connections.count
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(connections.count, count)
        XCTAssertEqual(model.status, "Disconnected")
        XCTAssertNil(model.runtimeImage)
    }
    func testOfficialDesktopCancelsPendingRecoveryOnDismissal() async throws {
        let api = APIClient(baseURL: OfficialServer.apiURL, officialSession: OfficialSession(cookies: []))
        var count = 0
        let model = DesktopModel(api: api, botID: "fixture", waitForNetwork: {}) { _, _ in count += 1; throw URLError(.networkConnectionLost) }
        await model.connect()
        XCTAssertEqual(model.status, "Reconnecting")
        model.disconnect()
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.status, "Disconnected")
    }
    func testOfficialDesktopRecoversFromUnwrappedSocketDisconnect() async throws {
        let api = APIClient(baseURL: OfficialServer.apiURL, officialSession: OfficialSession(cookies: []))
        var attempts = 0
        let model = DesktopModel(api: api, botID: "fixture", waitForNetwork: {}) { _, _ in
            attempts += 1
            if attempts == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOTCONN.rawValue)) }
            return RecoverableDesktopFixture()
        }
        await model.connect()
        XCTAssertEqual(model.status, "Reconnecting")
        try await waitUntil { model.status == "Connected" }
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(model.error)
        model.disconnect()
        XCTAssertFalse(DesktopRecovery.canRetry(ClientError.http(401, "Unauthorized")))
        XCTAssertFalse(DesktopRecovery.canRetry(RFBClient.Failure.unsupported))
    }
    func testOfflineDesktopWaitsForConnectivityBeforeReconnecting() async throws {
        let api = APIClient(baseURL: OfficialServer.apiURL, officialSession: OfficialSession(cookies: []))
        let (updates, continuation) = AsyncStream<Bool>.makeStream()
        defer { continuation.finish() }
        var attempts = 0
        let model = DesktopModel(api: api, botID: "fixture", waitForNetwork: {
            for await online in updates {
                try Task.checkCancellation()
                if online { return }
            }
            throw CancellationError()
        }, recoveryDelay: { _ in .milliseconds(10) }) { _, _ in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return RecoverableDesktopFixture()
        }
        await model.connect()
        XCTAssertEqual(model.status, "Waiting for network")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(attempts, 1)
        continuation.yield(true)
        try await waitUntil { model.status == "Connected" }
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(model.error)
        model.disconnect()
    }
    func testNetworkOutageDoesNotExhaustRecoveryBudget() async throws {
        let api = APIClient(baseURL: OfficialServer.apiURL, officialSession: OfficialSession(cookies: []))
        var attempts = 0
        let model = DesktopModel(api: api, botID: "fixture", waitForNetwork: {},
                                 recoveryDelay: { _ in .milliseconds(10) }) { _, _ in
            attempts += 1
            if attempts <= 5 { throw URLError(.notConnectedToInternet) }
            return RecoverableDesktopFixture()
        }
        await model.connect()
        try await waitUntil { model.status == "Connected" }
        XCTAssertEqual(attempts, 6)
        XCTAssertNil(model.error)
        model.disconnect()
        XCTAssertEqual(DesktopRecovery.delay(attempt: 100), .seconds(30))
        XCTAssertFalse(DesktopRecovery.canRetry(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(DesktopRecovery.canRetry(URLError(.cancelled)))
    }
    func testClosingOfflinePaneCancelsNetworkWait() async throws {
        let api = APIClient(baseURL: OfficialServer.apiURL, officialSession: OfficialSession(cookies: []))
        let (updates, continuation) = AsyncStream<Bool>.makeStream()
        defer { continuation.finish() }
        var attempts = 0
        let model = DesktopModel(api: api, botID: "fixture", waitForNetwork: {
            for await _ in updates { try Task.checkCancellation(); return }
            throw CancellationError()
        }, recoveryDelay: { _ in .milliseconds(10) }) { _, _ in
            attempts += 1
            throw URLError(.notConnectedToInternet)
        }
        await model.connect()
        try await Task.sleep(for: .milliseconds(30))
        model.disconnect()
        continuation.yield(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(model.status, "Disconnected")
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition())
    }
    func testNativeOfferReceivesVideoTrackAndCleansUpSession() async throws {
        let remote = DesktopPeerFixture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DesktopOfferProtocol.self]
        let api = APIClient(baseURL: URL(string: "http://127.0.0.1/api")!, session: URLSession(configuration: config))
        var closed = false
        DesktopOfferProtocol.handler = { request in
            if request.httpMethod == "DELETE" { closed = true; return Data() }
            if request.url!.path.hasSuffix("/offer") {
                var data = request.httpBody
                if data == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096); var body = Data()
                    while stream.hasBytesAvailable { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; body.append(buffer, count: size) }
                    data = body
                }
                let offer = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(data))
                XCTAssertTrue(offer["sdp"].string.contains("m=video"))
                XCTAssertTrue(offer["sdp"].string.contains("a=recvonly"))
                let answer = try await remote.answer(offer["sdp"].string)
                return try JSONValue.object(["type": "answer", "sdp": .string(answer), "session_id": "native-test"]).encoded
            }
            return Data(#"{"enabled":true,"available":true,"running":true}"#.utf8)
        }
        defer { DesktopOfferProtocol.handler = nil; remote.peer.close() }
        let model = DesktopModel(api: api, botID: "fixture")
        await model.connect()
        let deadline = Date().addingTimeInterval(12)
        while (model.track == nil || model.status != "Connected"), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.status, "Connected")
        XCTAssertNotNil(model.track)
        model.videoSize = CGSize(width: 1280, height: 720)
        XCTAssertNil(model.point(CGPoint(x: 0, y: 0), in: CGSize(width: 400, height: 800)))
        let point = try XCTUnwrap(model.point(CGPoint(x: 200, y: 400), in: CGSize(width: 400, height: 800)))
        XCTAssertEqual(point.x, 640, accuracy: 1); XCTAssertEqual(point.y, 360, accuracy: 1)
        model.disconnect()
        let closeDeadline = Date().addingTimeInterval(3)
        while !closed, Date() < closeDeadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(closed)
        XCTAssertNil(model.track)
    }
}

private final class DesktopOfferProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var handler: ((URLRequest) async throws -> Data)?
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        responseTask = Task { @MainActor in
            do {
                let data = try await Self.handler!(request)
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}

@MainActor private final class DesktopPeerFixture: NSObject, RTCPeerConnectionDelegate {
    let factory: RTCPeerConnectionFactory
    var peer: RTCPeerConnection!
    override init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        super.init()
        let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
        peer = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "desktop-video")
        peer.add(track, streamIds: ["desktop"])
    }
    func answer(_ sdp: String) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in if let error { c.resume(throwing: error) } else { c.resume() } } }
        let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? ClientError.invalidResponse) } } }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in peer.setLocalDescription(answer) { error in if let error { c.resume(throwing: error) } else { c.resume() } } }
        let deadline = Date().addingTimeInterval(5)
        while peer.iceGatheringState != .complete, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        return peer.localDescription!.sdp
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

private actor RecoverableDesktopFixture: DesktopTransport {
    private var interrupted = false
    private let sendDelay: Duration
    init(sendDelay: Duration = .zero) { self.sendDelay = sendDelay }
    private(set) var sent: [Data] = []
    func run(frame: @Sendable (CGImage) async -> Void) async throws {
        let bytes = Data(repeating: 127, count: 16)
        let provider = CGDataProvider(data: bytes as CFData)!
        let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        await frame(image)
        while !interrupted { try await Task.sleep(for: .milliseconds(30)) }
        throw URLError(.networkConnectionLost)
    }
    func drop() { interrupted = true }
    func close() { interrupted = true }
    func send(_ data: Data) async throws { try await Task.sleep(for: sendDelay); sent.append(data) }
}
