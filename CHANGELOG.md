# Changelog

All notable changes to WhiteShot are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-11-06

### Added
- Freeze-frame region capture with magnifier, size label and keyboard modifiers (square, from centre, move).
- Capture of the full screen, all displays, the last region and single windows (by clicking or from a list), with optional mouse pointer and countdown.
- After-capture destinations in any combination: editor, clipboard, file, Save As, print, Share sheet, email; or ask each time.
- Editor with rectangle, ellipse, line, arrow, freehand, text, speech bubble, step label, censor (pixelate, blur, black out), highlight (marker, spotlight, grayscale, magnify) and crop tools, undo/redo, z-order and copy/paste.
- Image operations: auto-crop, rotate, flip, resize, canvas size, drop shadow, border, torn edge, colour adjustment, grayscale, invert.
- Editable `.whiteshot` project files.
- Global shortcuts with two ready-made sets (WhiteShot's own and macOS-style) and a recorder for custom ones. Every action can have a second shortcut, and each set keeps the shortcuts recorded in it when you switch.
- Colour editor with presets, a screen eyedropper, hex and RGB fields, a colour wheel and opacity.
- Settings for output folder, file name pattern, image format and quality, launch at login. The default file name is `SCR_${YYYY}-${MM}-${DD}_${hh}-${mm}-${ss}-${ms}`; `${ms}` is the millisecond.
- Update check against GitHub Releases (notification only).
- “Reset All Settings…” in Settings › General.
- English and German localisation, following the Mac's language by default with a language selector in Settings › General; Liquid Glass styling on macOS 26.
- Recognize Text in the editor (toolbar button, Tools menu, ⇧⌘T): Vision text recognition with selectable, copyable text over the picture. Drawing tools and image changes are locked while it is on; text under censoring boxes is dropped. Saved PNG, JPEG, TIFF and HEIC files can carry the recognised text in their description (Settings › Output).
- The Recognize Text button has an island of its own in the editor toolbar.
- Censor from recognised text: censor the selection or every occurrence of it, with the style of the Censor tool; suggestions for email addresses, phone numbers, IBANs and card numbers (and optionally web and IP addresses) marked in orange, one click to censor them; the kinds to look for are a setting. QR codes and barcodes in the picture can be copied, and web and mail links opened.
- Grab Text shortcut (⌃⇧7 / ⇧⌘7): select a region and its text and QR code contents go to the clipboard. What it picks up is a setting.
- Pin screenshots on top of other windows, from the editor or as an after-capture destination; they appear where the capture was taken.
- Drag the edited picture out of the editor into other apps.
- Window capture can include the window's shadow and can put a white or black background behind the window instead of leaving it transparent.
- The tool palette adapts to small windows (compact buttons, then scrolling) and windows never open or shrink below what it needs.

### Fixed
- The menu bar (File, Edit, …) did not work in the editor after a region capture until Settings was opened: the capture overlay had already activated WhiteShot as a menu-bar-only app, so it never received the menu bar when the editor turned it into a regular app. The app now hands over to the Dock and takes the activation back at that moment.
- Zooming or fitting a picture that is smaller than the window could leave it off-centre instead of centred.
