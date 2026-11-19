// Sounds.swift
// The game's sound effects. None of them is a file: each is computed when the game
// starts from a few numbers (a waveform, a pitch that may slide, a duration).

import LMEngine

struct Sounds {
    var collect: AudioClip      // a gem was picked up
    var jump: AudioClip
    var land: AudioClip         // the marble hit something
    var fall: AudioClip         // the marble fell off the level
    var win: AudioClip
    var roll: AudioClip         // loops while the marble rolls

    static func make() -> Sounds {
        func note(_ waveform: Waveform, _ frequency: Float, _ duration: Float, _ volume: Float) -> SynthParams {
            SynthParams(waveform: waveform, frequency: frequency, duration: duration, release: duration * 0.6, volume: volume)
        }

        // Two quick notes a fifth apart: the classic "got it" chime.
        let collect = synthesizeSequence([note(.triangle, 880, 0.07, 0.35), note(.triangle, 1318.5, 0.22, 0.35)])

        // A pitch that slides up reads as "going up"; down, as falling.
        var jump = note(.sine, 260, 0.16, 0.4)
        jump.frequencyEnd = 520

        var fall = note(.sawtooth, 440, 0.6, 0.25)
        fall.frequencyEnd = 70

        // A very short low thump.
        var land = note(.sine, 110, 0.09, 0.6)
        land.frequencyEnd = 55
        land.attack = 0.002

        // A rising major arpeggio: C, E, G, C.
        let win = synthesizeSequence([note(.triangle, 523.25, 0.12, 0.35), note(.triangle, 659.25, 0.12, 0.35),
                                      note(.triangle, 783.99, 0.12, 0.35), note(.triangle, 1046.5, 0.5, 0.35)])

        // One second of noise. Played far below its recorded speed it becomes a low rumble.
        var roll = note(.noise, 0, 1, 0.5)
        roll.attack = 0
        roll.release = 0
        roll.seed = 5

        return Sounds(collect: collect, jump: synthesize(jump), land: synthesize(land), fall: synthesize(fall), win: win,
                      roll: synthesize(roll))
    }
}
