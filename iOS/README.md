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

- **Thumbs.** Left stick: throttle (it stays where you leave it) and yaw. Right stick: pitch and roll.
- **A controller.** Anything iOS accepts as a game controller: Xbox, PlayStation, MFi. Left stick throttle and yaw, right stick pitch and roll; A resets, X switches Angle and Acro, B goes to the menu.
- **An RC radio.** iOS only lets apps see controllers through its GameController framework, so a radio must present itself as a gamepad. Radios with an "Xbox" or "gamepad" USB mode (the BETAFPV LiteRadio 2 SIM has one) are the ones to try, over USB-C or a Lightning adapter; a radio in plain "joystick" mode may not be seen at all. Set **Controller throttle: whole stick** in the menu, which is the default. This has not been tried with real hardware.

## Not checked

This app was written without a Mac: it has never been compiled or run. See the main README.
