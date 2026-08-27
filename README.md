# Spaces

Menu bar app that names macOS desktop Spaces and shows the name of the Space on the display that currently has focus.

## Features

- The menu bar title is the custom name of the focused display's current Space (or `Desktop N` until you name it).
- Click the menu bar item to rename Spaces and to jump to one.
- Multiple displays are grouped by screen. Each screen's current Space is marked; the keyboard-focused one is labeled **Focus**.
- Names are stored by Space UUID, so they survive Mission Control reordering and reboots.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`)

This uses private WindowServer APIs (`SkyLight`) to read and switch Spaces. Apple can change those APIs in a future macOS release.

## Build and run

```bash
./build.sh
open build/Spaces.app
```

The app is a menu bar extra (no Dock icon). Click **Spaces** in the menu bar, type a name next to a desktop, and use the arrow (or the circle) to switch to it. Enable **Launch at login** if you want it to start on its own.
