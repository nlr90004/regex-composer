# Notes toward a macOS app

Design decisions for wrapping this page as a native app, recorded before the
work starts so they do not have to be re-derived. Nothing here is built yet.

**Target:** an M4 Mac mini with Xcode. The app runs only on that machine.

## Why these choices

**Bundle the HTML rather than pointing at the live site.** A window onto
<https://regex.nlr.wtf/> is less code, but it needs the network and the app
would change under you whenever `docs/` is redeployed. Bundling `docs/index.html`
keeps the app and the site the same build without coupling them at runtime.

**arm64 only.** The app is not intended to leave the mini, so there is no reason
to produce a universal binary. If that ever changes, add `x86_64` to `ARCHS` —
an arm64-only build simply refuses to launch on an Intel Mac, with a message
that does not obviously say why.

**Sign to Run Locally.** Ad-hoc signing is enough for a machine-local app. The
Apple Developer Program and notarization only become necessary to hand the app
to someone else without Gatekeeper warnings.

## The one real trap: localStorage needs a real origin

The page saves your blocks, flags and test text to `localStorage`. That requires
a legitimate origin, and the obvious ways to load bundled HTML do not provide
one:

- **`file://` in a WKWebView** — storage is unreliable. It often appears to work
  within a session and then does not survive a restart, which reads as a bug in
  the page rather than in the container.
- **A custom `WKURLSchemeHandler`** (`myapp://…`) — looks like the elegant
  answer and is not. Custom schemes get an opaque origin, so storage throws.
  Worth naming because it is the first thing you would reach for.

Three ways that do work, in the order I would try them:

1. **Loopback HTTP server.** An `NWListener` bound to `127.0.0.1` on an
   ephemeral port, serving the single bundled file. Roughly 60 lines. Gives a
   normal `http://127.0.0.1:PORT` origin, so storage behaves exactly as it does
   in a browser, and the app stays fully offline. This is the recommended path.
2. **Load the live site.** Zero extra code and a real origin, at the cost of
   requiring the network.
3. **Replace `localStorage` with `UserDefaults`** bridged over a
   `WKScriptMessageHandler`. The most native option, the most work, and it makes
   the app and the web version diverge — the page would need a storage
   abstraction rather than direct `localStorage` calls.

## Sketch of the work

- `main.swift` — `NSApplication`, one window, a `WKWebView`, plus the loopback
  server described above
- `Info.plist` — bundle id, minimum system version, `NSHighResolutionCapable`
- App icon — a 1024px PNG through Xcode's asset catalog; the page's own favicon
  is an inline SVG (`/·/` in Rosé Pine gold and foam) and can be the basis
- Build either from a fresh Xcode macOS App project, or with plain `swiftc` and
  a script that assembles `Contents/MacOS`, `Contents/Resources` and the plist

Estimate: about an hour to a working app, most of it in the server and the
window plumbing rather than anything conceptually hard.

## Things to check on first run

- A pattern survives quitting and reopening the app — this is the whole point of
  the loopback server, and the failure mode is silent
- The window remembers its size, and the layout crosses the 940px breakpoint
  cleanly when resized, since that is where the expression panel docks
- The theme switch still follows the system, and its choice persists — it uses
  the same storage as everything else
