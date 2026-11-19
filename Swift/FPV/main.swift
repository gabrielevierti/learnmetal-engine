// FPV on a Mac: the same game as on the iPhone, in a window.
//
//   swift run FPV
//
// W / S          throttle up and down (it stays where you leave it, like a radio's)
// A / D          yaw            arrows   pitch and roll
// R start again  M angle / acro   C onboard / chase   Esc menu   Enter starts a race
// A controller works too: left stick throttle and yaw, right stick pitch and roll.

import Foundation
import FPVKit
import LMEngine

var defaults = EngineConfig()
defaults.title = "FPV"
let engine = Engine(config: EngineConfig.fromArguments(CommandLine.arguments, defaults: defaults))
exit(engine.run(FPVGame()))
