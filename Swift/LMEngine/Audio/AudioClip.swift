// AudioClip.swift
// Sound as numbers: a clip is an array of samples between -1 and 1.
// Clips can be decoded from files by the Audio class, or generated here from a few
// parameters, which is how the sample games get their sound effects without shipping
// a single audio file.

import Foundation

public struct AudioClip {
    public var samples: [Float] = []        // interleaved if there is more than one channel
    public var sampleRate = 44100
    public var channels = 1

    public init() {}

    public var duration: Float {
        samples.isEmpty ? 0 : Float(samples.count) / Float(sampleRate * channels)
    }
}

public enum Waveform {
    case sine, square, triangle, sawtooth, noise
}

/// One synthesized note.
public struct SynthParams {
    public var waveform = Waveform.sine
    public var frequency: Float = 440       // in hertz, at the start
    public var frequencyEnd: Float = 0      // if above zero, the pitch slides to this value
    public var duration: Float = 0.2        // seconds
    public var attack: Float = 0.005        // seconds to fade in: avoids a click
    public var release: Float = 0.1         // seconds to fade out at the end
    public var volume: Float = 0.5
    public var seed: UInt64 = 1             // for Waveform.noise

    public init(waveform: Waveform = .sine, frequency: Float = 440, frequencyEnd: Float = 0, duration: Float = 0.2,
                attack: Float = 0.005, release: Float = 0.1, volume: Float = 0.5, seed: UInt64 = 1) {
        self.waveform = waveform
        self.frequency = frequency
        self.frequencyEnd = frequencyEnd
        self.duration = duration
        self.attack = attack
        self.release = release
        self.volume = volume
        self.seed = seed
    }
}

public func synthesize(_ params: SynthParams, sampleRate: Int = 44100) -> AudioClip {
    var clip = AudioClip()
    clip.sampleRate = sampleRate
    let count = max(Int(params.duration * Float(sampleRate)), 1)
    clip.samples = [Float](repeating: 0, count: count)

    var random = Random(seed: params.seed)
    var phase: Float = 0                                // position inside one cycle, 0..1
    let startFrequency = max(params.frequency, 1)
    let endFrequency = params.frequencyEnd > 0 ? params.frequencyEnd : startFrequency

    for i in 0..<count {
        let time = Float(i) / Float(sampleRate)
        let progress = Float(i) / Float(count)

        // Slide the pitch along a musical (exponential) curve and advance the phase by
        // one sample's worth of the current frequency.
        let frequency = startFrequency * pow(endFrequency / startFrequency, progress)
        phase += frequency / Float(sampleRate)
        phase -= floor(phase)

        var value: Float = 0
        switch params.waveform {
        case .sine: value = sin(phase * 2 * Float.pi)
        case .square: value = phase < 0.5 ? 1 : -1
        case .triangle: value = 1 - 4 * abs(phase - 0.5)
        case .sawtooth: value = 2 * phase - 1
        case .noise: value = random.range(-1, 1)
        }

        // Envelope: fade in over `attack`, fade out over the last `release` seconds.
        var envelope: Float = 1
        if params.attack > 0 { envelope = min(envelope, time / params.attack) }
        if params.release > 0 { envelope = min(envelope, (params.duration - time) / params.release) }
        clip.samples[i] = value * saturate(envelope) * params.volume
    }
    return clip
}

/// Several notes played one after another, as one clip.
public func synthesizeSequence(_ notes: [SynthParams], sampleRate: Int = 44100) -> AudioClip {
    var clip = AudioClip()
    clip.sampleRate = sampleRate
    for note in notes {
        clip.samples.append(contentsOf: synthesize(note, sampleRate: sampleRate).samples)
    }
    return clip
}
