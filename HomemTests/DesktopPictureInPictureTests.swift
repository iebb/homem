import XCTest
import AVKit
import WebRTC
@testable import Homem

@MainActor final class DesktopPictureInPictureTests: XCTestCase {
    func testRFBImageBecomesImmediateLiveVideoSample() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let buffer = try XCTUnwrap(DesktopVideoSamples.pixelBuffer(image: XCTUnwrap(context.makeImage())))
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 32)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        let sample = try XCTUnwrap(DesktopVideoSamples.sample(buffer))
        XCTAssertTrue(CMSampleBufferDataIsReady(sample))
        XCTAssertTrue(CMSampleBufferGetPresentationTimeStamp(sample).isNumeric)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary])
        XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool, true)
    }
    func testSoftwareWebRTCFrameInterleavesChromaAndHandlesRotation() throws {
        let source = RTCI420Buffer(width: 4, height: 2)
        memset(UnsafeMutablePointer(mutating: source.dataY), 80, Int(source.strideY * source.height))
        memset(UnsafeMutablePointer(mutating: source.dataU), 90, Int(source.strideU * source.chromaHeight))
        memset(UnsafeMutablePointer(mutating: source.dataV), 120, Int(source.strideV * source.chromaHeight))
        let frame = RTCVideoFrame(buffer: source, rotation: ._0, timeStampNs: 1)
        let buffer = try XCTUnwrap(DesktopVideoSamples.pixelBuffer(frame: frame))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(y[0], 80); XCTAssertEqual(uv[0], 90); XCTAssertEqual(uv[1], 120)
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        let rotated = try XCTUnwrap(DesktopVideoSamples.pixelBuffer(frame: RTCVideoFrame(buffer: source, rotation: ._90, timeStampNs: 2)))
        XCTAssertEqual(CVPixelBufferGetWidth(rotated), 2)
        XCTAssertEqual(CVPixelBufferGetHeight(rotated), 4)
    }
    func testLivePlaybackPauseAndSkipCompletion() throws {
        let model = DesktopModel(api: APIClient(baseURL: OfficialServer.apiURL, officialSession: OfficialSession(cookies: [])), botID: "fixture")
        let pip = model.pictureInPicture
        print("System Picture in Picture support on this test device: \(pip.isSupported)")
        let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: pip.surface.displayLayer, playbackDelegate: pip))
        XCTAssertTrue(pip.pictureInPictureControllerTimeRangeForPlayback(controller).duration.isPositiveInfinity)
        pip.pictureInPictureController(controller, setPlaying: false)
        XCTAssertTrue(pip.pictureInPictureControllerIsPlaybackPaused(controller))
        pip.pictureInPictureController(controller, setPlaying: true)
        XCTAssertFalse(pip.pictureInPictureControllerIsPlaybackPaused(controller))
        var completed = false
        pip.pictureInPictureController(controller, skipByInterval: CMTime(seconds: 10, preferredTimescale: 600)) { completed = true }
        XCTAssertTrue(completed)
        XCTAssertFalse(pip.keepsConnectionAlive)
    }
}
