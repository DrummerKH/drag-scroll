# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

DragScroll is a small macOS menu-bar utility that turns mouse movement into
scrolling while an activation gesture is held (a mouse button, modifier keys,
and/or a single key). The entire app is one Objective-C file:
`DragScroll/main.m`. There are no third-party dependencies, no tests, and no
linter — it links only system frameworks.

## Build & run

This machine has **Command Line Tools only (no full Xcode)**, so `xcodebuild`
does not work. Use the clang script:

```
./build.sh                       # → build/DragScroll.app (universal, ad-hoc signed)
open build/DragScroll.app        # run it
kill $(pgrep -f "build/DragScroll.app/Contents/MacOS/DragScroll")   # stop it
```

`build.sh` compiles `main.m` with `-fobjc-arc -fmodules` (frameworks
auto-link via module imports), assembles the `.app` bundle, writes a concrete
`Info.plist` (the checked-in `DragScroll/Info.plist` uses `$(VAR)`
placeholders only Xcode expands), copies the icon into `Resources/`, and
ad-hoc signs.

`DragScroll.xcodeproj` is kept in sync (it references `main.m` and links the
icon) purely so an Xcode build works for **signed/notarized release builds** —
it is not needed for development here. When editing the project or bundle
metadata, change **both** `build.sh` and the Xcode-side `Info.plist` /
`project.pbxproj`, and keep `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
aligned with `VERSION` / `BUILD_NUM` in `build.sh`.

The app is an `LSUIElement` (agent) — no Dock icon; its only UI is the
menu-bar item.

### App icon

`DragScroll/AppIcon.icns` is generated, not hand-drawn. Regenerate with
`./tools/make_icon.sh`, which compiles `tools/make_icon.m` (renders a 1024px
PNG of the four-arrow glyph on a gradient squircle), builds an iconset with
`sips`, and packs it with `iconutil`. macOS aggressively caches icons; after
rebuilding into the same path you may need
`lsregister -f build/DragScroll.app && killall Finder` to see changes (a
freshly copied `.app` shows the icon immediately).

## Architecture

Two layers in one file, connected by a set of file-scope globals and the
preferences store.

### Event-tap engine (C)

`tapCallback` is a CoreGraphics `CGEventTap` handler. Activation is tracked by
three independent booleans — `BUTTON_ENABLED` (mouse-button toggle),
`KEY_ENABLED` (modifier-hold, used only when no activation key is set), and
`KEYDOWN_ENABLED` (the activation key, hold or toggle). When any is on,
`kCGEventMouseMoved` events are consumed and re-emitted as pixel-unit
scroll-wheel events while the cursor is warped back in place
(`CGWarpMouseCursorPosition`). Each axis delta is passed through
`accelScroll`, a power-curve acceleration (normalized at `SCROLL_REF`, steepness
the configurable `ACCEL` exponent where `1.0` is linear) that keeps `SPEED` as
an overall multiplier — small movements scroll gently (important for line-based
apps like terminals) while fast flicks scroll further. `ACCEL` comes from the
`acceleration` preference (a double), set via the popover slider.

Config lives entirely in globals (`BUTTON`, `KEYS`, `SPEED`, `KEYCODE`,
`KEY_TOGGLE`, …). `loadConfiguration()` reads them from preferences;
`installTap()` tears down and rebuilds the tap with an event mask derived from
those globals (so which events are watched changes with config). **Any
settings change calls `applyChanges` → `loadConfiguration()` + `installTap()`,
which is how live reconfiguration works and why activation state resets on
change.** The event mask deliberately omits `flagsChanged` when an activation
key is set, and adds `keyDown`/`keyUp` instead.

Key-swallowing detail: `SWALLOW_UP` tracks whether the activation key's
`keyDown` was consumed, so the matching `keyUp` (and auto-repeat) is also
swallowed and the key never types while used for scrolling — while still
letting the key type normally when the required modifiers aren't held.

### UI layer (AppKit, `AppDelegate`)

An `NSStatusItem` whose button toggles an `NSPopover` (transient) built by
`buildContentView`. The popover holds the live status line, all settings
controls, and Pause/Quit buttons — there is no separate settings window and no
`NSMenu`. Controls write straight to preferences and call `applyChanges`.
The activation-key recorder uses a local `NSEventMonitor` (not a first
responder) so it reliably captures any key, including Space/Return, and
swallows the event.

### Preferences

Stored via `CFPreferences` under the app domain `com.emreyolcu.DragScroll`, so
the `defaults write com.emreyolcu.DragScroll …` commands documented in the
README stay interchangeable with the UI. Keys: `button`, `keys` (array of
modifier name strings), `speed`, `keyCode`, `keyLabel`, `keyToggle`. Invalid
values fall back to defaults (`DEFAULT_*` macros). `button` is stored 1-based
(as the README documents) and converted to the 0-based `BUTTON_COMPARE` the
event carries.

### Accessibility gating

The tap requires Accessibility (AXIsProcessTrusted) access. On launch, if not
yet trusted, the app prompts and registers a distributed-notification observer
(`axChanged`) that installs the tap the moment access is granted — no restart
needed. The status line reflects the "waiting for access" state.

### Launch at login

`SMAppService.mainAppService` on macOS 13+, falling back to writing a per-user
LaunchAgent plist (`~/Library/LaunchAgents/com.emreyolcu.DragScroll.plist`) on
older systems. Both paths are behind `isLoginItemEnabled` /
`setLoginItemEnabled`.
