import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var channel: FlutterMethodChannel?
  private var dartReady = false
  /// mailto: URLs received before Dart said it is ready (cold launch via a link).
  private var pendingURLs: [String] = []

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      setUpChannel(controller)
    }
    super.applicationDidFinishLaunching(notification)
  }

  private func setUpChannel(_ controller: FlutterViewController) {
    guard channel == nil else { return }
    let channel = FlutterMethodChannel(name: "hearthmail/urls", binaryMessenger: controller.engine.binaryMessenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "ready":
        self?.dartReady = true
        self?.flushPending()
        result(nil)
      case "setDefaultMailApp":
        self?.setDefaultMailApp(result)
      case "isDefaultMailApp":
        result(self?.isDefaultMailApp() ?? false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func flushPending() {
    let urls = pendingURLs
    pendingURLs.removeAll()
    for url in urls { channel?.invokeMethod("openUrl", arguments: url) }
  }

  private func deliver(_ url: URL) {
    guard url.scheme?.lowercased() == "mailto" else { return }
    if dartReady, let channel = channel {
      channel.invokeMethod("openUrl", arguments: url.absoluteString)
    } else {
      pendingURLs.append(url.absoluteString)
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { deliver(url) }
    NSApp.activate(ignoringOtherApps: true)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
  }

  // MARK: Default mail app

  private func isDefaultMailApp() -> Bool {
    guard #available(macOS 12.0, *) else { return false }
    guard let probe = URL(string: "mailto:test@example.com"),
          let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
    return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
  }

  private func setDefaultMailApp(_ result: @escaping FlutterResult) {
    guard #available(macOS 12.0, *) else {
      result(false)
      return
    }
    NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto") { error in
      DispatchQueue.main.async { result(error == nil) }
    }
  }
}
