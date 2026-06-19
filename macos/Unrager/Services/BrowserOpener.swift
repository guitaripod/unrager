import AppKit

/// Opens web links in Vivaldi when it's installed (the browser whose x.com
/// session unrager already uses), falling back to the system default. Non-web
/// schemes (the `twitter://` app link, `x-apple.systempreferences:` …) are left
/// to their own default handler.
enum BrowserOpener {
    private static let vivaldiBundleID = "com.vivaldi.Vivaldi"

    static func open(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https",
              let vivaldi = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vivaldiBundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: vivaldi, configuration: NSWorkspace.OpenConfiguration())
    }
}
