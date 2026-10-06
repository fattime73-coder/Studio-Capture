import Foundation
import AVFoundation
import CoreImage

@main
enum MediaTests {
    static func pixel(_ color: CIColor, width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        CIContext().render(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: buffer!)
        return buffer!
    }
    static func audio(index: Int, rate: Double, frequency: Double, base: CMTime) -> CMSampleBuffer {
        let count = Int(rate / 30)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        pcm.frameLength = pcm.frameCapacity
        for n in 0..<count { pcm.floatChannelData![0][n] = Float(0.25 * sin(2 * .pi * frequency * Double(index * count + n) / rate)) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
            presentationTimeStamp: base + CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        CMSampleBufferSetDataReady(sample!)
        return sample!
    }
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let screen = pixel(CIColor(red: 0.8, green: 0.08, blue: 0.05), width: 640, height: 360)
        let camera = pixel(CIColor(red: 0.02, green: 0.12, blue: 0.95), width: 320, height: 240)
        for (name, system, mic, pip) in [("silent",false,false,false),("system",true,false,false),("microphone",false,true,true),("mixed",true,true,true)] {
            let url = folder.appendingPathComponent(name + ".mp4")
            let writer = try MediaWriter(destination: url, width: 640, height: 360, system: system, mic: mic)
            let base = CMTime(seconds: 1000, preferredTimescale: 48000)
            for i in 0..<60 {
                try writer.appendVideo(screen: screen, camera: pip ? camera : nil, at: base + CMTime(value: Int64(i), timescale: 30))
                if system { try writer.appendAudio(audio(index: i, rate: 48000, frequency: 440, base: base), mic: false) }
                // Test native 44.1 kHz mic conversion and a 200 ms delayed first sample.
                if mic && i >= 6 { try writer.appendAudio(audio(index: i, rate: 44100, frequency: 660, base: base), mic: true) }
                try await Task.sleep(for: .milliseconds(34))
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in writer.finish { c.resume(with: $0) } }
            try await writer.export()
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            precondition(videos.count == 1 && audios.count == (system || mic ? 1 : 0))
            precondition(abs(duration - 2) < 0.1, "Unexpected duration \(duration)")
            let generator = AVAssetImageGenerator(asset: asset)
            let (image, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 30))
            let ci = CIImage(cgImage: image)
            var rgba = [UInt8](repeating: 0, count: 4)
            CIContext().render(ci, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 560, y: 50, width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            precondition(pip ? rgba[2] > rgba[0] : rgba[0] > rgba[2], "PIP compositing failed")
            if let track = audios.first {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
                reader.add(output); precondition(reader.startReading())
                var values: [Float] = []; var sampleRate = 48000.0
                while let buffer = output.copyNextSampleBuffer() {
                    let description = CMSampleBufferGetFormatDescription(buffer)!
                    let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)!.pointee
                    sampleRate = format.mSampleRate
                    let channels = Int(format.mChannelsPerFrame)
                    let block = CMSampleBufferGetDataBuffer(buffer)!
                    let length = CMBlockBufferGetDataLength(block)
                    var floats = [Float](repeating: 0, count: length / 4)
                    _ = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                    for i in stride(from: 0, to: floats.count, by: channels) { values.append(floats[i]) }
                }
                precondition(reader.status == .completed)
                let segment = Array(values.suffix(Int(sampleRate)))
                func magnitude(_ frequency: Double) -> Double {
                    var real = 0.0, imaginary = 0.0
                    for (i, value) in segment.enumerated() {
                        let angle = 2 * Double.pi * frequency * Double(i) / sampleRate
                        real += Double(value) * cos(angle); imaginary += Double(value) * sin(angle)
                    }
                    return 2 * hypot(real, imaginary) / Double(segment.count)
                }
                let a = magnitude(440), b = magnitude(660)
                precondition(system ? a > 0.03 : a < 0.005)
                precondition(mic ? b > 0.03 : b < 0.005)
                print("\(name): tone amplitudes system=\(a), mic=\(b)")
            }
            print("PASS \(name): \(duration)s, video=\(videos.count), audio=\(audios.count), frames=\(writer.videoFrames), PIP=\(pip)")
        }
    }
}
