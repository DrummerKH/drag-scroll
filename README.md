# DragScroll

[![Downloads](https://img.shields.io/github/downloads/DrummerKH/drag-scroll/total.svg)](https://github.com/DrummerKH/drag-scroll/releases)

This small utility provides a drag-to-scroll mechanism for macOS.
It runs in the background and does not interfere until you activate
drag scrolling, which you can do in any of three ways:
by pressing or holding a mouse button (button 5 by default),
by holding a set of modifier keys (Shift by default),
or by holding an optional activation key.
In this mode, the mouse cursor is locked in place
and mouse movement is interpreted as scrolling.
Activating again (or releasing the keys) deactivates drag scrolling mode.

This application is especially useful with a trackball:
you can activate drag scrolling and roll the ball
to quickly scroll through a large website or a document.
It also works with the trackpad, for instance allowing you
to drag scroll with a single finger while holding down the modifier keys.

Everything is configured from a menu-bar popover — see [Settings](#settings).

> [!NOTE]
> The activation methods operate independently of each other:
> if you first press the mouse button to activate
> and then press and release the modifier keys,
> drag scrolling mode stays active until you press the mouse button again.

### Supported versions

This build requires **macOS 10.13 (High Sierra) or later** and ships as a
universal binary (Apple silicon and Intel). It has been built and tested on
macOS 15 (Sequoia).

Two features degrade gracefully on older systems: the menu-bar glyph falls
back to a text symbol before macOS 11, and *Launch at login* uses a per-user
launch agent instead of the system login-item service before macOS 13.

### Installation

You may download the latest binary from the
[releases page](https://github.com/DrummerKH/drag-scroll/releases/latest).
DragScroll requires access to accessibility features.
Upon startup, if it does not have access, it will prompt you and wait.
You do not need to restart the application
after you grant it access to accessibility features.

> [!CAUTION]
> You should not revoke accessibility access
> for DragScroll while it is running.
> Otherwise, your mouse might become unresponsive, requiring a reboot to fix.

DragScroll shows an icon in the menu bar. Click it to open a popover
containing all of the settings, along with buttons to temporarily
**Pause**/**Resume** scrolling or **Quit** the application. The popover also
shows the current status (Active, Paused, or waiting for Accessibility access).

To run the application automatically when you log in, open the popover and
turn on **Launch DragScroll at login** (this uses the system login-item
service on macOS 13.0 and later, and a per-user launch agent on older
versions). You can also add it manually under
`System Settings > General > Login Items`.

### Settings

Click the menu bar icon to configure the application from the popover.
Changes take effect immediately — no restart required.

- **Scrolling speed:** overall multiplier for scrolling (default 3); negative
  values invert the direction.
- **Acceleration:** how non-linear the scrolling is (default 1.7). At `1.0` it
  is linear (off); higher values make slow, precise movements gentler (nicer in
  line-based apps like terminals) while fast flicks cover more distance.
- **Mouse button:** the button that activates drag scrolling (3–32), or *Off*.
- **Button behavior:** whether the mouse button works as **toggle** (press once
  to start, press again to stop — the default) or **hold** (scroll only while
  the button is held). Holding is handy when the button is a real mouse button
  that a trackball's auto-mouse layer should keep alive.
- **Modifier keys:** the modifiers held to activate drag scrolling
  (Caps Lock, Shift, Control, Option, Command).
- **Activation key:** optionally, any single key pressed together with the
  modifiers above to activate drag scrolling. While the key is used for drag
  scrolling it is intercepted, so it will not type. Use **Clear** to remove it.
- **Key behavior:** whether the activation key works as **hold** (scroll while
  held, stop on release) or **toggle** (press once to start, press again to
  stop, like the mouse button). Applies only to the activation key; modifier
  keys always work as hold.

Settings are saved automatically and persist across restarts.

### Uninstallation

To uninstall DragScroll, quit the application, move it to trash,
and remove it from the lists for accessibility access and login items.
You can remove any stored preferences by running the following:

```
defaults delete com.emreyolcu.DragScroll
```

### Potential problems

Recent versions of macOS have made it difficult to run unsigned binaries.

If you experience issues launching the application, try the following:

- Remove the quarantine attribute by running the command
  `xattr -dr com.apple.quarantine /path/to/DragScroll.app`,
  where the path points to the application bundle.
- Disable Gatekeeper by running the command
  `spctl --add /path/to/DragScroll.app`,
  where the path points to the application bundle.

If on startup the application asks for accessibility permissions
even though you have previously granted it access, try the following:

1. On macOS 13.0 and later, go to `System Settings > Privacy & Security > Accessibility`;
   otherwise, go to `System Preferences > Security & Privacy > Privacy > Accessibility`.
2. Remove `DragScroll` from the list and add it again.

### History

#### v1.4.4 (2026-07-21)

- Add a **hold/toggle** option for mouse-button activation (previously the
  button always toggled). In hold mode, drag scrolling is active only while the
  button is held — useful when the button is a real mouse button that a
  trackball's QMK auto-mouse layer should keep alive.

#### v1.4.3 (2026-07-20)

- Service the event tap on a dedicated high-priority thread so heavy main-thread
  work (popover, status-item updates) can no longer delay activation.

#### v1.4.2 (2026-07-20)

- Make scroll acceleration configurable from the popover (1.0 = linear).

#### v1.4.1 (2026-07-20)

- Scroll with an acceleration curve so slow movements stay gentle (better in
  terminals and other line-based apps) while fast flicks scroll further.

#### v1.4.0 (2026-07-20)

- Add a menu bar icon with a popover holding all settings plus Pause/Resume
  and Quit, showing the current status.
- Configure speed, mouse button, modifier keys, and launch-at-login from the
  popover, with changes applied live.
- Add an application icon.
- Allow holding any single key (in addition to modifiers) to activate
  drag scrolling.
- Allow the activation key to toggle drag scrolling instead of holding it.

#### v1.3.1 (2024-06-05)

- **Fix:** Release event tap and run loop source after adding source.

#### v1.3.0 (2024-06-02)

- Change "scale" to "speed".
- Remove accessibility observer once granted access.

#### v1.2.0 (2024-05-31)

- Observe changes in accessibility access continuously.

#### v1.1.0 (2024-05-29)

- Allow using modifier keys in addition to mouse buttons.

#### v1.0.0 (2024-05-27)

- Handle errors and check for accessibility access.
- Allow configuring the toggle button and scrolling speed.
- Rename project from "PixelScroll" to "DragScroll".

#### v0.1.0 (2018-05-26)

- Initial release.
