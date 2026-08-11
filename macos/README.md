# Regex Composer for macOS

A native window around the page. `docs/index.html` is copied into the app, so
the app is a build of the site rather than a browser pointed at it: no network,
and it does not change when the site is redeployed.

The design decisions behind this — why bundle rather than load the live site,
why arm64 only, why ad-hoc signing, and why there is an HTTP server inside a
local app — are in [MACOS-APP.md](../MACOS-APP.md).

## Build

```bash
./macos/build.sh
```

Needs Xcode for the macOS SDK; there is no Xcode project. The script compiles
one Swift file, lays out the bundle, draws the icon, and signs ad-hoc. Output
is `macos/build/Regex Composer.app`, which is gitignored — the app is built,
not committed. `./macos/build.sh --run` launches it afterwards.

If you changed `regex-builder.html`, run `python3 build.py` first: the app
bundles `docs/index.html`, and the script warns rather than rebuilding it for
you.

```
Sources/main.swift   the app: window, web view, loopback server
Info.plist           bundle id, minimum version, NSHighResolutionCapable
make-icon.swift      draws the icon from the page's favicon, writes an .iconset
build.sh             compiles and assembles the bundle
```

## The port is part of the origin

The page keeps your work in `localStorage`, which needs a real origin, which is
why the app serves the bundled file from `http://127.0.0.1` instead of loading
it from `file://` — see MACOS-APP.md for why the obvious alternatives do not
work.

What that note does not say, and what matters in practice: an origin is scheme,
host **and port**. On an ephemeral port the app would come up on a different
origin every launch, `localStorage` would be empty every time, and the page
would look like it had lost your patterns. So the port is fixed, at **47823**.

If something else already holds it, the app says so and falls back to an
ephemeral port for that session only — nothing is lost, and the next launch
goes back to 47823 and finds everything where it was.

To move the app to a different port deliberately:

```bash
defaults write wtf.nlr.regex-composer LoopbackPort -int 47900
```

That is the only thing that changes the port, and the app never writes it
itself. Whatever you set becomes the new origin, so the page starts empty until
you set it back.

The listener is bound to the loopback interface, so it is not reachable from
anywhere but this machine. It answers `GET` and `HEAD` for `/` and
`/index.html` and 404s everything else.

## Resetting

Window size and position live in `UserDefaults`; the patterns, flags, test text
and theme live in WebKit's storage.

```bash
defaults delete wtf.nlr.regex-composer          # window frame, port override
rm -rf ~/Library/WebKit/wtf.nlr.regex-composer  # everything the page saved
```

## Intel Macs

The default build is arm64 only, per MACOS-APP.md. For a universal binary that
also runs on Intel:

```bash
ARCHS="arm64 x86_64" ./macos/build.sh
```

Each architecture is compiled separately and the slices joined with `lipo`.
That matters: `swiftc` accepts one `-target` per invocation and silently
honours the last one, so passing both to a single call produces an Intel-only
app that will not launch on Apple Silicon — the same unexplained refusal, aimed
the other way. Make it permanent by changing the `ARCHS` default in `build.sh`.

The x86_64 slice has been run here under Rosetta: it launches, binds the
loopback port, loads the page and writes storage. That is translation on Apple
Silicon rather than a real Intel Mac, so it exercises the code but not the
hardware.

## Giving it to someone else

Not as built. The signature is ad-hoc, which is enough for the machine it was
built on and nothing more — another Mac will quarantine it and show a Gatekeeper
warning. That needs the Apple Developer Program and notarization, not a build
flag. A universal binary only settles the architecture question.
