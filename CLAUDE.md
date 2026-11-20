# CLAUDE.md

Snapper is Jawaz's own menu bar screenshot app for macOS, built to replace Snagit. Screenshots only,
no video. `README.md` is the user-facing documentation and the code map: read it first, and keep it
current when behaviour changes. This file holds what a new session needs that the README does not say.

## Ground rules

- Jawaz uses Snapper many times a day. The clipboard copy must never fail silently: that is why the
  app exists.
- He is not a Swift developer. Explain changes in plain English, and verify them yourself rather than
  asking him to test. Say plainly what you could not verify.
- Rebuilding and restarting the app while he works is fine.
- Never simulate key presses on his keyboard and never drive the mouse to test. Use the `snapper://`
  hooks and the in-app self-tests below.
- Never handle his Apple ID or the app-specific password. He types those himself.
- Do not change System Settings (Login Items, privacy switches). Ask him to.
- Commit after each working change with a short message, and push. The About panel's build number is
  the commit count, so it rises by itself.

## Build, run, test

    ./build.sh && open /Applications/Snapper.app     # local build, installs and relaunches
    swift test                                       # stitching logic, 6 tests

- To compile without touching the installed app: `./build.sh --no-install` (builds and signs into
  `build/` only). `./release.sh --no-notarise` stops before anything is sent to Apple.
- `build.sh` signs with the **Apple Development** identity. Keep it that way: a stable identity is
  what keeps the Screen Recording permission across rebuilds. This build only opens on his Mac.
- Swift 6.4 toolchain, Swift 5 language mode, macOS 14+, no third-party packages. Keep it that way
  unless there is a strong reason.
- The build prints a few warnings (for example in `MainMenu.swift`). They are harmless.
- Log: `~/Library/Logs/Snapper.log`. Every capture writes size, clipboard result, file and timings.

## Releasing a copy for other people

    ./release.sh        # universal build, Developer ID signed, notarised, stapled, zipped

- Output: `build/release/Snapper-<version>.zip`. That zip, or the `Snapper.app` beside it, is the
  only thing to give anyone. Never the copy in `/Applications`.
- Uses the **Developer ID Application** certificate (team K9MT44M2RM, in the login keychain) and the
  keychain profile `snapper-notary`. Both are already set up.
- Notarisation waits on Apple. It is usually minutes, but the first submissions took 11 hours. Run it
  in the background. If one sticks at "In Progress", resubmitting the same zip is harmless and got an
  answer in 14 minutes. Check with `xcrun notarytool history --keychain-profile snapper-notary`.
- Verify before saying it is ready: unzip a copy, then `xcrun stapler validate` and
  `spctl --assess --type execute -vv` must report "Notarized Developer ID".
- Publish with `gh release create v<version> <zip> -R illavia/snapper --target <full commit sha>`
  (a short sha is rejected). The repo is private, so release links only work for Jawaz.
- Bump `CFBundleShortVersionString` in `Info.plist` by hand when a release means something.
- The Mac App Store is on hold by his decision. It would need sandboxing and a different capture
  permission flow. Do not start it unprompted.

## Testing without a person

The app answers `snapper://` URLs. The list here is the full one (the README table is a shorter
summary); the handlers are in `application(_:open:)` in `App/AppDelegate.swift`.

- `open "snapper://rect?x=&y=&w=&h="` captures a rectangle with no picker. Coordinates are points from
  the top-left of the primary display. Add `&own=1` to include Snapper's own windows, which is how to
  photograph the editor, Settings, About, thumbnails and pins. Only the presence of `own` counts, so
  `own=0` includes them too: leave it out to exclude them.
- `snapper://selftest?kind=…` drives the picker and editor with synthetic events inside the app
  (`App/SelfTest.swift`): region, window, editor, texts, deselect, recolour, esctext, zoom, record,
  reopen, print.
- `printpdf?path=<image>&out=<pdf>` runs the real print job into a PDF with no panel and no printer:
  read the PDF to check page count, orientation and scaling. `selftest?kind=print` logs who would
  answer File > Print for the front window (the canvas in the editor, `HistoryWindowController` in
  history) and whether the editor shows its Print button. Neither touches the clipboard.
- `settings`, `history`, `about`, `closepins`, `scrollrect` then `scrolldone`, `textrect`, `pinrect`.
- `open?path=` opens a file in the editor. `thumbbuttons` shows the thumbnail's hover buttons so they
  can be photographed. `menushot?path=` opens the menu bar menu and saves a picture of it.
- `appearance?mode=light|dark` forces the look for this run only; any other value follows the system.
- `setshortcut?action=<capture|captureAlt|fullScreen|scrolling|text|pin>&key=<n>&mods=<n>`. `key` is the
  macOS virtual key code and `mods` the Carbon modifier sum (cmd 256, shift 512, option 2048,
  control 4096; so Shift-Option is 2560). Leave out `key` to clear that shortcut; `action=defaults`
  restores them all. The result is written to the log. This changes his real shortcuts: put back
  whatever you change.
- Scrolling capture is tested against a long local page served over `http://localhost` (a `file://`
  page does not reload reliably in Safari).

Test captures land in his real save folder, next to his own captures. That is `~/Pictures/Screenshots`
by default, or whatever folder is chosen in Settings; the log line gives the exact path.

- Find yours from the log (`grep ' rect: .*file=' ~/Library/Logs/Snapper.log`), never with
  `ls -t | head -1`, which once picked up and renamed one of his.
- Move your test captures to the Trash when done, especially any that show his screen.
- A test capture replaces whatever is on his clipboard. Avoid running them while he is mid-task.

## Things that went wrong once

- **Lazy image decoding.** A `CGImage` from `CGImageSource` re-reads the file later. Saving over that
  file doubled the marks on reopen. Anything kept after its file may change goes through
  `inMemoryCopy()` (`Editor/EditStore.swift`).
- **Shortcut swaps.** `RegisterEventHotKey` returns -9878 if the keys are still held by another
  action. `ShortcutStore.registerAll()` unregisters everything first; keep that order.
- **Own windows in captures.** Only Snapper windows above layer 0 (overlay, thumbnail, pins, toast)
  are excluded. Its normal windows are captured like any other app's.
- **Scroll stitching.** Cache the `SCContentFilter` (`RegionGrabber`), about 27 ms a frame; rebuilding
  it each frame loses fast scrolls. The stitcher restarts if its first frame never matches.
- **Text recognition** takes tens of seconds the first time after launch, so it is warmed up in the
  background at start.
- **Text marks** are drawn as solid labels. An outline or glow was unreadable on busy backgrounds.
- **Scrolling bar.** Done and Cancel are large, centred with Auto Layout, on an opaque bar. He asked
  for each of those.

## Not yet checked by a real hand

The print panel itself and paper from a real printer, Print… in the history right-click menu,
trackpad pinch zoom in the editor, hover buttons with a real mouse, dragging the thumbnail into
another app, recording a shortcut with real keys, the £ sign in grabbed text, scrolling a PDF.

## Design choices already made

- Shortcuts default to Shift-Option-C/F/S/T/P. Region capture has a second slot, which he has set to
  the § key on his Mac. Shortcuts are per user in Settings; do not hard-code his.
- After every capture: clipboard, a PNG in the save folder, and a thumbnail. No prompts.
- Edits are non-destructive: the flattened PNG is in the save folder, the original and the marks are
  in `~/Library/Application Support/Snapper/Edits`.
- History is just the save folder. No database, nothing to maintain.
- Left out on purpose: video, auto-scroll, delayed capture, cloud upload.
- A Windows version was considered on 17 Nov 2026 and parked: it is a full rewrite, needs a Windows
  machine to test on, and nobody has asked for it.
