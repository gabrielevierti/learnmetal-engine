// Audio.swift
// Sound output: connects the Mixer to the computer's speakers, and decodes audio files.
//
// AVAudioEngine does the device work. All this class adds is one "source node": a
// function the system calls whenever it needs more samples, which asks the mixer.

import AVFoundation

public final class Audio {
    /// Volume, pitch and pan of a playing sound, and the master volume.
    public let mixer = Mixer()

    /// False if no output device could be opened. Playing sounds is then harmless and silent.
    public private(set) var isAvailable = false

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var scratch: UnsafeMutablePointer<Float>?

    /// With `openDevice` false nothing is played: used when rendering without a window.
    public init(openDevice: Bool = true) {
        guard openDevice else { return }
        #if os(iOS)
        // "Ambient" mixes with whatever music is playing and obeys the silent switch: right for a game.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        // Two channels of floats, each in its own buffer: the system's standard layout.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(mixer.sampleRate), channels: 2) else { return }

        // The mixer produces interleaved samples (left, right, left, right). They are
        // rendered into this scratch buffer, allocated once: the audio thread must never
        // allocate memory or it may miss its deadline.
        let capacity = 4096
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 2)
        self.scratch = scratch
        let mixer = self.mixer

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let total = Int(frameCount)
            var done = 0
            while done < total {
                let count = min(capacity, total - done)
                mixer.render(into: scratch, frameCount: count)
                for channel in 0..<min(buffers.count, 2) {
                    guard let data = buffers[channel].mData else { continue }
                    let out = data.assumingMemoryBound(to: Float.self) + done
                    for i in 0..<count { out[i] = scratch[i * 2 + channel] }
                }
                done += count
            }
            return noErr
        }

        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            logWarning("no audio output (\(error.localizedDescription)): the game will be silent")
            return
        }
        self.engine = engine
        sourceNode = node
        isAvailable = true
    }

    deinit {
        engine?.stop()              // the audio thread stops calling us before the scratch buffer goes away
        scratch?.deallocate()
    }

    @discardableResult
    public func play(_ clip: AudioClip, options: PlayOptions = PlayOptions()) -> SoundHandle {
        mixer.play(clip, options: options)
    }

    public func stop(_ handle: SoundHandle) { mixer.stop(handle) }

    /// Decodes a WAV, AIFF, MP3 or AAC file into memory. Returns nil and logs if it cannot.
    public static func loadClip(path: String) -> AudioClip? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channelData = buffer.floatChannelData else {
            logError("cannot load sound \(path)")
            return nil
        }
        // The file arrives with one buffer per channel; a clip keeps them interleaved.
        let frames = Int(buffer.frameLength)
        let channels = Int(file.processingFormat.channelCount)
        var clip = AudioClip()
        clip.sampleRate = Int(file.processingFormat.sampleRate)
        clip.channels = channels
        clip.samples = [Float](repeating: 0, count: frames * channels)
        for channel in 0..<channels {
            let source = channelData[channel]
            for frame in 0..<frames { clip.samples[frame * channels + channel] = source[frame] }
        }
        return clip
    }
}
