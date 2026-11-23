// SPDX-License-Identifier: Apache-2.0

import AppKit
import UniformTypeIdentifiers
import WebKit

/// Window for one LabelDocument.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "PhomymoEditorWindow"
    private static var lastCascadePoint = NSPoint.zero

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Below 768pt wide the web app switches to its phone layout.
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.contentViewController = EditorViewController()

        self.init(window: window)
        window.delegate = self

        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        Self.lastCascadePoint = window.cascadeTopLeft(from: Self.lastCascadePoint)
    }

    func windowWillClose(_ notification: Notification) {
        (contentViewController as? EditorViewController)?.shutdown()
    }
}

/// Hosts the web app and connects it to the document, the file system and Bluetooth.
final class EditorViewController: NSViewController {
    private static let documentHandlerName = "phomymoDocument"

    private var webView: WKWebView!
    private let bluetooth = BluetoothBridge()
    private var isReady = false

    private var labelDocument: LabelDocument? {
        view.window?.windowController?.document as? LabelDocument
    }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: AppSchemeHandler.scheme)
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let content = configuration.userContentController
        content.add(WeakMessageHandler(self), name: Self.documentHandlerName)
        content.addScriptMessageHandler(bluetooth, contentWorld: .page, name: BluetoothBridge.handlerName)
        for source in [Self.bluetoothPolyfill, Self.localFontsPolyfill] {
            content.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1320, height: 880), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = false
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        bluetooth.webView = webView
        view = webView

        webView.load(URLRequest(url: AppSchemeHandler.indexURL))
    }

    func shutdown() {
        bluetooth.shutdown()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: - Document bridge (see src/web/native.js)

    /// Ask the web app for the current design as JSON.
    func fetchDesign(completion: @escaping (Result<String, Error>) -> Void) {
        guard isReady else {
            completion(.failure(LabelDocument.DocumentError.editorNotReady))
            return
        }
        webView.evaluateJavaScript("window.phomymoNative.serialize()") { value, error in
            if let json = value as? String {
                completion(.success(json))
            } else {
                completion(.failure(error ?? LabelDocument.DocumentError.nothingToWrite))
            }
        }
    }

    /// Tell the web app that `json` is now what is on disk.
    func markSaved(_ json: String) {
        callBridge("window.phomymoNative.markSaved(json)", arguments: ["json": json])
    }

    /// Replace the design on screen with the one the document last read from disk.
    func loadDesignFromDocument() {
        guard isReady, let document = labelDocument, let json = document.designJSON else { return }
        let name = document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName ?? ""
        callBridge("window.phomymoNative.load(json, name)", arguments: ["json": json, "name": name]) { error in
            guard let window = self.view.window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The design could not be opened."
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }

    private func callBridge(_ script: String, arguments: [String: Any], onError: ((Error) -> Void)? = nil) {
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("Phomymo bridge call failed: %@", String(describing: error))
                onError?(error)
            }
        }
    }

    #if DEBUG
    /// `Phomymo file.phomymo -SelfTestSaveTo /path/out.phomymo` (debug builds):
    /// once the design has loaded, save it to the given path and quit. Exercises
    /// the open and save round trip without anyone driving the UI.
    private func runSelfTestIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "SelfTestSaveTo") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let document = self.labelDocument else { return }
            let type = document.fileType ?? "dev.ryjones.phomymo.label"
            // Also record what the page managed to load, and from where.
            let probe = """
            JSON.stringify({
              libraries: {
                tailwind: typeof tailwind, JsBarcode: typeof JsBarcode, QRCode: typeof QRCode,
                jspdf: typeof window.jspdf, pdfjsLib: typeof window.pdfjsLib,
              },
              systemFonts: document.querySelectorAll('#prop-font-family optgroup[label="System Fonts"] option').length,
              interLoaded: document.fonts.check('16px Inter'),
              network: performance.getEntriesByType('resource').map(e => e.name).filter(n => n.startsWith('http')),
            }, null, 2)
            """
            self.webView.evaluateJavaScript(probe) { value, _ in
                try? (value as? String ?? "probe failed").write(toFile: path + ".probe.json", atomically: true, encoding: .utf8)
                document.save(to: URL(fileURLWithPath: path), ofType: type, for: .saveAsOperation) { error in
                    NSLog("Phomymo self-test save: %@", error.map { String(describing: $0) } ?? "ok")
                    exit(error == nil ? 0 : 1)
                }
            }
        }
    }
    #endif

    // MARK: - Injected scripts

    private static let bluetoothPolyfill: String = {
        guard let url = Bundle.main.url(forResource: "WebBluetoothPolyfill", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("WebBluetoothPolyfill.js is missing from the app bundle")
            return ""
        }
        return source
    }()

    /// WebKit has no Local Font Access API; answer queryLocalFonts() from the system font list.
    /// STORAGE_KEYS.LOCAL_FONTS_ENABLED in src/web/constants.js
    private static let localFontsEnabledKey = "phomymo_local_fonts_enabled"

    private static let localFontsPolyfill: String = {
        let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
        let fonts = families.map { ["family": $0, "fullName": $0, "postscriptName": $0, "style": "Regular"] }
        guard let data = try? JSONSerialization.data(withJSONObject: fonts),
              let json = String(data: data, encoding: .utf8) else { return "" }
        // In a browser the user opts in once (it prompts for permission) and the
        // web app remembers that under this key; here there is nothing to ask,
        // so mark it enabled and the System Fonts list is always present.
        return """
        if (!('queryLocalFonts' in window)) { window.queryLocalFonts = async () => \(json); }
        try { localStorage.setItem('\(localFontsEnabledKey)', 'true'); } catch (e) {}
        """
    }()
}

// MARK: - Messages from the page

extension EditorViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            loadDesignFromDocument()
            bluetooth.lookForKnownPrinters()
            #if DEBUG
            runSelfTestIfRequested()
            #endif
        case "dirty":
            let dirty = body["dirty"] as? Bool ?? false
            labelDocument?.updateChangeCount(dirty ? .changeDone : .changeCleared)
        default:
            break
        }
    }
}

/// WKUserContentController retains its handlers; this keeps the view controller out of that cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Navigation and downloads

extension EditorViewController: WKNavigationDelegate, WKDownloadDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Export (PNG, PDF, JSON) arrives as a click on <a download href="blob:...">.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame, url.scheme != AppSchemeHandler.scheme, url.scheme != "about", url.scheme != "blob" {
            // Links to the project site, GitHub and so on belong in the browser.
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard let window = view.window else {
            completionHandler(nil)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else {
                completionHandler(nil)
                return
            }
            // WKDownload refuses to overwrite; the panel has already confirmed replacement.
            try? FileManager.default.removeItem(at: url)
            completionHandler(url)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let window = view.window, (error as? URLError)?.code != .cancelled else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The document's JSON on disk is intact; unsaved edits in the page are gone.
        isReady = false
        webView.load(URLRequest(url: AppSchemeHandler.indexURL))
    }
}

// MARK: - Panels the page asks for

extension EditorViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // target="_blank" links
        if let url = navigationAction.request.url {
            if url.scheme == AppSchemeHandler.scheme {
                Self.openBundledPage(url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    /// Open a page of the bundled web app (the manual) in the default browser.
    static func openBundledPage(_ url: URL) {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("web") else { return }
        NSWorkspace.shared.open(root.appendingPathComponent(url.path))
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        present(alert) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        let alert = NSAlert()
        alert.messageText = prompt
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        guard let window = view.window else {
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
