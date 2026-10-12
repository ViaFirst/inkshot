# PSE — notes for Claude

- Built to the **mac-app** standard (`~/.claude/skills/mac-app`); `/mac-app PSE audit` before larger
  changes. Bump with `~/.claude/skills/mac-app/scripts/bump-version.sh . patch|minor "note"`.
- **Distribution: personal** (owner only). Not App Store-compatible by design: global CGEventTap
  hotkey (right ⌘ needs device flags), AppleScript to browsers, posted scroll events.
- **Accessibility is requested at launch on purpose**: the hotkey is the app's main entry point.
- Git: public, github.com/ViaFirst/pse (MIT). Mac apps live under the ViaFirst account, not WPFF-Dev;
  `gh auth switch -u ViaFirst` before repo operations. Commits use the ViaFirst noreply email (repo config).
- Build/install: `./build.sh install`. Tests: `--self-test` (must print ALL PASS), render tests write PNGs
  — look at them before claiming a visual change works.
- Full web page capture: see the vault note "WKWebView Full Page Capture" for the gotchas.
