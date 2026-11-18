# Unbound

Use an Android tablet as a **true extended display** for a Mac — a genuine second
desktop, not mirroring — over USB-C or Wi-Fi, with touch, mouse, scroll and keyboard input.

> Status: **release candidate 1.0.0.** Feasibility gate passed on Apple Silicon (macOS 27).
> Before publishing: a Developer ID certificate + notarization for the Mac app (see Releasing),
> a real download URL, and Intel Mac validation.

```
Mac (Unbound.app)                                           Android tablet (Unbound app)
CGVirtualDisplay ─► ScreenCaptureKit ─► VideoToolbox H.264 ─► USB-C (AOA) / Wi-Fi ─► MediaCodec ─► SurfaceView
       ▲                                                                                   │
       └──────────── CGEvent mouse / scroll / keyboard ◄──────── touch · mouse · keyboard ─┘
```

## For users

1. **Mac:** open `Unbound-1.0.0.dmg`, drag Unbound to Applications, open it. It lives in the menu bar.
   Grant **Screen Recording** (then relaunch) and **Accessibility** from its menu.
2. **Tablet:** install `Unbound-1.0.0.apk` (or from the store).
3. **Connect:**
   - **USB-C:** plug the tablet into the Mac. The tablet asks *“Open Unbound to handle Unbound Display?”*
     — tick *Always* and tap **OK**. No developer mode needed.
   - **Wi-Fi:** open the app on the tablet and tap your Mac in the list. The Mac asks once to allow it.

Drag windows onto the new display; arrange it in **System Settings › Displays**. Pick resolution
(including Retina presets) and 60/90/120 Hz from the menu-bar icon.

## For developers

```bash
scripts/run-usb.sh            # build both sides, install the debug app, run the CLI host @ 90 fps
scripts/package.sh            # release artifacts → dist/ (DMG + APK)
```

`scripts/run-usb.sh` uses the **adb** path (needs USB debugging). Note: a running adb server owns
the tablet's USB device exclusively, so the consumer USB-C path (`--aoa`, used by the app) can't
take it at the same time — run `adb kill-server` first; the host tells you when this happens.

The project pins **JDK 21** via jenv (`.java-version`).

### macOS permissions

| Permission | Needed for | If missing |
|---|---|---|
| Screen Recording | capturing the virtual display | app shows a Grant button; CLI exits with instructions |
| Accessibility | touch / keyboard control of the Mac | video works, input is ignored |
| Local Network | Wi-Fi discovery | Wi-Fi tablets can't find the Mac (USB still works) |

## Other ways to run

```bash
cd mac && swift build -c release
.build/release/unbound-host serve --aoa --fps 90                 # USB-C, no developer mode
.build/release/unbound-host serve --usb --fps 90                 # USB via adb (developer mode)
.build/release/unbound-host usb                                # which USB devices look like Android
.build/release/unbound-host serve --fps 60                       # Wi-Fi: type the printed IP in the app
.build/release/unbound-host serve --width 1152 --height 720 --hidpi   # Retina-sharp, larger UI
.build/release/unbound-host capabilities                         # Mac / encoder / permission report
.build/release/unbound-host probe --cycles 20                    # display create/destroy stress test
```

Display options: `--width --height` (mode size in points), `--hidpi` (2× pixels),
`--fps N` (stream rate and display refresh; default 60), `--bitrate MBPS` (max, default 12).
Wi-Fi works best with both devices on the **same** network; across routers/hotspots throughput drops
and adaptive bitrate lowers quality.

### Tablet gestures

| Gesture | Mac action |
|---|---|
| Tap / double-tap | click / double-click |
| Press and drag | drag |
| Long-press | right-click |
| Two-finger drag | scroll |
| Three-finger tap | toggle stats overlay |
| Back | disconnect |
| USB/Bluetooth mouse, keyboard | passed through (Meta/Windows key = ⌘) |

## Repository

```
mac/                     Swift 6 package (macOS 13+)
  Sources/CGVirtualDisplayBridge   ObjC shim; private API resolved at runtime, never crashes
  Sources/UnboundHostCore
    Display/    VirtualDisplayProvider abstraction, private provider, DisplayModeManager
    Capture/    ScreenCaptureKit (virtual display only)
    Encoding/   VideoToolbox H.264 (low-latency rtvc), Annex-B
    Transport/  MediaTransport abstraction, TCP server, USB/adb bridge, adaptive bitrate
    Input/      CGEvent injection
    Protocol/   wire format
  Sources/unbound-host               CLI: serve / probe / capabilities
android/                 Kotlin client (minSdk 26), MediaCodec + SurfaceView
docs/                    protocol, ADRs, sprint reports
scripts/run-usb.sh       one-command USB workflow
```

Tests: `cd mac && swift test` · `cd android && ./gradlew testDebugUnitTest`
(the protocol tests on both sides assert identical byte layouts).

## Releasing

`scripts/package.sh` builds `dist/Unbound-<version>.dmg` and `dist/Unbound-<version>.apk`.

| Item | Status |
|---|---|
| Mac: universal binary, app bundle, icon, hardened runtime, DMG | done |
| Mac: **Developer ID Application** certificate | **needed** — without it other Macs block the app |
| Mac: notarization | automatic once `NOTARY_PROFILE` is set (see script header) |
| Android: signed, minified release APK | done — key in `~/.unbound-signing/` (**back it up**) |
| Download URL shown by Android when the app is missing | placeholder `UnboundProduct.downloadURL` |
| Intel Macs | builds; untested on hardware (ADR-012) |
| Wi-Fi encryption | not yet — Wi-Fi is approval-gated but unencrypted; USB-C is a direct cable |

## Roadmap

| Next | Outcome |
|---|---|
| Security | TLS + pinned device identity for Wi-Fi (ADR-007/009) |
| Transport | WebRTC for Wi-Fi congestion control |
| Input | stylus pressure, on-screen keyboard, trackpad-style gestures |
| Updates | Sparkle (Mac) + Play Store / in-app update check (Android) |
