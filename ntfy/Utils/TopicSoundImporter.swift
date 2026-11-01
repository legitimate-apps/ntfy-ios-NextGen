import AVFoundation
import AudioToolbox

struct TopicSoundImportError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Choose a readable audio file up to 50 MB. Protected or unsupported audio cannot be imported.")
    }
}

/// App only. The NSE never decodes audio, allocates sample buffers or creates sound files.
enum TopicSoundImporter {
    static let sampleRate = 22_050
    static let maximumDuration = 29.0
    static let maximumBytes = 50 * 1024 * 1024

    static func importFile(_ source: URL, library: TopicSoundLibrary) throws -> TopicSound {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumBytes, let directory = library.directory else { throw TopicSoundImportError() }
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw TopicSoundImportError() }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maximumDuration, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw TopicSoundImportError() }
        reader.add(output)
        guard reader.startReading() else { throw TopicSoundImportError() }
        defer { reader.cancelReading() }
        var pcm = Data()
        let limit = Int(maximumDuration) * sampleRate * 2
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw TopicSoundImportError() }
            let count = CMBlockBufferGetDataLength(block)
            guard count > 0 else { continue }
            var bytes = Data(count: count)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw TopicSoundImportError() }
            pcm.append(bytes.prefix(max(0, limit - pcm.count)))
            if pcm.count >= limit { break }
        }
        guard !pcm.isEmpty, reader.status != .failed else { throw TopicSoundImportError() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "ntfy-import-\(UUID().uuidString).wav"
        let destination = directory.appendingPathComponent(filename)
        // A trim may land mid-wave. Fade both edges to avoid a click, without increasing duration.
        pcm.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let fade = min(samples.count / 2, sampleRate / 100)
            for i in 0..<fade {
                let gain = Double(i) / Double(max(1, fade))
                samples[i] = Int16(Double(Int16(littleEndian: samples[i])) * gain).littleEndian
                let end = samples.count - 1 - i
                samples[end] = Int16(Double(Int16(littleEndian: samples[end])) * gain).littleEndian
            }
        }
        do {
            try wave(pcm).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let title = source.deletingPathExtension().lastPathComponent
        library.registerImport(filename: filename, title: title)
        return TopicSound(id: filename, title: title)
    }

    static func installBuiltins(library: TopicSoundLibrary) throws {
        guard let directory = library.directory else { throw TopicSoundImportError() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, sound) in TopicSound.builtins.enumerated() where library.file(sound.id) == nil {
            let duration = [0.38, 1.35, 3.2][index]
            var pcm = Data()
            for frame in 0..<Int(duration * Double(sampleRate)) {
                let t = Double(frame) / Double(sampleRate)
                let local: Double
                let frequency: Double
                switch index {
                case 0: local = t; frequency = 1046.5
                case 1: local = t.truncatingRemainder(dividingBy: 0.45); frequency = [659.25, 830.61, 987.77][min(2, Int(t / 0.45))]
                default: local = t.truncatingRemainder(dividingBy: 0.4); frequency = Int(t / 0.4) % 2 == 0 ? 880 : 1174.66
                }
                let segmentDuration = index == 0 ? duration : (index == 1 ? 0.45 : 0.4)
                let release = min(1, max(0, segmentDuration - local) / 0.025)
                let envelope = min(1, local / 0.008) * release * exp(-local * (index == 2 ? 8 : 12))
                let fundamental = sin(2 * .pi * frequency * t)
                let harmonic = 0.2 * sin(4 * .pi * frequency * t)
                var value = Int16(max(-1, min(1, (fundamental + harmonic) * envelope * 0.65)) * 32767).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
            let url = directory.appendingPathComponent(sound.id)
            try wave(pcm).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
        }
    }

    static func wave(_ pcm: Data) -> Data {
        var data = Data("RIFF".utf8)
        func word(_ value: UInt32, bytes: Int = 4) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0.prefix(bytes)) }
        }
        word(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8)); word(16)
        word(1, bytes: 2); word(1, bytes: 2); word(UInt32(sampleRate)); word(UInt32(sampleRate * 2))
        word(2, bytes: 2); word(16, bytes: 2); data.append(Data("data".utf8)); word(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
