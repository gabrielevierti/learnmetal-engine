// Sounds.swift
// Every sound of the game, computed when it starts: no audio files.

import Foundation
import LMEngine

struct Sounds {
    var motor = AudioClip()         // one motor at 100 turns per second, to loop and re-pitch
    var wind = AudioClip()          // rushing air, to loop
    var beep = AudioClip()
    var go = AudioClip()
    var gate = AudioClip()
    var lap = AudioClip()
    var finish = AudioClip()
    var crash = AudioClip()
    var alarm = AudioClip()

    private static func note(_ waveform: Waveform, _ frequency: Float, _ duration: Float, _ volume: Float) -> SynthParams {
        SynthParams(waveform: waveform, frequency: frequency, duration: duration, release: duration * 0.5, volume: volume)
    }

    /// The whine of one motor and its propeller, turning 100 times per second. Half a
    /// second holds exactly 50 turns, so the clip loops without a click. The game plays
    /// four of these and changes the pitch of each to follow its motor.
    private static func motorLoop() -> AudioClip {
        var clip = AudioClip()
        // The turn itself, then its multiples. The second and third are the loudest: that is
        // the blades going by, the note people recognize as "a drone".
        let strengths: [Float] = [0.45, 1.0, 0.8, 0.4, 0.32, 0.2, 0.14, 0.09]
        let phases: [Float] = [0.0, 1.3, 2.9, 0.7, 4.1, 2.2, 5.0, 3.3]
        let rate = clip.sampleRate
        clip.samples = (0..<(rate / 2)).map { i in
            let t = Float(i) / Float(rate)
            var sample: Float = 0
            for n in 0..<8 { sample += strengths[n] * sin(2 * Float.pi * 100 * Float(n + 1) * t + phases[n]) }
            return sample * 0.11
        }
        return clip
    }

    /// Air rushing past: noise with the hiss taken out. The end is faded into the beginning,
    /// so that it loops without a seam.
    private static func windLoop() -> AudioClip {
        var clip = AudioClip()
        let count = clip.sampleRate * 2, overlap = clip.sampleRate / 5
        var random = Random(seed: 17)
        var slow: Float = 0, slower: Float = 0
        var noise = [Float](repeating: 0, count: count + overlap)
        for i in 0..<noise.count {
            // Two simple low-pass filters in a row.
            slow += (random.range(-1, 1) - slow) * 0.12
            slower += (slow - slower) * 0.2
            noise[i] = slower * 2.4
        }
        clip.samples = (0..<count).map { i in
            let fade: Float = i < overlap ? Float(i) / Float(overlap) : 1
            return noise[i] * fade + (i < overlap ? noise[count + i] * (1 - fade) : 0)
        }
        return clip
    }

    static func make() -> Sounds {
        var sounds = Sounds()
        sounds.motor = motorLoop()
        sounds.wind = windLoop()
        // The start lights: three low beeps and a long high one.
        sounds.beep = synthesize(note(.sine, 660, 0.14, 0.35))
        sounds.go = synthesize(note(.sine, 1320, 0.5, 0.35))
        sounds.gate = synthesize(note(.triangle, 1320, 0.09, 0.3))
        sounds.lap = synthesizeSequence([note(.triangle, 1320, 0.08, 0.3), note(.triangle, 1760, 0.16, 0.3)])
        sounds.finish = synthesizeSequence([note(.triangle, 523.25, 0.13, 0.3), note(.triangle, 659.25, 0.13, 0.3),
                                            note(.triangle, 783.99, 0.13, 0.3), note(.triangle, 1046.5, 0.4, 0.3)])
        // A crash: a crack of noise.
        sounds.crash = synthesize(SynthParams(waveform: .noise, frequency: 0, duration: 0.4, attack: 0.001, release: 0.35, volume: 0.6, seed: 3))
        // The battery alarm of a flight controller's buzzer.
        sounds.alarm = synthesizeSequence([note(.square, 2700, 0.09, 0.12), note(.square, 2700, 0.09, 0), note(.square, 2700, 0.09, 0.12)])
        return sounds
    }
}
