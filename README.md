# Spaces

Menu bar app that names macOS desktop Spaces and shows the name of the Space on the display that currently has focus.

## Features

- The menu bar title is the custom name of the focused display's current Space (or `Desktop N` until you name it).
- Click the menu bar item to rename Spaces and to jump to one.
- Multiple displays are grouped by screen. Each screen's current Space is marked; the keyboard-focused one is labeled **Focus**.
- Names are stored by Space UUID, so they survive Mission Control reordering and reboots.
- Save a Space's apps and window layout (download icon), then restore it later (reload icon). If you close the desktop in Mission Control, it stays under **Closed spaces** so you can reopen it. Restore needs Accessibility permission so windows can be positioned and a new desktop can be created.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`)

This uses private WindowServer APIs (`SkyLight`) to read and switch Spaces. Apple can change those APIs in a future macOS release.

## Build and run

```bash
./build.sh
open build/Spaces.app
```

The app is a menu bar extra (no Dock icon). Click the Space name in the menu bar to rename desktops or switch to one. Use the download icon to save that Space's apps and window positions, and the reload icon to bring them back. If you close the desktop in Mission Control, it stays listed under **Closed spaces** — Reopen creates a new desktop and launches the saved apps. Restore will ask for Accessibility permission the first time. Enable **Launch at login** if you want the app to start on its own.
