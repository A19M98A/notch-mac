# NotchPulse

[![macOS 12+](https://img.shields.io/badge/macOS-12%20Monterey%2B-black?logo=apple&logoColor=white)](#requirements)
[![Universal](https://img.shields.io/badge/Arch-Apple%20Silicon%20%26%20Intel-blue)](#download--install)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20CoreAudio-orange?logo=swift&logoColor=white)](#build-from-source)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**NotchPulse** is a lightweight, native macOS Dynamic Notch overlay that turns the top-center of your display into a live command center for audio, media, microphone effects, network speeds, VPN routing, timers, and clipboard history.

---

## Features

- **3-Stage Dynamic Notch UX**
  - **Idle Strip**: Ultra-slim (`14px`) top pill showing minimal status dots (VPN active, media playing, timer running).
  - **Hover Peek**: Immediately expands on hover to show **live download/upload speeds & session totals** (fixed-width columns, zero jitter), VPN status, timer countdown, or mini equalizer.
  - **Click / `⌥Space` Full Panel**: Smooth translucent frosted dark glass panel with customizable tabs and pin-open toggle.
- **Multi-Source Media Deck (`Media`)**
  - Simultaneously detects **Spotify**, **Apple Music**, **YouTube**, **YouTube Music**, **SoundCloud**, **Twitch**, **Telegram**, and any active audio app.
  - Switch between multiple live sources, view artwork & animated equalizer, scrub track progress, focus the exact app/tab, or mute individual sources.
- **Master & Per-App Volume Mixer (`Mixer`)**
  - Master system volume + mute alongside **independent per-app volume sliders** using macOS CoreAudio Process Taps (`macOS 14.2+`).
- **Audio Output Switcher (`Output`)**
  - One-click switching across Built-in Speakers, AirPods, Bluetooth headphones, USB DACs, HDMI, and AirPlay.
- **Mic Studio & Real-Time Voice Effects (`Mic`)**
  - Switch microphones, adjust gain/mute, watch the live VU meter, and apply native `AVAudioEngine` DSP effects (**Studio, Podcast, Radio, Deep, High, Robot, Hall Reverb, Echo, Noise Cut**).
  - Automatic routing to **BlackHole 2ch** (with automatic system default mic switching & restore when toggling FX ON/OFF) plus an independent **Headphone Monitor** toggle.
- **Standalone VPN & Split-Tunnel Manager (`VPN`)**
  - 100% standalone native core supporting **VLESS, VMess, Trojan, Shadowsocks, SSH, Hysteria2, SOCKS5, HTTP** (`sing-box`), **OpenConnect**, and **macOS System VPNs** (`scutil --nc`).
  - Dedicated Notch-style VPN Manager window with clipboard URI import, subscriptions, manual server editor, real TCP ping tester, JSON import/export, and split-tunnel rules (including live **Google & YouTube IPv4 ranges** and **Valve Steam SDR** clusters).
- **Quick Timer / Pomodoro (`Timer`)**
  - Built-in focus/break presets with live countdown right inside the notch.
- **Persistent Clipboard History (`Clips`)**
  - Saves up to your last **100 clips** (configurable up to 200) across app restarts and macOS reboots, with pinning and one-click re-copy.
- **Full Settings Panel (`⚙`)**
  - Show/hide individual modules, customize transparency, heights, collapse delay, hover network monitor, Launch at Login, and live **Permissions & System** health checks.

---

## Requirements

- **macOS 12 Monterey or newer** (Universal binary for both **Apple Silicon** and **Intel** Macs).
- *Optional*:
  - **macOS 14.2+** for Per-App Volume Mixing (CoreAudio Process Taps).
  - [`blackhole-2ch`](https://existential.audio/blackhole/) (`brew install blackhole-2ch`) to route Mic FX into Telegram, Discord, Zoom, or OBS.
  - [`sing-box`](https://sing-box.sagernet.org/) (`brew install sing-box`) and/or `openconnect` (`brew install openconnect`) for standalone VPN tunnels.

---

## Download & Install

1. Download `NotchPulse-1.0.0-macOS-Universal.zip` from [Releases](https://github.com/A19M98A/notch-mac/releases).
2. Unzip and move **`NotchPulse.app`** into `/Applications`.
3. Because the release is ad-hoc signed, remove the macOS quarantine attribute once:
   ```bash
   xattr -cr /Applications/NotchPulse.app
   open /Applications/NotchPulse.app
   ```

### Optional: Passwordless VPN Connect/Disconnect
To connect/disconnect `sing-box` or `openconnect` tunnels without entering your password each time, run once:
```bash
./scripts/install_vpn_helper.sh
```

---

## Build from Source

```bash
git clone https://github.com/A19M98A/notch-mac.git
cd notch-mac
./scripts/build_app.sh
```

This compiles a **Universal (`arm64` + `x86_64`)** release targeting **macOS 12.0+** and outputs:
- `dist/NotchPulse.app`
- `dist/NotchPulse-1.0.0-macOS-Universal.zip`

---

## License

MIT License — see [LICENSE](LICENSE).
