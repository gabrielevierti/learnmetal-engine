# FPV for iPhone and iPad

The game is in `Swift/FPVKit`; this folder only holds what makes it an iOS app.

## Build it

```sh
brew install xcodegen
cd iOS
xcodegen generate
open FPV.xcodeproj
```

In Xcode, select the FPV target, choose your team under **Signing & Capabilities**, pick your iPhone and press Run.

Without XcodeGen: create a new iOS App project (Storyboard interface, then delete the storyboard, `SceneDelegate.swift` and the scene entries in Info.plist), add the repository as a local package with the products `FPVKit` and `LMEngine`, replace the app delegate with `App/AppDelegate.swift`, and drag the `Shaders` and `Assets` folders in as **folder references** (blue folders) so that they are copied into the app as they are.

## Controls

- **Thumbs.** Left stick: throttle (it stays where you leave it) and yaw. Right stick: pitch and roll. The buttons along the top open the menu, start again, switch between the onboard and the chase view, and between Angle and Acro.
- **A controller.** Anything iOS accepts as a game controller: Xbox, PlayStation, MFi. Left stick throttle and yaw, right stick pitch and roll; A starts again, X switches Angle and Acro, Y the view, B goes to the menu.
- **An RC radio.** iOS only lets apps see controllers through its GameController framework, so a radio must present itself as a gamepad, not as a plain USB joystick. The BETAFPV LiteRadio 2 SE and LiteRadio 3 (the radio of the Cetus kits) gained an Xbox mode in their recent firmware: that is the mode to use, over USB-C or a Lightning adapter. Leave **Controller throttle: whole stick** on in the menu, which is the default: a radio's throttle stick does not spring back to the middle.
