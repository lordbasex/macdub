import AppKit
import MacDubCore

/// MacDub's Chrome extension for live translation in Google Meet (the virtual microphone switch
/// and the chat). It ships inside the app (`Contents/Resources/meet-extension`, copied by
/// scripts/build-app.sh).
///
/// Chrome installs extensions by itself only from the Chrome Web Store. Until the extension is
/// published there (`webStoreID` is nil), "Install" copies it to a stable folder and opens
/// Chrome's extensions page for Load unpacked. Once published: the store page, plus a hint file
/// that makes Chrome offer it on its next launch.
enum ChromeExtension {
    /// The extension's id in the Chrome Web Store, once published.
    static let webStoreID: String? = nil

    static var bundled: URL? { Bundle.main.url(forResource: "meet-extension", withExtension: nil) }

    /// Where it is copied for Load unpacked: stable across app updates, outside the app bundle.
    static var folder: URL { MacDubPaths.dataDirectory.appendingPathComponent("chrome-extension", isDirectory: true) }

    static var version: String? {
        guard let manifest = bundled?.appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    static var chromeURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") }

    /// Copies the bundled extension to `folder` (replacing an older copy: Chrome then only needs
    /// its reload button). Returns the folder.
    @discardableResult
    static func prepareFolder() throws -> URL {
        guard let bundled else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: MacDubPaths.dataDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: bundled, to: folder)
        return folder
    }

    /// Published: the store page, and Chrome's external-extension hint. Not yet: the folder in
    /// Finder and chrome://extensions, for Developer mode › Load unpacked.
    static func install() throws {
        if let id = webStoreID {
            try? writeExternalExtensionHint(id: id)
            NSWorkspace.shared.open(URL(string: "https://chromewebstore.google.com/detail/\(id)")!)
            return
        }
        let folder = try prepareFolder()
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        openInChrome("chrome://extensions/")
    }

    static func openInChrome(_ link: String) {
        guard let url = URL(string: link), let chrome = chromeURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `~/Library/Application Support/Google/Chrome/External Extensions/<id>.json`: Chrome offers
    /// to install a Web Store extension named there the next time it starts.
    private static func writeExternalExtensionHint(id: String) throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/External Extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"external_update_url": "https://clients2.google.com/service/update2/crx"}"#
        try json.write(to: dir.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
    }
}
