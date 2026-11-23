// SPDX-License-Identifier: Apache-2.0

import AppKit

/// One label design on disk.
///
/// The design itself lives in the web app running in the document's window;
/// this class only moves its JSON to and from the file. The format is the same
/// JSON the web app's Export/Import uses, so files are interchangeable with
/// the browser version.
final class LabelDocument: NSDocument {
    enum DocumentError: LocalizedError {
        case notADesign
        case editorNotReady
        case nothingToWrite

        var errorDescription: String? {
            switch self {
            case .notADesign: return "The file is not a Phomymo label design."
            case .editorNotReady: return "The label editor has not finished loading."
            case .nothingToWrite: return "The label design could not be read from the editor."
            }
        }
    }

    /// JSON most recently read from disk; handed to the editor once it is ready.
    private(set) var designJSON: String?

    /// JSON captured from the editor for the save that is in progress.
    private var jsonBeingSaved: String?

    private var editor: EditorViewController? {
        windowControllers.first?.contentViewController as? EditorViewController
    }

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController())
    }

    // MARK: - Reading

    override func read(from data: Data, ofType typeName: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["elements"] is [Any],
              let json = String(data: data, encoding: .utf8) else {
            throw DocumentError.notADesign
        }
        designJSON = json

        // Already on screen (Revert to Saved): push the reloaded design in.
        if let editor {
            editor.loadDesignFromDocument()
        }
    }

    // MARK: - Writing

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let editor else {
            completionHandler(DocumentError.editorNotReady)
            return
        }

        // The design has to be fetched from the web view asynchronously, but
        // NSDocument wants the bytes synchronously, so capture them first and
        // let data(ofType:) hand them over.
        editor.fetchDesign { result in
            switch result {
            case .failure(let error):
                completionHandler(error)
            case .success(let json):
                self.write(json, to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
            }
        }
    }

    private func write(
        _ json: String,
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        jsonBeingSaved = json
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            self.jsonBeingSaved = nil
            if error == nil, saveOperation == .saveOperation || saveOperation == .saveAsOperation {
                self.designJSON = json
                self.editor?.markSaved(json)
            }
            completionHandler(error)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let json = jsonBeingSaved else { throw DocumentError.nothingToWrite }
        return Data(json.utf8)
    }
}
