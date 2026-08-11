// Regex Composer for macOS — a window onto the bundled copy of docs/index.html.
//
// The page itself is unchanged: this file is only a container. Everything
// interesting here is in service of one requirement, which is that the page
// keeps your blocks, flags, test text and theme choice in localStorage, and
// localStorage needs a legitimate origin.
//
//   file:// in a WKWebView    storage often works for a session and then does
//                             not survive a restart
//   a custom URL scheme       WKURLSchemeHandler gets an opaque origin, so
//                             storage throws
//
// So the app serves the bundled file from an HTTP listener on 127.0.0.1 and
// points the web view at it. The origin is then an ordinary one, storage
// behaves exactly as it does in a browser, and nothing ever leaves the machine.

import AppKit
import Network
import WebKit

// MARK: - Loopback HTTP server

/// Serves one file, over TCP, to 127.0.0.1 only.
///
/// Deliberately not a general web server: it holds the page in memory, answers
/// GET and HEAD for `/` and `/index.html`, and 404s everything else. Each
/// connection is answered once and closed.
final class LoopbackServer {
    /// An origin is scheme + host + *port*, so the port is part of the identity
    /// of the stored data. A fresh ephemeral port on every launch would mean a
    /// fresh origin on every launch, and every saved pattern would silently
    /// disappear — the exact failure this server exists to prevent. So we ask
    /// for the same port each time and only fall back to an ephemeral one if
    /// something else has taken it.
    static let defaultPort: UInt16 = 47823

    private let body: Data
    private let queue = DispatchQueue(label: "wtf.nlr.regex-composer.server")
    private var listener: NWListener?

    /// The port actually bound. Valid once `start` has reported success.
    private(set) var port: UInt16 = 0

    init(body: Data) {
        self.body = body
    }

    /// Binds and starts listening. `completion` runs on the main queue exactly
    /// once, reporting the port that was bound or the error that stopped us.
    func start(preferredPort: UInt16, completion: @escaping (Result<UInt16, Error>) -> Void) {
        var finished = false
        let report: (Result<UInt16, Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { completion(result) }
        }
        bind(to: preferredPort, allowingFallback: true, report: report)
    }

    private func bind(to rawPort: UInt16, allowingFallback: Bool,
                      report: @escaping (Result<UInt16, Error>) -> Void) {
        let requested = NWEndpoint.Port(rawValue: rawPort) ?? .any
        do {
            let parameters = NWParameters.tcp
            // Bind to the loopback interface specifically. Without this the
            // listener would accept from anywhere the machine is reachable.
            //
            // The port goes here too, rather than through NWListener's `on:`
            // argument. requiredLocalEndpoint fixes the whole local address,
            // and supplying `on:` as well states the port twice — which the
            // Network framework rejects outright with EINVAL rather than
            // reconciling, even when the two agree.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                                   port: requested)
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener?.port?.rawValue ?? rawPort
                    report(.success(self.port))
                case .failed(let error), .waiting(let error):
                    // In use, most likely. Retry once on an ephemeral port —
                    // the app still works, it just cannot see data stored
                    // under the old origin.
                    self.listener?.cancel()
                    self.listener = nil
                    if allowingFallback {
                        self.bind(to: 0, allowingFallback: false, report: report)
                    } else {
                        report(.failure(error))
                    }
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            if allowingFallback {
                bind(to: 0, allowingFallback: false, report: report)
            } else {
                report(.failure(error))
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// Reads until the end of the request head, then answers. A request body,
    /// if any, is ignored — nothing here accepts one.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, isComplete, error in
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if error != nil {
                connection.cancel()
                return
            }
            if let head = Self.requestLine(in: buffer) {
                self.respond(to: head, on: connection)
                return
            }
            // No complete head yet. Give up rather than buffer without bound.
            if isComplete || buffer.count > 16 * 1024 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    /// The request line, if the head is complete: ("GET", "/index.html").
    private static func requestLine(in buffer: Data) -> (method: String, target: String)? {
        guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil,
              let text = String(data: buffer, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let fields = firstLine.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return (String(fields[0]), String(fields[1]))
    }

    private func respond(to head: (method: String, target: String), on connection: NWConnection) {
        // Everything before the query. Not split(separator:"?")[0]: split drops
        // empty pieces, so a target of "?" yields an empty array and the
        // subscript traps — a malformed request from any local process would
        // take the app down with it.
        let path = head.target.prefix { $0 != "?" }
        let wantsPage = (path == "/" || path == "/index.html")
        let allowedMethod = (head.method == "GET" || head.method == "HEAD")

        let status: String
        let contentType: String
        let payload: Data
        if wantsPage && allowedMethod {
            status = "200 OK"
            contentType = "text/html; charset=utf-8"
            payload = body
        } else if allowedMethod {
            status = "404 Not Found"
            contentType = "text/plain; charset=utf-8"
            payload = Data("not found\n".utf8)
        } else {
            status = "405 Method Not Allowed"
            contentType = "text/plain; charset=utf-8"
            payload = Data("method not allowed\n".utf8)
        }

        // no-store keeps the app and the bundled file in step: a rebuilt page
        // is what you see on next launch, not whatever the web view cached.
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(payload.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        if head.method != "HEAD" { response.append(payload) }

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    /// Optional override for the port, for moving the app deliberately:
    ///
    ///     defaults write wtf.nlr.regex-composer LoopbackPort -int 47900
    ///
    /// Nothing writes it. A port the app fell back to is emphatically not worth
    /// remembering — recording it would turn one busy afternoon into a
    /// permanent move away from the origin holding all the saved work.
    private static let portDefaultsKey = "LoopbackPort"

    private var window: NSWindow!
    private var webView: WKWebView!
    private var server: LoopbackServer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()

        guard let url = Bundle.main.url(forResource: "index", withExtension: "html"),
              let html = try? Data(contentsOf: url) else {
            fail("The bundled page is missing.",
                 "index.html was not found in the app's Resources. Rebuild with macos/build.sh.")
            return
        }

        let override = UserDefaults.standard.object(forKey: Self.portDefaultsKey) as? Int
        let preferred = override.flatMap(UInt16.init(exactly:)) ?? LoopbackServer.defaultPort

        server = LoopbackServer(body: html)
        server.start(preferredPort: preferred) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let port):
                self.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
                if port != preferred {
                    // A different origin, so previously saved work is not
                    // visible. Silence here would look like data loss. After
                    // the load, not before: the alert is modal, and there is
                    // no reason to hold the page behind it.
                    DispatchQueue.main.async {
                        self.warnAboutPortChange(from: preferred, to: port)
                    }
                }
            case .failure(let error):
                self.fail("Could not start the local server.",
                          "The page is served over http://127.0.0.1 so that it has a real "
                          + "origin for storage.\n\n\(error.localizedDescription)")
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: Window

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        // The default data store is the persistent one; being explicit because
        // swapping it for .nonPersistent() would quietly undo the whole point
        // of the loopback server.
        configuration.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Regex Composer"
        // The page's own theme-color values, so the moment before the page
        // paints is the page's background rather than a white flash. Following
        // the system appearance the same way the page does.
        window.backgroundColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 0x23 / 255, green: 0x21 / 255, blue: 0x36 / 255, alpha: 1)
                : NSColor(srgbRed: 0xfa / 255, green: 0xf4 / 255, blue: 0xed / 255, alpha: 1)
        }
        // Small enough to get well under the 940px breakpoint where the
        // expression panel undocks, so both layouts are reachable by dragging.
        window.contentMinSize = NSSize(width: 420, height: 480)
        window.contentView = webView
        window.center()
        // Remember size and position across launches.
        window.setFrameAutosaveName("RegexComposerWindow")
        window.setFrameUsingName("RegexComposerWindow")
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Our own page, loaded normally. Anything else — should a link ever be
        // added to the page — belongs in the user's browser, not in here.
        if url.host == "127.0.0.1", url.port == Int(server?.port ?? 0) {
            decisionHandler(.allow)
        } else if url.scheme == "http" || url.scheme == "https" {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
        } else {
            decisionHandler(.cancel)
        }
    }

    /// Cancelling a navigation in `decidePolicyFor` — which is how an external
    /// link gets handed to the browser — comes back here as a failure with
    /// NSURLErrorCancelled. Treating that as a real failure would quit the app
    /// every time you followed a link out of it.
    private func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isCancellation(error) else { return }
        fail("The page failed to load.", error.localizedDescription)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard !isCancellation(error) else { return }
        fail("The page failed to load.", error.localizedDescription)
    }

    // MARK: Alerts

    private func warnAboutPortChange(from wanted: UInt16, to got: UInt16) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Port \(wanted) was busy."
        alert.informativeText = """
        The page is being served on port \(got) instead. Because the port is part \
        of the origin, anything saved previously will not appear this time, and \
        anything saved now will not appear next time.

        Nothing is lost. The next launch tries port \(wanted) again.
        """
        alert.runModal()
    }

    private func fail(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: Menu

    /// Built in code because there is no nib. Edit is not decoration: without
    /// it the standard clipboard shortcuts do not reach the web view, and the
    /// page is mostly text fields.
    private func buildMenu() {
        let appName = "Regex Composer"
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen",
                                          action: #selector(NSWindow.toggleFullScreen(_:)),
                                          keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func reloadPage() {
        webView.reload()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
