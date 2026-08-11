#!/usr/bin/env python3
"""Regex Composer as a desktop app — a Qt window onto the bundled page.

The Linux counterpart to macos/. The page itself is unchanged: this is only a
container, and the reasoning behind it is in MACOS-APP.md, which applies here
almost word for word.

The one thing worth repeating, because it decides the whole shape of this file:
the page keeps your blocks, flags, test text and theme in localStorage, and
localStorage needs a legitimate origin. Loading bundled HTML from file:// does
not give you one — storage is unreliable and frequently does not survive a
restart — and a custom URL scheme gets an opaque origin where storage throws.
So the app serves the bundled file over HTTP on 127.0.0.1 and points a web view
at it. The origin is then an ordinary one, storage behaves exactly as it does
in a browser, and nothing leaves the machine.

That reasoning was worked out against WebKit on macOS. It holds for Chromium
here for the same reasons, which is why this file and macos/Sources/main.swift
have the same shape despite sharing no code.
"""

import http.server
import socketserver
import sys
import threading
from pathlib import Path

from PySide6.QtCore import QSettings, QUrl
from PySide6.QtGui import QDesktopServices, QIcon, QKeySequence
from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineProfile, QWebEngineSettings
from PySide6.QtWebEngineWidgets import QWebEngineView
from PySide6.QtWidgets import QApplication, QMainWindow, QMessageBox

APP_ID = "wtf.nlr.regex-composer"
ORGANISATION = "wtf.nlr"
APPLICATION = "regex-composer"

# An origin is scheme, host *and port*, so the port is part of the identity of
# the stored data. An ephemeral port would mean a new origin on every launch
# and an empty page every time — the exact failure the server exists to
# prevent. Override it deliberately with LoopbackPort in the settings file;
# nothing here ever writes it, because recording a port the app merely fell
# back to would turn one collision into a permanent move away from the origin
# holding all the saved work.
DEFAULT_PORT = 47823


def find_page() -> Path:
    """The bundled page: installed beside this script, or the repo's docs/."""
    here = Path(__file__).resolve().parent
    for candidate in (here / "index.html", here.parent / "docs" / "index.html"):
        if candidate.is_file():
            return candidate
    raise SystemExit(
        "regex-composer: no index.html beside this script and no ../docs/index.html.\n"
        "Run linux/install.sh, or run this from a checkout of the repository."
    )


class PageHandler(http.server.BaseHTTPRequestHandler):
    """Serves one file. Not a general web server.

    GET and HEAD for / and /index.html; everything else is a 404. `body` is
    replaced per-server with the bytes to serve.
    """

    body = b""
    protocol_version = "HTTP/1.1"
    server_version = "RegexComposer"
    sys_version = ""

    def _reply(self, status: int, content_type: str, payload: bytes, with_body: bool = True):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        # no-store keeps the app and the bundled file in step: a rebuilt page is
        # what you see on the next launch, not whatever the view cached.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if with_body:
            self.wfile.write(payload)

    def _serve(self, with_body: bool):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._reply(200, "text/html; charset=utf-8", self.body, with_body)
        else:
            self._reply(404, "text/plain; charset=utf-8", b"not found\n", with_body)

    def do_GET(self):
        self._serve(with_body=True)

    def do_HEAD(self):
        self._serve(with_body=False)

    def log_message(self, *args):
        """Quiet. A request log for a one-file local server is only noise."""


class LoopbackServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def start_server(body: bytes, preferred: int) -> tuple[LoopbackServer, int]:
    """Serve `body` on 127.0.0.1, preferring `preferred`.

    Binds to the loopback address specifically, so the listener is not reachable
    from anywhere but this machine. Falls back to an ephemeral port if the
    preferred one is taken; the caller is expected to say so.
    """
    handler = type("BoundPageHandler", (PageHandler,), {"body": body})
    try:
        server = LoopbackServer(("127.0.0.1", preferred), handler)
    except OSError:
        server = LoopbackServer(("127.0.0.1", 0), handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, port


class LoopbackPage(QWebEnginePage):
    """Keeps navigation on our own origin.

    Should a link ever be added to the page, it belongs in the user's browser
    rather than in this window.
    """

    def __init__(self, profile: QWebEngineProfile, parent, port: int):
        super().__init__(profile, parent)
        self._port = port

    def acceptNavigationRequest(self, url: QUrl, nav_type, is_main_frame: bool) -> bool:
        if url.host() == "127.0.0.1" and url.port() == self._port:
            return True
        if url.scheme() in ("http", "https"):
            QDesktopServices.openUrl(url)
        return False


class Window(QMainWindow):
    def __init__(self, profile: QWebEngineProfile, port: int, settings: QSettings):
        super().__init__()
        self._settings = settings

        self.view = QWebEngineView(self)
        # The page must be constructed with the profile — that is what ties the
        # view to persistent storage rather than to the default off-the-record
        # profile, where nothing would survive a restart.
        self.page = LoopbackPage(profile, self.view, port)
        self.view.setPage(self.page)
        self.setCentralWidget(self.view)

        self.setWindowTitle("Regex Composer")
        # Small enough to get well under the 940px breakpoint where the
        # expression panel undocks, so both layouts are reachable by dragging.
        self.setMinimumSize(420, 480)

        geometry = settings.value("geometry")
        if geometry is not None:
            self.restoreGeometry(geometry)
        else:
            self.resize(1200, 840)

        self._build_menu()
        self.view.setUrl(QUrl(f"http://127.0.0.1:{port}/"))

    def _build_menu(self):
        """Edit is not decoration: without it the clipboard shortcuts do not
        reach the web view, and the page is mostly text fields."""
        bar = self.menuBar()

        file_menu = bar.addMenu("&File")
        quit_action = file_menu.addAction("&Quit")
        quit_action.setShortcut(QKeySequence.StandardKey.Quit)
        quit_action.triggered.connect(self.close)

        edit_menu = bar.addMenu("&Edit")
        for label, action in (
            ("&Undo", QWebEnginePage.WebAction.Undo),
            ("&Redo", QWebEnginePage.WebAction.Redo),
            (None, None),
            ("Cu&t", QWebEnginePage.WebAction.Cut),
            ("&Copy", QWebEnginePage.WebAction.Copy),
            ("&Paste", QWebEnginePage.WebAction.Paste),
            ("Select &All", QWebEnginePage.WebAction.SelectAll),
        ):
            if label is None:
                edit_menu.addSeparator()
                continue
            web_action = self.page.action(action)
            web_action.setText(label)
            edit_menu.addAction(web_action)

        view_menu = bar.addMenu("&View")
        reload_action = self.page.action(QWebEnginePage.WebAction.Reload)
        reload_action.setShortcut(QKeySequence.StandardKey.Refresh)
        view_menu.addAction(reload_action)

    def closeEvent(self, event):
        """Remember size and position across launches."""
        self._settings.setValue("geometry", self.saveGeometry())
        super().closeEvent(event)


def main() -> int:
    page_file = find_page()
    body = page_file.read_bytes()

    app = QApplication(sys.argv)
    app.setApplicationName(APPLICATION)
    app.setOrganizationName(ORGANISATION)
    # Lets the compositor match the window to the .desktop entry, which is what
    # gives it the right icon under Wayland.
    app.setDesktopFileName(APP_ID)

    icon_file = Path(__file__).resolve().parent / "regex-composer.svg"
    if icon_file.is_file():
        app.setWindowIcon(QIcon(str(icon_file)))

    settings = QSettings(ORGANISATION, APPLICATION)
    try:
        preferred = int(settings.value("LoopbackPort", DEFAULT_PORT))
    except (TypeError, ValueError):
        preferred = DEFAULT_PORT

    server, port = start_server(body, preferred)

    # A named profile is the persistent one; the default profile is
    # off-the-record, and using it would quietly undo the point of all this.
    # Held on the app so it outlives every page that refers to it.
    app.profile = QWebEngineProfile(APPLICATION, app)
    app.profile.settings().setAttribute(
        QWebEngineSettings.WebAttribute.LocalStorageEnabled, True)

    window = Window(app.profile, port, settings)
    window.show()

    if port != preferred:
        # A different origin, so previously saved work is not visible. Silence
        # here would look like data loss. After the window is up, not before.
        QMessageBox.warning(
            window,
            f"Port {preferred} was busy",
            f"The page is being served on port {port} instead.\n\n"
            f"Because the port is part of the origin, anything saved previously "
            f"will not appear this time, and anything saved now will not appear "
            f"next time.\n\nNothing is lost. The next launch tries port "
            f"{preferred} again.",
        )

    try:
        return app.exec()
    finally:
        server.shutdown()


if __name__ == "__main__":
    sys.exit(main())
