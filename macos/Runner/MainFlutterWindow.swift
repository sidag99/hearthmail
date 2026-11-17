import Cocoa
import FlutterMacOS
import NaturalLanguage
import Translation

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    AppleLanguageBridge.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Apple's on-device language detection (NaturalLanguage) and translation
/// (Translation framework), used by lib/services/apple_language.dart.
/// Both run entirely on this Mac.
enum AppleLanguageBridge {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "app.hearthmail/apple_language", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "detect":
        let text = args["text"] as? String ?? ""
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang] else {
          result(nil)
          return
        }
        result(["code": lang.rawValue, "confidence": confidence])
      case "status", "translate":
        guard #available(macOS 26.0, *) else {
          result(FlutterError(code: "unavailable", message: "Needs macOS 26", details: nil))
          return
        }
        let source = Locale.Language(identifier: args["source"] as? String ?? "en")
        let target = Locale.Language(identifier: args["target"] as? String ?? "en")
        Task {
          let status = await LanguageAvailability().status(from: source, to: target)
          let statusName: String
          switch status {
          case .installed: statusName = "installed"
          case .supported: statusName = "supported"
          default: statusName = "unsupported"
          }
          if call.method == "status" {
            DispatchQueue.main.async { result(statusName) }
            return
          }
          guard status == .installed else {
            DispatchQueue.main.async {
              result(FlutterError(code: "not_installed", message: statusName, details: nil))
            }
            return
          }
          do {
            // Translate paragraph by paragraph to keep the layout.
            let paragraphs = (args["paragraphs"] as? [String]) ?? []
            let session = TranslationSession(installedSource: source, target: target)
            let requests = paragraphs.enumerated().map {
              TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            let responses = try await session.translations(from: requests)
            var out = paragraphs
            for r in responses {
              if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText }
            }
            DispatchQueue.main.async { result(out) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
