// Mixer.swift
// Turns "play this clip" into the stream of samples a sound card wants.
//
// The operating system asks for audio in small blocks, a few hundred times per second,
// on a thread of its own. Each time, the mixer walks its list of playing sounds
// ("voices"), reads the next piece of each clip at the right speed, scales it by its
// volume and pan, and adds everything together. That is all a software mixer is.
//
// The mixer has no idea what a sound card is: Audio (in Audio.swift) connects it to one.
// That keeps this file plain Swift that can be tested by calling render() directly.

import Foundation
import simd

public struct PlayOptions {
    public var volume: Float
    public var pitch: Float         // 2 is an octave higher and twice as fast, 0.5 an octave lower
    public var pan: Float           // -1 left, 0 center, 1 right
    public var loops: Bool

    public init(volume: Float = 1, pitch: Float = 1, pan: Float = 0, loops: Bool = false) {
        self.volume = volume
        self.pitch = pitch
        self.pan = pan
        self.loops = loops
    }
}

/// Identifies one playing sound. 0 means "no sound".
public typealias SoundHandle = UInt32

public final class Mixer {
    public static let maxVoices = 64
    private static let fadeFrames = 256         // about 6 milliseconds

    public let sampleRate: Int

    private struct Voice {
        var handle: SoundHandle
        var clip: AudioClip
        var position: Double = 0                // in frames of the clip; fractional, because of pitch
        var volume: Float
        var pitch: Float
        var pan: Float
        var loops: Bool
        var fadeOutFrames = -1                  // while stopping: output frames left before silence
    }

    private var voices: [Voice] = []
    private var master: Float = 1
    private var nextHandle: SoundHandle = 1
    private let lock = NSLock()                 // the game thread and the audio thread both touch `voices`

    public init(sampleRate: Int = 44100) {
        self.sampleRate = sampleRate
    }

    /// Starts playing a clip. Returns 0 if the clip is empty or too many sounds are playing.
    @discardableResult
    public func play(_ clip: AudioClip, options: PlayOptions = PlayOptions()) -> SoundHandle {
        if clip.samples.isEmpty || clip.channels < 1 { return 0 }
        lock.lock()
        defer { lock.unlock() }
        if voices.count >= Mixer.maxVoices { return 0 }
        let handle = nextHandle
        nextHandle = nextHandle == .max ? 1 : nextHandle + 1
        voices.append(Voice(handle: handle, clip: clip, volume: options.volume, pitch: options.pitch, pan: options.pan,
                            loops: options.loops))
        return handle
    }

    private func withVoice(_ handle: SoundHandle, _ body: (inout Voice) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let index = voices.firstIndex(where: { $0.handle == handle }) { body(&voices[index]) }
    }

    /// Stops a sound with a very short fade, so that cutting it does not click.
    public func stop(_ handle: SoundHandle) {
        withVoice(handle) { voice in
            if voice.fadeOutFrames < 0 { voice.fadeOutFrames = Mixer.fadeFrames }
        }
    }

    public func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        for i in voices.indices where voices[i].fadeOutFrames < 0 { voices[i].fadeOutFrames = Mixer.fadeFrames }
    }

    public func setVolume(_ handle: SoundHandle, _ volume: Float) { withVoice(handle) { $0.volume = volume } }
    public func setPitch(_ handle: SoundHandle, _ pitch: Float) { withVoice(handle) { $0.pitch = pitch } }
    public func setPan(_ handle: SoundHandle, _ pan: Float) { withVoice(handle) { $0.pan = pan } }

    public func isPlaying(_ handle: SoundHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return voices.contains { $0.handle == handle }
    }

    public var activeVoiceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return voices.count
    }

    public var masterVolume: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return master
        }
        set {
            lock.lock()
            master = newValue
            lock.unlock()
        }
    }

    /// Writes `frameCount` stereo frames to `output` (left, right, left, right, ...).
    /// This is what the audio thread calls.
    public func render(into output: UnsafeMutablePointer<Float>, frameCount: Int) {
        for i in 0..<frameCount * 2 { output[i] = 0 }
        lock.lock()
        defer { lock.unlock() }

        var v = 0
        while v < voices.count {
            var voice = voices[v]
            let clip = voice.clip                       // shares the samples, does not copy them
            let channels = clip.channels
            let clipFrames = Double(clip.samples.count / channels)
            // How far to move through the clip for every frame of output.
            let step = Double(max(voice.pitch, 0.01)) * Double(clip.sampleRate) / Double(sampleRate)
            // Balance: at the center both sides play at full volume; panning lowers the far side.
            let pan = min(max(voice.pan, -1), 1)
            let left = voice.volume * min(1, 1 - pan)
            let right = voice.volume * min(1, 1 + pan)

            var isFinished = false
            clip.samples.withUnsafeBufferPointer { samples in
                for frame in 0..<frameCount {
                    if voice.position >= clipFrames {
                        if !voice.loops {
                            isFinished = true
                            break
                        }
                        voice.position = voice.position.truncatingRemainder(dividingBy: clipFrames)
                    }
                    // The position falls between two samples of the clip: blend them.
                    let index = Int(voice.position)
                    var next = index + 1
                    if next >= Int(clipFrames) { next = voice.loops ? 0 : index }
                    let blend = Float(voice.position - Double(index))
                    let sampleLeft = lerp(samples[index * channels], samples[next * channels], blend)
                    var sampleRight = sampleLeft
                    if channels > 1 {
                        sampleRight = lerp(samples[index * channels + 1], samples[next * channels + 1], blend)
                    }

                    var fade: Float = 1
                    if voice.fadeOutFrames >= 0 {
                        fade = Float(voice.fadeOutFrames) / Float(Mixer.fadeFrames)
                        voice.fadeOutFrames -= 1
                        if voice.fadeOutFrames < 0 {
                            isFinished = true
                            break
                        }
                    }
                    output[frame * 2] += sampleLeft * left * fade
                    output[frame * 2 + 1] += sampleRight * right * fade
                    voice.position += step
                }
            }

            if isFinished {
                voices.swapAt(v, voices.count - 1)      // order does not matter: fill the hole with the last voice
                voices.removeLast()
            } else {
                voices[v] = voice
                v += 1
            }
        }

        // Many loud sounds at once can add up to more than a sample can hold.
        for i in 0..<frameCount * 2 { output[i] = min(max(output[i] * master, -1), 1) }
    }

    /// The same, into a new array: handy for tests and for writing sound to a file.
    public func render(frameCount: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frameCount * 2)
        output.withUnsafeMutableBufferPointer { buffer in
            if let pointer = buffer.baseAddress { render(into: pointer, frameCount: frameCount) }
        }
        return output
    }
}

/// The volume and pan that make a sound seem to come from a place in the world.
public struct SpatialGain {
    public var volume: Float = 1
    public var pan: Float = 0
}

/// `listenerWorld` is the world matrix of whoever is listening, usually the camera.
/// The sound plays at full volume within `fullVolumeDistance` and is silent at `maxDistance`.
public func spatialize(listenerWorld: Mat4, position: Vec3, fullVolumeDistance: Float = 2, maxDistance: Float = 40) -> SpatialGain {
    let toSound = position - xyz(listenerWorld.columns.3)
    let distance = simd_length(toSound)
    let t = saturate((distance - fullVolumeDistance) / max(maxDistance - fullVolumeDistance, 0.001))
    var gain = SpatialGain()
    gain.volume = (1 - t) * (1 - t)
    if distance > 0.0001 {
        let right = safeNormalize(xyz(listenerWorld.columns.0), fallback: Vec3(1, 0, 0))
        gain.pan = simd_dot(toSound / distance, right) * 0.8        // never entirely in one ear
    }
    return gain
}
