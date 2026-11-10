# Snapper

A small menu bar screenshot app for macOS. Region, window, full screen and scrolling capture;
every capture goes to the clipboard and is saved as a PNG; a simple editor adds arrows, boxes,
text, highlights, numbered steps and crop.

## Shortcuts

| Keys | Action |
|---|---|
| Shift-Option-C | Capture a region (drag) or a window (click) |
| Shift-Option-F | Capture the full screen |
| Shift-Option-S | Scrolling capture: pick the area, scroll down slowly, press Return |

## Build

    ./build.sh

Builds with Swift Package Manager, signs with the local Apple Development identity and installs
to /Applications. Tests: `swift test`.

Captures are saved to `~/Pictures/Screenshots`. A log of every capture is kept at
`~/Library/Logs/Snapper.log`.
