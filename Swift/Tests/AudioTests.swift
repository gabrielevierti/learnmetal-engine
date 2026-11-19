import XCTest
import simd
@testable import LMEngine

private func constantClip(_ value: Float, frames: Int, sampleRate: Int = 44100, channels: Int = 1) -> AudioClip {
    var clip = AudioClip()
    clip.sampleRate = sampleRate
    clip.channels = channels
    clip.samples = [Float](repeating: value, count: frames * channels)
    return clip
}

final class AudioTests: XCTestCase {
    func testMixerPlaysAClipOnceThenGoesQuiet() {
        let mixer = Mixer(sampleRate: 44100)
        let handle = mixer.play(constantClip(0.5, frames: 100))
        XCTAssertNotEqual(handle, 0)
        XCTAssertTrue(mixer.isPlaying(handle))

        let out = mixer.render(frameCount: 300)
        XCTAssertEqual(out[0], 0.5, accuracy: 1e-6)                 // first frame, left
        XCTAssertEqual(out[1], 0.5, accuracy: 1e-6)                 // first frame, right
        XCTAssertEqual(out[99 * 2], 0.5, accuracy: 1e-6)            // last frame of the clip
        XCTAssertEqual(out[100 * 2], 0, accuracy: 1e-6)             // silence after it
        XCTAssertEqual(out[299 * 2 + 1], 0, accuracy: 1e-6)
        XCTAssertFalse(mixer.isPlaying(handle))
        XCTAssertEqual(mixer.activeVoiceCount, 0)
    }

    func testMixerVolumePanAndMasterVolume() {
        let mixer = Mixer(sampleRate: 44100)
        mixer.play(constantClip(0.8, frames: 64), options: PlayOptions(volume: 0.5, pan: -1))      // all the way left
        var out = mixer.render(frameCount: 64)
        XCTAssertEqual(out[10], 0.4, accuracy: 1e-6)
        XCTAssertEqual(out[11], 0, accuracy: 1e-6)

        mixer.play(constantClip(0.8, frames: 64), options: PlayOptions(volume: 0.5, pan: 0.5))     // half right: the left side drops to half
        mixer.masterVolume = 0.5
        out = mixer.render(frameCount: 64)
        XCTAssertEqual(out[10], 0.8 * 0.5 * 0.5 * 0.5, accuracy: 1e-6)
        XCTAssertEqual(out[11], 0.8 * 0.5 * 0.5, accuracy: 1e-6)
    }

    func testMixerAddsVoicesAndClamps() {
        let mixer = Mixer(sampleRate: 44100)
        mixer.play(constantClip(0.3, frames: 32))
        mixer.play(constantClip(0.4, frames: 32))
        var out = mixer.render(frameCount: 32)
        XCTAssertEqual(out[0], 0.7, accuracy: 1e-6)

        mixer.play(constantClip(0.9, frames: 32))
        mixer.play(constantClip(0.9, frames: 32))
        out = mixer.render(frameCount: 32)
        XCTAssertEqual(out[0], 1, accuracy: 1e-6)                   // 1.8 does not fit: clamped
    }

    func testMixerPitchAndSampleRateChangeTheSpeed() {
        let mixer = Mixer(sampleRate: 44100)
        let fast = mixer.play(constantClip(0.5, frames: 100), options: PlayOptions(pitch: 2))
        let out = mixer.render(frameCount: 60)
        XCTAssertEqual(out[49 * 2], 0.5, accuracy: 1e-6)            // 100 frames at double speed last 50
        XCTAssertEqual(out[50 * 2], 0, accuracy: 1e-6)
        XCTAssertFalse(mixer.isPlaying(fast))

        // A clip recorded at half the mixer's rate must last twice as many output frames.
        let slow = mixer.play(constantClip(0.5, frames: 100, sampleRate: 22050))
        let longer = mixer.render(frameCount: 220)
        XCTAssertEqual(longer[199 * 2], 0.5, accuracy: 1e-6)
        XCTAssertEqual(longer[200 * 2], 0, accuracy: 1e-6)
        XCTAssertFalse(mixer.isPlaying(slow))
    }

    func testMixerInterpolatesBetweenSamples() {
        var ramp = AudioClip()
        ramp.samples = [0, 1, 0, 1]
        let mixer = Mixer(sampleRate: 44100)
        mixer.play(ramp, options: PlayOptions(pitch: 0.5))
        let out = mixer.render(frameCount: 4)
        XCTAssertEqual(out[0], 0, accuracy: 1e-6)
        XCTAssertEqual(out[2], 0.5, accuracy: 1e-6)                 // halfway between the first two samples
        XCTAssertEqual(out[4], 1, accuracy: 1e-6)
        XCTAssertEqual(out[6], 0.5, accuracy: 1e-6)
    }

    func testMixerLoopsAndStopsWithAFade() {
        let mixer = Mixer(sampleRate: 44100)
        let handle = mixer.play(constantClip(0.5, frames: 10), options: PlayOptions(loops: true))
        var out = mixer.render(frameCount: 1000)
        XCTAssertEqual(out[999 * 2], 0.5, accuracy: 1e-6)           // still going, 100 times around
        XCTAssertTrue(mixer.isPlaying(handle))

        mixer.stop(handle)
        out = mixer.render(frameCount: 1000)
        XCTAssertEqual(out[0], 0.5, accuracy: 1e-6)                 // the fade starts at full volume
        XCTAssertTrue(out[100 * 2] < 0.5 && out[100 * 2] > 0)       // and is on its way down
        XCTAssertEqual(out[600 * 2], 0, accuracy: 1e-6)
        XCTAssertFalse(mixer.isPlaying(handle))
    }

    func testMixerStereoClipsKeepTheirSides() {
        var clip = AudioClip()
        clip.channels = 2
        clip.samples = [0.2, 0.6, 0.2, 0.6, 0.2, 0.6]
        let mixer = Mixer(sampleRate: 44100)
        mixer.play(clip)
        let out = mixer.render(frameCount: 3)
        XCTAssertEqual(out[2], 0.2, accuracy: 1e-6)
        XCTAssertEqual(out[3], 0.6, accuracy: 1e-6)
    }

    func testMixerRefusesEmptyClipsAndTooManyVoices() {
        let mixer = Mixer(sampleRate: 44100)
        XCTAssertEqual(mixer.play(AudioClip()), 0)
        let clip = constantClip(0.01, frames: 1000)
        for _ in 0..<Mixer.maxVoices { XCTAssertNotEqual(mixer.play(clip), 0) }
        XCTAssertEqual(mixer.play(clip), 0)
        mixer.stopAll()
        _ = mixer.render(frameCount: 1000)
        XCTAssertEqual(mixer.activeVoiceCount, 0)
    }

    func testSpatializeGivesVolumeByDistanceAndPanBySide() {
        let listener = matrix_identity_float4x4                     // at the origin, looking down -Z, +X to the right
        let near = spatialize(listenerWorld: listener, position: Vec3(0, 0, -1))
        XCTAssertEqual(near.volume, 1, accuracy: 1e-6)
        XCTAssertEqual(near.pan, 0, accuracy: 1e-6)

        let right = spatialize(listenerWorld: listener, position: Vec3(10, 0, 0))
        XCTAssertEqual(right.pan, 0.8, accuracy: 1e-5)
        XCTAssertTrue(right.volume < 1 && right.volume > 0)

        let left = spatialize(listenerWorld: listener, position: Vec3(-10, 0, 0))
        XCTAssertEqual(left.pan, -0.8, accuracy: 1e-5)

        let far = spatialize(listenerWorld: listener, position: Vec3(0, 0, -100))
        XCTAssertEqual(far.volume, 0, accuracy: 1e-6)

        let half = spatialize(listenerWorld: listener, position: Vec3(0, 0, -21), fullVolumeDistance: 2, maxDistance: 40)
        XCTAssertEqual(half.volume, 0.25, accuracy: 1e-5)           // halfway out: (1 - 0.5) squared
    }
}
