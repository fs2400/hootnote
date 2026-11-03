import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Turns any audio or video file into a meeting: the soundtrack is extracted to a 16 kHz mono
/// capture file, then the normal pipeline transcribes it with everyone separated by voice.
enum AudioImporter {
    static let allowedTypes: [UTType] = [.audio, .movie, .audiovisualContent, .mpeg4Audio, .mp3, .wav, .aiff]

    enum ImportError: LocalizedError {
        case noAudio
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .noAudio: return "That file has no audio track."
            case .unreadable(let why): return "Couldn't read that file: \(why)"
            }
        }
    }

    /// Writes the file's soundtrack to `destination` (CAF, 16 kHz mono) and returns its duration.
    static func extract(from source: URL, to destination: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ImportError.noAudio }
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioTrackWriter.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(output)
        guard reader.startReading() else { throw ImportError.unreadable(reader.error?.localizedDescription ?? "unknown") }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioTrackWriter.sampleRate,
                                   channels: 1, interleaved: false)!
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioTrackWriter.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: destination, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frames = length / MemoryLayout<Float>.size
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: channel)
            try file.write(from: buffer)
        }
        if reader.status == .failed { throw ImportError.unreadable(reader.error?.localizedDescription ?? "unknown") }
        return duration
    }
}
