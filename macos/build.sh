#!/usr/bin/env bash
#
# Assemble Regex Composer.app from Sources/main.swift and docs/index.html.
#
#     ./macos/build.sh            build, then tell you where it is
#     ./macos/build.sh --run      build and launch it
#
# No Xcode project: this compiles one Swift file and lays out the bundle by
# hand. Xcode itself is still required, because swiftc needs the macOS SDK.
#
# Choices this script encodes, from MACOS-APP.md:
#   arm64 only          the app is for one Mac mini; a universal binary would
#                       be build time spent on nothing. Adding x86_64 to ARCHS
#                       below is the whole change if that stops being true.
#   ad-hoc signature    "Sign to Run Locally". Enough for a machine-local app;
#                       the Developer Program and notarization only matter for
#                       handing the app to someone else.
#   bundled page        docs/index.html is copied in, so the app is a build of
#                       the site rather than a window onto the live one.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# arm64 only, per MACOS-APP.md: the app is for one Apple Silicon Mac. For a
# universal build that also runs on Intel, override it for one build —
#
#     ARCHS="arm64 x86_64" ./macos/build.sh
#
# — or change the default here. Each architecture is compiled separately and
# the slices are joined with lipo; swiftc takes one -target per invocation and
# silently honours the last one, so building both in a single call would
# quietly produce an Intel-only app.
ARCHS="${ARCHS:-arm64}"
DEPLOYMENT_TARGET="13.0"
APP_NAME="Regex Composer"
EXECUTABLE="RegexComposer"

BUILD_DIR="$HERE/build"
APP="$BUILD_DIR/$APP_NAME.app"
PAGE="$ROOT/docs/index.html"

if [ ! -f "$PAGE" ]; then
	echo "build.sh: $PAGE is missing — run 'python3 build.py' first" >&2
	exit 1
fi

# The app is a build of the site, so it is only as current as docs/ is. A
# warning rather than an error: rebuilding docs/ is build.py's job, and running
# it from here would be a surprising side effect of building the app.
if [ "$ROOT/regex-builder.html" -nt "$PAGE" ]; then
	echo "warning: regex-builder.html is newer than docs/index.html." >&2
	echo "         Run 'python3 build.py' first or the app bundles the old page." >&2
fi

if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
	echo "build.sh: no macOS SDK. Install Xcode and run 'sudo xcode-select --switch /Applications/Xcode.app'" >&2
	exit 1
fi

echo "clean   $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BINARY="$APP/Contents/MacOS/$EXECUTABLE"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SLICES=()
for arch in $ARCHS; do
	echo "compile main.swift ($arch, macOS $DEPLOYMENT_TARGET)"
	slice="$BUILD_DIR/$EXECUTABLE-$arch"
	swiftc -O \
		-target "$arch-apple-macos$DEPLOYMENT_TARGET" \
		-sdk "$SDK" \
		-framework AppKit -framework WebKit -framework Network \
		-o "$slice" \
		"$HERE/Sources/main.swift"
	SLICES+=("$slice")
done

if [ "${#SLICES[@]}" -gt 1 ]; then
	echo "lipo    $(echo "$ARCHS" | tr ' ' '+')"
	lipo -create "${SLICES[@]}" -output "$BINARY"
else
	mv "${SLICES[0]}" "$BINARY"
fi

echo "icon    AppIcon.icns"
ICON_WORK="$BUILD_DIR/icon"
mkdir -p "$ICON_WORK"
swift "$HERE/make-icon.swift" "$ICON_WORK"
iconutil --convert icns "$ICON_WORK/AppIcon.iconset" \
	--output "$APP/Contents/Resources/AppIcon.icns"

echo "bundle  index.html, Info.plist"
cp "$PAGE" "$APP/Contents/Resources/index.html"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "sign    ad-hoc"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo
echo "built   $APP"

if [ "${1:-}" = "--run" ]; then
	echo "open    $APP"
	open "$APP"
else
	echo "run it  open '$APP'"
fi
