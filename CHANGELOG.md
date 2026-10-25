# Changelog

## 0.9.0 — 2026-10-25
- Editor: freehand pen (P), question mark (Q) and cross (X) — click for a default X, drag to cross out an area.

## 0.8.0 — 2026-10-14
- Scrolling capture is manual again: pick a window or area and scroll it yourself; auto-scroll stays optional (▶ on the panel).

## 0.7.0 — 2026-10-12
- Renamed PSE → Inkshot (bundle id com.viafirst.inkshot); history and settings move over on first launch; store listings in en/ru/he.

## 0.6.2 — 2026-10-12
- Fix the adaptive highlighter reading brightness upside down; README with icon and screenshots (--readme-shots).

## 0.6.1 — 2026-10-12
- App icon: a tilted screenshot card in viewfinder corners, highlighted and pointed at by an annotation arrow.

## 0.6.0 — 2026-10-12
- Pixel loupe next to the pointer (position and colour), eyedropper on C.
- Adaptive highlighter: multiply on light content, screen on dark content.
- Audit fixes (mac-app standard): lazy pasteboard (PNG/TIFF encoded only on paste), no private WebKit
  API, unused PDF renderer removed, `--self-test` runs every logic test, localized OK button.

## 0.5.0 — 2026-10-12
- Full web page capture: click a browser window, PSE renders the tab's URL in a hidden WebKit view
  at window / desktop 1440 / mobile 390 width; fixed elements once, consent banners hidden.
- Scrolling capture starts auto-scrolling right away; a click picks the window.

## 0.4.0 — 2026-10-12
- Scrolling capture with frame stitching, sticky footer handling and auto-crop to the main column.

## 0.3.0 — 2026-10-12
- Screenshot history (default 10, 5–100) with pinning; reopen and keep editing.

## 0.2.0 — 2026-10-12
- English base language with Russian and Hebrew; the build fails on a missing translation.

## 0.1.0 — 2026-10-12
- Menu-bar app: right ⌘⇧P, frozen-screen overlay (area / window / full screen), annotation editor
  (arrow, rectangle, text, step numbers, highlighter, blur, crop), copy to clipboard by default.
