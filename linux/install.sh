#!/usr/bin/env bash
#
# Install Regex Composer into the current user's ~/.local tree.
#
#     ./linux/install.sh              install
#     ./linux/install.sh --uninstall  remove everything it wrote
#
# No root, no packaging format, nothing outside $HOME. The app is a Python
# script and a copy of the page, so "installing" is copying four files into the
# places a desktop expects to find them.
#
# Needs PySide6 with QtWebEngine. Prefer your distribution's package over pip,
# because the pip wheel bundles its own Qt and is a few hundred MB:
#
#     Debian/Ubuntu   sudo apt install python3-pyside6.qtwebenginewidgets
#     Fedora          sudo dnf install python3-pyside6
#     Arch            sudo pacman -S pyside6

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

APP_ID="wtf.nlr.regex-composer"
PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}"
LIBDIR="$PREFIX/regex-composer"
BINDIR="$HOME/.local/bin"
DESKTOP="$PREFIX/applications/$APP_ID.desktop"
ICON="$PREFIX/icons/hicolor/scalable/apps/$APP_ID.svg"

if [ "${1:-}" = "--uninstall" ]; then
	rm -rf "$LIBDIR"
	rm -f "$BINDIR/regex-composer" "$DESKTOP" "$ICON"
	echo "removed  $LIBDIR, $BINDIR/regex-composer, $DESKTOP, $ICON"
	echo "kept     settings and saved patterns — see linux/README.md to clear those"
	exit 0
fi

PAGE="$ROOT/docs/index.html"
if [ ! -f "$PAGE" ]; then
	echo "install.sh: $PAGE is missing — run 'python3 build.py' first" >&2
	exit 1
fi

# The app is a copy of the site, so it is only as current as docs/ is. A
# warning rather than an error: rebuilding docs/ is build.py's job.
if [ "$ROOT/regex-builder.html" -nt "$PAGE" ]; then
	echo "warning: regex-builder.html is newer than docs/index.html." >&2
	echo "         Run 'python3 build.py' first or you install the old page." >&2
fi

if ! python3 -c 'import PySide6.QtWebEngineWidgets' 2>/dev/null; then
	echo "warning: PySide6 with QtWebEngine is not importable by this python3." >&2
	echo "         Installing anyway; see the header of this script for packages." >&2
fi

echo "install  $LIBDIR"
mkdir -p "$LIBDIR" "$BINDIR" "$(dirname "$DESKTOP")" "$(dirname "$ICON")"
install -m 755 "$HERE/regex-composer.py" "$LIBDIR/regex-composer.py"
install -m 644 "$PAGE" "$LIBDIR/index.html"
install -m 644 "$HERE/regex-composer.svg" "$LIBDIR/regex-composer.svg"
install -m 644 "$HERE/regex-composer.svg" "$ICON"
# Exec= is rewritten to an absolute path rather than copied verbatim. The
# checked-in entry says `Exec=regex-composer`, which only resolves if
# ~/.local/bin is on the session's PATH — and on Ubuntu that is added by
# ~/.profile at login, so a directory this script just created is not on it
# until the next login. The launcher would sit there doing nothing.
sed "s|^Exec=.*|Exec=$BINDIR/regex-composer|" "$HERE/regex-composer.desktop" > "$DESKTOP"
chmod 644 "$DESKTOP"

# A launcher on PATH, so the .desktop entry's Exec= line resolves.
cat > "$BINDIR/regex-composer" <<EOF
#!/usr/bin/env bash
exec python3 "$LIBDIR/regex-composer.py" "\$@"
EOF
chmod 755 "$BINDIR/regex-composer"

command -v update-desktop-database >/dev/null && \
	update-desktop-database "$(dirname "$DESKTOP")" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && \
	gtk-update-icon-cache -f -t "$PREFIX/icons/hicolor" 2>/dev/null || true

echo
echo "installed"
echo "  launcher  $BINDIR/regex-composer"
echo "  entry     $DESKTOP"
case ":$PATH:" in
	*":$BINDIR:"*) ;;
	*) echo
	   echo "note: $BINDIR is not on your PATH. The desktop entry still works," >&2
	   echo "      but 'regex-composer' from a shell will not until it is." >&2 ;;
esac
