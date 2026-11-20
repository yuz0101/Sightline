# Contributing to Sightline

Bug reports, code changes, and documentation fixes are welcome.

- For a window-placement bug, include the macOS version, the affected app, the display layout, and what happened when you tried to move the window. [Open an issue](https://github.com/yuz0101/Sightline/issues/new).
- For a code change, fork the repository and work on a branch in your fork. [Fork Sightline](https://github.com/yuz0101/Sightline/fork).

## Build and test

On macOS 14 or later with Xcode and its command-line tools, run these commands from the checkout.

```sh
./Scripts/build_app.sh
open build/Sightline.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The build script fetches Sparkle on the first run and signs the app locally. To try window placement, allow Accessibility access when prompted. The layout calculations and board planner live in `Sources/SightlineCore`. The menu bar and window controls live in `Sources/Sightline`. [Read the design notes](docs/DESIGN.md).

Open a pull request against `main` with a short description of what changed and how you tried it. A cropped screenshot helps with visual changes.
