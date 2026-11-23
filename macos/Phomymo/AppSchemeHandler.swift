// SPDX-License-Identifier: Apache-2.0

import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled web app (the repository's src/web, copied into the app
/// as Resources/web) at phomymo://app/.
///
/// A custom scheme rather than file:// so that ES module imports and fetch()
/// behave as they do on the hosted site, and so localStorage has a stable origin.
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "phomymo"
    static let indexURL = URL(string: "phomymo://app/index.html")!

    private let root: URL

    /// Copies of the libraries and fonts index.html loads from CDNs
    /// (macos/vendor, fetched by macos/vendor/fetch.py), served at /vendor/.
    private let vendorRoot: URL

    /// CDN URL as written in index.html -> path under phomymo://app/.
    private let vendorReplacements: [String: String]

    override init() {
        let resources = Bundle.main.resourceURL!
        root = resources.appendingPathComponent("web", isDirectory: true).standardizedFileURL
        vendorRoot = resources.appendingPathComponent("vendor", isDirectory: true).standardizedFileURL

        struct Manifest: Decodable { let replacements: [String: String] }
        if let data = try? Data(contentsOf: vendorRoot.appendingPathComponent("manifest.json")),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            vendorReplacements = manifest.replacements
        } else {
            NSLog("Phomymo: vendor/manifest.json is missing; libraries will load from the network")
            vendorReplacements = [:]
        }
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        var path = url.path
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
        let vendorPrefix = "/vendor/"
        let base = path.hasPrefix(vendorPrefix) ? vendorRoot : root
        if path.hasPrefix(vendorPrefix) { path.removeFirst(vendorPrefix.count - 1) }
        let file = base.appendingPathComponent(path).standardizedFileURL

        // Never serve anything outside the bundled directories.
        guard file.path.hasPrefix(base.path + "/"), var data = try? Data(contentsOf: file) else {
            respond(to: task, url: url, status: 404, type: "text/plain", body: Data("Not found".utf8))
            return
        }
        if base == root, path == "/index.html" {
            data = usingVendoredLibraries(data)
        }
        respond(to: task, url: url, status: 200, type: Self.mimeType(for: file), body: data)
    }

    /// Point index.html at the bundled copies of its CDN libraries so the app works offline.
    private func usingVendoredLibraries(_ html: Data) -> Data {
        guard !vendorReplacements.isEmpty, var text = String(data: html, encoding: .utf8) else { return html }
        // Longest first: the pdf.js worker URL must not be half-rewritten by a shorter match.
        for (remote, local) in vendorReplacements.sorted(by: { $0.key.count > $1.key.count }) {
            let quoted = ["\"\(remote)\"", "'\(remote)'"]
            if !quoted.contains(where: text.contains) {
                NSLog("Phomymo: index.html no longer references %@; rerun macos/vendor/fetch.py", remote)
            }
            for form in quoted {
                let quote = String(form.prefix(1))
                text = text.replacingOccurrences(of: form, with: quote + local + quote)
            }
        }
        return Data(text.utf8)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(to task: WKURLSchemeTask, url: URL, status: Int, type: String, body: Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": type,
                "Content-Length": String(body.count),
                "Cache-Control": "no-cache",
            ]
        )!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    private static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "woff2": return "font/woff2"
        case "json": return "application/json; charset=utf-8"
        default:
            return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
