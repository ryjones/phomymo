// SPDX-License-Identifier: Apache-2.0

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let openRecentMenu = NSMenu(title: "Open Recent")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Menus

    private func buildMainMenu() -> NSMenu {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Phomymo"
        let main = NSMenu()

        // Application
        let app = NSMenu()
        app.addItem(withTitle: "About \(appName)", action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Forget Remembered Printers", action: #selector(forgetPrinters(_:)), keyEquivalent: "").target = self
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        // File
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        openRecentMenu.delegate = self
        file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = openRecentMenu
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save…", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        file.addItem(withTitle: "Revert to Saved", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        add(file, to: main)

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        // View
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        add(view, to: main)

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, to: main)
        NSApp.windowsMenu = window

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "\(appName) Manual", action: #selector(openManual(_:)), keyEquivalent: "?").target = self
        add(help, to: main)
        NSApp.helpMenu = help

        return main
    }

    private func add(_ submenu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        main.addItem(item)
    }

    /// The standard About panel, with links to this app's source and to the
    /// web designer it is built around.
    @objc private func showAbout(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]

        let credits = NSMutableAttributedString()
        func line(_ text: String, link: String, end: String = "\n") {
            credits.append(NSAttributedString(string: text, attributes: base))
            var linked = base
            linked[.link] = URL(string: "https://" + link)
            credits.append(NSAttributedString(string: link, attributes: linked))
            credits.append(NSAttributedString(string: end, attributes: base))
        }
        line("macOS app: ", link: "github.com/ryjones/phomymo")
        line("Original Phomymo label designer: ", link: "github.com/transcriptionstream/phomymo", end: "")

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Stop reconnecting automatically to printers used before.
    @objc private func forgetPrinters(_ sender: Any?) {
        KnownPrinters.forgetAll()
    }

    @objc private func openManual(_ sender: Any?) {
        EditorViewController.openBundledPage(URL(string: "phomymo://app/docs/manual.html")!)
    }

    // MARK: - Open Recent

    // Without a nib AppKit has no menu to fill in, so build it from the
    // document controller's list each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openRecentMenu else { return }
        menu.removeAllItems()

        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = menu.addItem(
                withTitle: FileManager.default.displayName(atPath: url.path),
                action: #selector(openRecent(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        if !urls.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(
            withTitle: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)),
            keyEquivalent: ""
        )
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                NSApp.presentError(error)
            }
        }
    }
}
