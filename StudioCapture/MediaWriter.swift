import Foundation
import AVFoundation
import CoreImage

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// All methods except export run on the capture engine's single media queue.
// Mutable state is confined to the media queue. Export only begins after finish completes.
final class MediaWriter: @unchecked Sendable {
    let temporaryURL: URL
    let destination: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let width: Int
    private let height: Int
    private var startTime: CMTime?
    private var lastVideoTime: CMTime?
    private var lastAudioTime: [Int: CMTime] = [:]
    private(set) var videoFrames = 0
    private(set) var audioBuffers = [0, 0]
    private(set) var droppedFrames = 0

    init(destination: URL, width: Int, height: Int, system: Bool, mic: Bool) throws {
        self.destination = destination; self.width = width; self.height = height
        temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.mov")
        writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000,
                AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 60]])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        func audio(_ channels: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 128000 : 192000])
            input.expectsMediaDataInRealTime = true
            return input
        }
        systemAudio = system ? audio(2) : nil
        microphone = mic ? audio(1) : nil
        for input in [video, systemAudio, microphone].compactMap({ $0 }) {
            guard writer.canAdd(input) else { throw CaptureError.message("動画エンコーダーを準備できません") }
            writer.add(input)
        }
    }

    func appendVideo(screen: CVPixelBuffer, camera: CVPixelBuffer?, at time: CMTime) throws {
        if startTime == nil {
            guard writer.startWriting() else { throw writer.error ?? CaptureError.message("保存開始に失敗しました") }
            writer.startSession(atSourceTime: time); startTime = time
        }
        guard writer.status == .writing else { throw writer.error ?? CaptureError.message("保存処理が停止しました") }
        guard video.isReadyForMoreMediaData else { droppedFrames += 1; return }
        if let lastVideoTime, time <= lastVideoTime { return }
        guard let pool = adaptor.pixelBufferPool else { throw CaptureError.message("映像バッファを作成できません") }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            droppedFrames += 1; return
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let source = CIImage(cvPixelBuffer: screen)
        let sx = CGFloat(width) / source.extent.width, sy = CGFloat(height) / source.extent.height
        var output = source.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: bounds)
        if let camera {
            let inset = CGFloat(width) * 0.025
            let boxWidth = CGFloat(width) * 0.24
            let box = CGRect(x: CGFloat(width) - boxWidth - inset, y: inset, width: boxWidth, height: boxWidth * 0.75)
            let image = CIImage(cvPixelBuffer: camera)
            let scale = max(box.width / image.extent.width, box.height / image.extent.height)
            let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let placed = resized.transformed(by: CGAffineTransform(
                translationX: box.midX - resized.extent.midX, y: box.midY - resized.extent.midY))
            let border = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
                .cropped(to: box.insetBy(dx: -3, dy: -3))
            output = placed.cropped(to: box).composited(over: border).composited(over: output)
        }
        context.render(output, to: buffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer.error ?? CaptureError.message("映像を書き込めません")
        }
        videoFrames += 1; lastVideoTime = time
    }

    func appendAudio(_ sample: CMSampleBuffer, mic: Bool) throws {
        let index = mic ? 1 : 0
        guard let input = mic ? microphone : systemAudio, let startTime else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid, time >= startTime else { return }
        if let previous = lastAudioTime[index], time <= previous { return }
        guard writer.status == .writing else { throw writer.error ?? CaptureError.message("音声保存が停止しました") }
        guard input.isReadyForMoreMediaData else {
            throw CaptureError.message("音声保存が追いつきませんでした。ここまでの録画を保存します")
        }
        guard input.append(sample) else { throw writer.error ?? CaptureError.message("音声を書き込めません") }
        lastAudioTime[index] = time; audioBuffers[index] += 1
    }

    func finish(completion: @escaping (Result<Void, Error>) -> Void) {
        guard startTime != nil, videoFrames > 0 else {
            writer.cancelWriting(); completion(.failure(CaptureError.message("画面のフレームを取得できませんでした"))); return
        }
        guard writer.status == .writing else {
            completion(.failure(writer.error ?? CaptureError.message("録画ファイルを確定できません"))); return
        }
        for input in [video, systemAudio, microphone].compactMap({ $0 }) { input.markAsFinished() }
        writer.finishWriting { [writer] in
            if writer.status == .completed { completion(.success(())) }
            else { completion(.failure(writer.error ?? CaptureError.message("保存に失敗しました"))) }
        }
    }

    /// Mix both native audio tracks into a single playback-friendly MP4 audio track.
    /// Each source track keeps its time range, including a delayed microphone start.
    func export() async throws {
        let asset = AVURLAsset(url: temporaryURL)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let sourceVideos = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = sourceVideos.first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureError.message("保存した映像を読み込めません")
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var mixInputs: [AVMutableAudioMixInputParameters] = []
        for source in audioTracks {
            let range = try await source.load(.timeRange)
            guard range.duration.seconds > 0,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(range, of: source, at: range.start)
            let params = AVMutableAudioMixInputParameters(track: track)
            // Two full-scale sources must not clip when summed.
            params.setVolume(audioTracks.count > 1 ? 0.5 : 1, at: .zero)
            mixInputs.append(params)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CaptureError.message("MP4を書き出せません")
        }
        if !mixInputs.isEmpty {
            let mix = AVMutableAudioMix(); mix.inputParameters = mixInputs; exporter.audioMix = mix
        }
        let exportURL = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).export.mp4")
        do {
            try await exporter.export(to: exportURL, as: .mp4)
            // Never silently overwrite an existing recording.
            try FileManager.default.moveItem(at: exportURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: exportURL)
            throw CaptureError.message("MP4保存に失敗: \(error.localizedDescription)\n復旧用MOV: \(temporaryURL.path)")
        }
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}
