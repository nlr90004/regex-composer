# Regex Composer for Linux

A Qt window around the page, in about 250 lines of Python. `docs/index.html` is
copied in, so the app is a build of the site rather than a browser pointed at
it: no network, and it does not change when the site is redeployed.

The design decisions are in [MACOS-APP.md](../MACOS-APP.md) and apply here
nearly unchanged — the loopback server especially, which exists for reasons
that have nothing to do with which platform you are on.

## Install

```bash
./linux/install.sh
```

Copies four files into `~/.local`: the script and the page into
`~/.local/share/regex-composer/`, an icon into the `hicolor` theme, a
`.desktop` entry, and a launcher into `~/.local/bin`. No root, nothing outside
`$HOME`, and `--uninstall` removes exactly what it wrote.

To run it straight from a checkout without installing anything, the script
falls back to `../docs/index.html`:

```bash
python3 linux/regex-composer.py
```

## Requirements

PySide6 with QtWebEngine. Prefer your distribution's package — the pip wheel
bundles its own copy of Qt and runs to a few hundred megabytes.

```
Debian/Ubuntu   sudo apt install python3-pyside6.qtwebenginewidgets
Fedora          sudo dnf install python3-pyside6
Arch            sudo pacman -S pyside6
```

PySide6 rather than PyQt6 deliberately: PySide6 is LGPL, PyQt6 is GPL or
commercial, and this repository is MIT. Using PyQt6 would mean this directory
could not be distributed under the repository's own licence.

## Why there is a web server inside a local app

The page keeps your work in `localStorage`, which needs a real origin. Loading
bundled HTML from `file://` does not give you one, and a custom URL scheme gets
an opaque origin where storage throws. So the app serves the one bundled file
over HTTP on `127.0.0.1` and points the web view at that.

An origin is scheme, host **and port**, so the port is fixed at **47823**. On
an ephemeral port the app would come up on a different origin every launch and
the page would be empty every time. If something else holds the port, the app
says so and falls back for that session only — nothing is lost, and the next
launch goes back to 47823 and finds everything where it was.

The listener binds the loopback address specifically, so it is not reachable
from anywhere but the machine it runs on. It answers `GET` and `HEAD` for `/`
and `/index.html` and 404s the rest.

## Settings and stored work

Window geometry and the optional port override live in QSettings
(`~/.config/wtf.nlr/regex-composer.conf`); the patterns, flags, test text and
theme live in QtWebEngine's storage.

```bash
# move the app to a different port deliberately
printf '[General]\nLoopbackPort=47900\n' >> ~/.config/wtf.nlr/regex-composer.conf

# start over
rm -f  ~/.config/wtf.nlr/regex-composer.conf
rm -rf ~/.local/share/wtf.nlr/regex-composer
```

Nothing writes `LoopbackPort` but you. Whatever you set becomes the new origin,
so the page starts empty until you set it back.

## What has and has not been tested

Written and exercised on macOS, where PySide6 runs the same code. Verified
there: the server binds 47823 and serves bytes identical to `docs/index.html`,
404s everything else, and falls back correctly when the port is taken; the
profile is persistent rather than off-the-record; a value written to
`localStorage` in one process is read back by the next, and the page's own
`regex-composer-state` is saved and restored; `window.isSecureContext` is true,
so the copy buttons work; and window geometry survives a close and reopen.

**Since run on Linux** — Ubuntu under Wayland, 2026-08-11. It launches, the
window is themed by the desktop, and after `install.sh` the compositor resolves
the icon from the entry. That closes two of the three questions below.

Worth knowing if the icon looks generic: running the script straight from a
checkout gives you no `.desktop` file to match against, so Wayland falls back to
a generic gear no matter what `setWindowIcon` was given. Installing is what
fixes it, not anything in the script.

- ~~**Dark mode.**~~ Two separate bugs, both now fixed. Worked out on
  Ubuntu/Wayland, 2026-08-11.

  **QtWebEngine resolves `prefers-color-scheme` when the page loads and never
  re-evaluates it.** The load-time value is correct, and relaunching picks up a
  new one, but changing the desktop's scheme while the window is open reaches
  the Qt menu bar and the Chromium scrollbars and never the page. On Auto the
  content simply keeps whatever the desktop was set to at launch. Fixed by
  reloading the view on `QStyleHints.colorSchemeChanged` (Qt 6.5+); the page
  persists to `localStorage` continuously, so the reload costs nothing.

  Verified after the fix: with the app open on Auto and showing dark, switching
  the desktop to light rethemes the window immediately. That was the failing
  case. Only that direction was watched — the signal driving it is the same one
  either way.

  **The page did not narrow `color-scheme` for an explicit choice.** `:root`
  declared `light dark`, which is right for Auto but left browser-drawn widgets
  following the system when you had picked Light or Dark yourself — dark
  scrollbars on a light page. Fixed in `regex-builder.html`, and it affected
  every browser, not only this app.

  A warning for anyone debugging this again: Ubuntu's Appearance panel writes
  only `'default'` and `'prefer-dark'`. Setting `color-scheme` to
  `'prefer-light'` by hand leaves the desktop in a state its own UI does not
  produce — neither option highlights — and the results are not representative.
  Half an hour was spent chasing conclusions drawn in that state. Use the panel.

- ~~**Wayland.**~~ Confirmed. `setDesktopFileName` gives the window an app_id
  matching `wtf.nlr.regex-composer.desktop`, and that is what the compositor
  matches on. `StartupWMClass` in the entry is for X11 and went unused here.
- ~~**Sandboxing.**~~ Not an issue on a stock Ubuntu desktop — the app ran with
  no sandbox complaint and no environment variables. Left here because the
  failure is specific to container and hardened-kernel setups rather than to
  the distribution: QtWebEngine's zygote sandbox announces it with a message
  about `SUID sandbox`, and the usual escape is `QTWEBENGINE_DISABLE_SANDBOX=1`,
  which is worth understanding before you reach for it.
