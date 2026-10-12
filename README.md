# PSE

A macOS menu-bar screenshot tool: capture, mark up, copy.

- **Right ⌘ ⇧ P** freezes the screen and shows an icon bar: area · window · scrolling capture ·
  full web page · full screen. A pixel loupe shows position and colour; **C** copies the colour.
- The capture is on the clipboard at once and opens in an editor: arrow, rectangle, text, step
  numbers, highlighter, blur, crop, undo. ↩ copies and closes, ⌘S saves a PNG.
- **Scrolling capture** auto-scrolls a window and stitches it; side bars that don't scroll are cropped.
- **Full web page** renders the browser tab's URL at window, desktop (1440) or mobile (390) width.
- **History** keeps the last N captures (default 10); pinned ones are never removed.

English, Russian, Hebrew. macOS 14+.

## Build

```bash
./build.sh install     # builds, signs, installs to ~/Applications and launches
```

Permissions on first use: Accessibility (the hotkey), Screen Recording, Automation (reading the
browser tab's URL).

## Tests

```bash
.build/release/PSE --self-test                 # stitching, history, pasteboard
.build/release/PSE --render-test out.png       # editor rendering; also --loupe-test, --highlight-test
.build/release/PSE --web-test <url> out.png [width] [mobile]
```

Debug: `defaults write com.viafirst.pse debugScrollFrames -bool YES` saves scrolling-capture frames
to `~/Library/Application Support/PSE/Debug/`; replay them with `--replay <dir>`.
