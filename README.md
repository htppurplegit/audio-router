# Audio Router

A small macOS menu-bar app that sends each app's sound to the speaker you choose,
e.g. Spotify → Bluetooth speaker while FaceTime / WhatsApp stay on your AirPods or Mac speakers.

Requires macOS 14.2 or later (uses Core Audio process taps).

## Build & run
1. Install the command line tools once: `xcode-select --install`
2. In Terminal, in this folder: `./build.sh`
3. `open "build/Audio Router.app"` (or drag it into /Applications first, then open it)

A speaker icon appears in the menu bar. The first time you route an app, macOS asks for
**Audio Capture** permission — allow it. (If you dismissed it: System Settings → Privacy & Security
→ Screen & System Audio Recording → System Audio Recording Only → enable Audio Router.)

Because the app is ad-hoc signed, macOS may ask again after each rebuild.

## Use
- Apps appear once they've played any sound. Pick an output next to each one;
  "System default" means don't touch it.
- Choices are remembered per app. If the speaker disconnects, the app falls back to the
  system default and goes back to the speaker when it reconnects.

## Known limits
- Safari and other WebKit apps play through a shared system process, so they can't be
  separated reliably. Chrome, Firefox, Spotify, Music, Zoom, Teams etc. are fine.
- FaceTime/phone-call audio is handled partly by system services; leave calls on
  "System default" and route the music app instead.
- There's a little extra latency on routed apps (fine for music, not for gaming).
