import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Dock icon badge (unread count), driven from Dart (lib/services/dock_badge.dart).
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "app.hearthmail/badge", binaryMessenger: controller.engine.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        if call.method == "setBadge" {
          let label = call.arguments as? String
          NSApp.dockTile.badgeLabel = (label?.isEmpty ?? true) ? nil : label
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
