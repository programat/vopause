# Vopause

Native macOS menu bar helper that watches input-device activity and pauses media playback while a microphone is in use.

## Quick Start

```bash
swift run VopauseCoreSmokeTests
./script/build_and_run.sh
```

Useful development modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
```

## Notes

- macOS 14+
- SwiftPM-only app bundle, staged into `dist/Vopause.app`
- development builds are ad-hoc signed with a stable designated requirement (`identifier dev.egor.vopause`) so Accessibility permission survives rebuilds after it is granted once
- microphone activity is observed through CoreAudio device state; the app does not record audio
- playback control first snapshots private MediaRemote player paths and sends discrete pause/play to those same system Now Playing sources; app-specific AppleScript, Control Center Now Playing Accessibility controls, app Playback-menu commands, and CoreAudio/global MediaRemote remain fallbacks
- resume runs only after Vopause previously sent a discrete pause command; it does not use play/pause toggle
