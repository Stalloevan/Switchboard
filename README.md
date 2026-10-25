# Switchboard

A small SwiftUI app that pairs with and controls Matter light bulbs straight from an iPhone. No hub and no HomeKit: the app is its own Matter controller (its own fabric) built on Apple's `Matter` framework.

## What it does

- Pair a bulb with its setup code (the 11-digit number on the bulb or box, or an `MT:` string).
- On/off, brightness, color temperature and color (when the bulb supports them).
- Control works over your home Wi-Fi, so the phone and bulbs must be on the same network.

## Scenes (wand icon, top left)

- **Sunrise:** starts very dim and warm, then brightens (and cools slightly) over 1 to 90 minutes. The bulb runs the ramp itself, so it keeps going if the app is closed.
- **Fade:** jump to one brightness or color, then glide to another over 5 seconds to 1 hour.
- **Music sync:** listens through the microphone and drives the bulbs from loudness and bass beats (Pulse, or Color on beat). iOS can't capture another app's audio, so the phone has to hear the music from a speaker. Keep the screen on; changes are rate-limited to about 7 per second per bulb.

## Shortcuts actions

Open the Shortcuts app, add an action, and search for Switchboard:

- Turn Bulb On or Off
- Set Brightness (percent, optional fade time)
- Set Color (named color, white temperature, or custom hex, optional fade time)
- Fade Between Brightness Levels (from, to, duration)
- Fade Between Two Colors (from, to, duration)
- Sunrise (duration in minutes)

Leave "Bulb" empty to affect all bulbs. For a wake-up light, create a time-of-day Automation that runs the Sunrise action.

Transitions are limited by Matter to about 109 minutes. Fading between a color and a white may jump rather than blend.

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
