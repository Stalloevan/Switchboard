# Switchboard

A small SwiftUI app that pairs with and controls Matter light bulbs straight from an iPhone. No hub and no HomeKit: the app is its own Matter controller (its own fabric) built on Apple's `Matter` framework.

## What it does

- Pair a bulb with its setup code (the 11-digit number on the bulb or box, or an `MT:` string).
- On/off, brightness, color temperature and color (when the bulb supports them).
- Control works over your home Wi-Fi, so the phone and bulbs must be on the same network.

## Scenes (wand icon, top left)

- **Fade:** jump to one brightness or color, then step smoothly to another over 5 seconds to 1 hour. Brightness moves in whole 1% steps; color is blended in many tiny hue/saturation steps. Switchboard drives every step, so the app stays open and the screen stays on while a fade runs. If a fade is shorter than about 10 steps per second allows, the steps get larger instead.
- **Music sync:** listens through the microphone and drives the bulbs from loudness and bass beats (Pulse, or Color on beat). iOS can't capture another app's audio, so the phone has to hear the music from a speaker. It sends the newest value as fast as each bulb accepts commands.

## Shortcuts actions

Open the Shortcuts app, add an action, and search for Switchboard:

- Turn Bulb On or Off
- Set Brightness (percent)
- Set Color (named color, white temperature, or custom hex)
- Fade Between Brightness Levels (from, to, duration)
- Fade Between Two Colors (from, to, duration)

Leave "Bulb" empty to affect all bulbs. The two fade actions open Switchboard and keep it on screen until the fade finishes.

## Pairing a bulb

1. Reset the bulb so it is in pairing mode (usually power-cycle it 3 to 5 times; check the bulb's manual).
2. In the app, tap **+**, enter the setup code, and enter your **2.4 GHz** Wi-Fi name and password.
3. Tap **Pair**. iOS will ask for Bluetooth and Local Network access the first time; allow both.

If the bulb is already on your Wi-Fi because another app owns it, open a commissioning window from that app ("share" or "add to another app") and use the temporary code it gives you. Leave the Wi-Fi fields blank in that case.

Thread bulbs are not supported without a Thread border router (HomePod, Apple TV 4K, etc.). Wi-Fi Matter bulbs work with just the phone.

## Building

CI builds an unsigned IPA whenever `VERSION` changes on `main` and publishes it as a GitHub release. Sign the IPA with your usual sideloading tool before installing.

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`.

## Notes and limits

- Bulbs are assumed to expose their light on endpoint 1, which is the norm.
- Device attestation failures are ignored while pairing, because a personal controller doesn't carry Matter's full certificate trust store. Only pair bulbs you own.
- The fabric's signing key lives in the Keychain and its data in the app's Application Support folder. Reinstalling with a different signing identity can lose the key, in which case bulbs must be factory reset and paired again.
- Removing a bulb in the app only forgets it locally; factory reset the bulb before pairing it elsewhere.

## Credits

The app icon is the Matter logo from [Dashboard Icons](https://dashboardicons.com) by Homarr Labs; the exact source URL is recorded in each release's notes.
