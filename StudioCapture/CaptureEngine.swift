import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreImage

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "studio.capture.media", qos: .userInitiated)
    private var stream: SCStream?
    private var cameraSession: AVCaptureSession?
    private var sink: MediaWriter?
    private var timer: DispatchSourceTimer?
    private var latestScreen: CVPixelBuffer?
    private var latestCamera: CVPixelBuffer?
    private var cameraTime: CMTime = .zero
    private var accepting = false
    private var failureSent = false
    var failure: ((String) -> Void)?
    var meter: ((Double, Double) -> Void)?
    var preview: ((CGImage) -> Void)?
    private let previewContext = CIContext(options: [.cacheIntermediates: false])
    private var ticks = 0
    private var captureStarted = Date()

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration, destination: URL, camera: Bool) async throws {
        let sink = try MediaWriter(destination: destination, width: configuration.width, height: configuration.height,
                                   system: configuration.capturesAudio, mic: configuration.captureMicrophone)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    self.sink = sink; accepting = true; failureSent = false; ticks = 0; captureStarted = Date()
                    latestScreen = nil; latestCamera = nil
                    if camera { try startCamera() }
                    continuation.resume()
                } catch { accepting = false; continuation.resume(throwing: error) }
            }
        }
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        stream = capture
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesAudio { try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if configuration.captureMicrophone { try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        do {
            try await capture.startCapture()
            queue.async { [self] in
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 1.0 / 30)
                timer.setEventHandler { [weak self] in self?.render() }
                self.timer = timer; timer.resume()
            }
        } catch { await discard(); throw error }
    }

    private func startCamera() throws {
        guard let device = AVCaptureDevice.default(for: .video) else { throw CaptureError.message("カメラが見つかりません") }
        let session = AVCaptureSession(); session.beginConfiguration(); session.sessionPreset = .hd1280x720
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CaptureError.message("カメラを開始できません") }
        session.addInput(input); session.addOutput(output); session.commitConfiguration()
        cameraSession = session; session.startRunning()
        guard session.isRunning else { throw CaptureError.message("カメラを使用できません。他のアプリの使用状況を確認してください") }
    }

    private func render() {
        guard accepting, !failureSent, let sink else { return }
        guard let latestScreen else {
            if Date().timeIntervalSince(captureStarted) > 8 {
                fail(CaptureError.message("画面を取得できません。画面収録の許可と対象の画面を確認してください"))
            }
            return
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let camera = CMTimeSubtract(now, cameraTime).seconds < 1 ? latestCamera : nil
        if cameraSession != nil, camera == nil, Date().timeIntervalSince(captureStarted) > 8 {
            fail(CaptureError.message("カメラ映像を取得できなくなりました。ここまでの録画を保存します")); return
        }
        do {
            try sink.appendVideo(screen: latestScreen, camera: camera, at: now)
            ticks += 1
            if ticks % 15 == 0 {
                let image = CIImage(cvPixelBuffer: latestScreen)
                let small = image.transformed(by: CGAffineTransform(scaleX: 420 / image.extent.width, y: 420 / image.extent.width))
                if let cg = previewContext.createCGImage(small, from: small.extent) { preview?(cg) }
            }
        } catch { fail(error) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepting else { return }
        latestCamera = CMSampleBufferGetImageBuffer(sampleBuffer)
        cameraTime = CMClockGetTime(CMClockGetHostTimeClock())
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, sampleBuffer.isValid else { return }
        do {
            switch type {
            case .screen:
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                      let status = attachments.first?[.status] as? Int,
                      status == SCFrameStatus.complete.rawValue else { return }
                latestScreen = CMSampleBufferGetImageBuffer(sampleBuffer)
            case .audio, .microphone:
                try sink?.appendAudio(sampleBuffer, mic: type == .microphone)
            @unknown default: break
            }
        } catch { fail(error) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in if accepting { fail(error) } }
    }
    private func fail(_ error: Error) {
        guard !failureSent else { return }
        failureSent = true; failure?(error.localizedDescription)
    }
    func finish() async throws -> (URL, String) {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        let finalSink: MediaWriter = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                timer?.cancel(); timer = nil; render(); accepting = false
                cameraSession?.stopRunning(); cameraSession = nil
                latestScreen = nil; latestCamera = nil
                guard let sink else { continuation.resume(throwing: CaptureError.message("録画が開始されていません")); return }
                sink.finish { result in
                    switch result {
                    case .success: continuation.resume(returning: sink)
                    case .failure(let error):
                        continuation.resume(throwing: CaptureError.message("\(error.localizedDescription)\n作業ファイル（復旧できる場合があります）: \(sink.temporaryURL.path)"))
                    }
                }
                self.sink = nil
            }
        }
        try await finalSink.export()
        let stats = "映像 \(finalSink.videoFrames) フレーム · 内部音声 \(finalSink.audioBuffers[0]) / マイク \(finalSink.audioBuffers[1]) バッファ · 映像ドロップ \(finalSink.droppedFrames)"
        return (finalSink.destination, stats)
    }
    func discard() async {
        if let stream { try? await stream.stopCapture() }; stream = nil
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                accepting = false; timer?.cancel(); timer = nil; cameraSession?.stopRunning(); cameraSession = nil
                sink = nil; latestCamera = nil; latestScreen = nil; continuation.resume()
            }
        }
    }
}
