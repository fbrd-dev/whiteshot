# Contributing to WhiteShot

Thanks for helping out. This file covers building, testing, the code layout and translations.

## Build and test

You need Xcode 26 or newer (the Liquid Glass styling is compiled against the macOS 26 SDK; the app itself still targets macOS 14) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate                      # creates WhiteShot.xcodeproj from project.yml
xcodebuild -project WhiteShot.xcodeproj -scheme WhiteShot -configuration Debug build
xcodebuild -project WhiteShot.xcodeproj -scheme WhiteShot test
```

The `.xcodeproj` is generated and not committed: edit `project.yml`, never the project file.

### Keep the Screen Recording permission between rebuilds

macOS ties the permission to the app's code signature, and an ad-hoc signature changes on every build, so you would be asked again after each rebuild. Avoid that by signing with your own Apple Development identity:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # git-ignored
# put your Team ID into DEVELOPMENT_TEAM
```

### Releases

`scripts/build_app.sh` builds `dist/WhiteShot.app` and a DMG. Without arguments it is ad-hoc signed. With `SIGNING_IDENTITY` (a "Developer ID Application" certificate) and `NOTARY_PROFILE` (a profile saved with `xcrun notarytool store-credentials`) it signs, notarizes and staples both the app and the DMG. The version of the app is its git tag (`v1.2.0` becomes 1.2.0): nothing else holds a version number, every build stamps it in through `scripts/stamp_version.sh`, a build without a tag is 0.0.0, and a signed build refuses to run unless HEAD is exactly at a version tag. So commit, tag, then build. The update check compares the running version with the tag of the latest GitHub release.

## Code layout

| Folder | What lives there |
| --- | --- |
| `WhiteShot/App` | Entry point, menu bar item, main menu, update check, debug harness (Debug builds only) |
| `WhiteShot/Capture` | ScreenCaptureKit grabbing, the freeze-frame overlay, capture coordination |
| `WhiteShot/Output` | Where a capture goes: file name patterns, encoding, clipboard, print, share, notifications |
| `WhiteShot/Editor` | The editor: model with undo, canvas, annotations and renderer, SwiftUI chrome, image operations, effect dialogs |
| `WhiteShot/Settings` | Preferences, global shortcuts, the Settings window |
| `WhiteShotTests` | Unit and interaction tests |

Two design rules worth knowing:

- **One renderer.** `Renderer.render(base:annotations:)` produces both what the canvas shows and what gets exported, so the two cannot disagree. Annotations are plain value types, which keeps undo (array snapshots), copy/paste and the project file trivial.
- **Censoring filters read the pixels *below* them.** A pixelate or blur annotation is applied to the picture as rendered up to that point in the z-order, never to the original image alone.

## Testing without touching your real screen

The tests drive the real canvas and overlay with synthetic mouse and key events and never capture the screen. Debug builds additionally contain `DebugHarness.swift`, which can render the editor, the overlay and Settings over made-up content, and verify the real capture path against a window WhiteShot draws itself:

```sh
WhiteShot.app/Contents/MacOS/WhiteShot --debug-editor-shot out.png [--dark] [--tool crop] [--select text]
WhiteShot.app/Contents/MacOS/WhiteShot --debug-capture-selftest    # needs Screen Recording permission
```

Please do not commit screenshots of real desktops or customer data.

## Translations

UI strings live in `WhiteShot/Resources/Localizable.xcstrings`; English is the source language. Write user-visible strings as `String(localized: "…")` in AppKit code and as literals in SwiftUI. To add or change a string:

1. Build, then sync new keys into the catalog:
   `xcrun xcstringstool sync WhiteShot/Resources/Localizable.xcstrings --stringsdata <DerivedData>/…/WhiteShot.build/Objects-normal/arm64/*.stringsdata`
2. Add the German text to `scripts/l10n_de.py` and run `python3 scripts/l10n_de.py`. It reports anything untranslated.

To add another language, add its translations the same way (or edit the catalog in Xcode) and list the language in `CFBundleLocalizations` in `project.yml`.

## Pull requests

Keep changes focused, add or update tests for behaviour you change, and make sure `xcodebuild test` passes. By contributing you agree that your work is licensed under the GPL-3.0, like the rest of the project.
