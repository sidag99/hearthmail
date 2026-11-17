import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Shows an email page (from EmailDocument) in the system web engine
/// (WebKit on Mac/iPhone, Chromium on Android), so every email looks the way
/// its sender designed it. Links open in the browser.
///
/// Where no web engine is available (Windows for now, and tests), falls
/// back to a simpler built-in renderer.
class EmailWebView extends StatefulWidget {
  const EmailWebView({super.key, required this.html, this.background = Colors.white});

  final String html;
  final Color background;

  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isIOS || Platform.isAndroid) && WebViewPlatform.instance != null;

  @override
  State<EmailWebView> createState() => _EmailWebViewState();
}

class _EmailWebViewState extends State<EmailWebView> {
  WebViewController? _controller;
  String? _loaded;

  @override
  void initState() {
    super.initState();
    if (EmailWebView.supported) {
      _controller = WebViewController()
        // Needed only for our own fit-to-width script; the email's own
        // scripts are blocked by its Content-Security-Policy.
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onNavigationRequest: (req) {
            final url = req.url;
            if (url.startsWith('about:') || url.startsWith('data:')) return NavigationDecision.navigate;
            final uri = Uri.tryParse(url);
            if (uri != null && req.isMainFrame) {
              launchUrl(uri, mode: LaunchMode.externalApplication);
            }
            return NavigationDecision.prevent;
          },
        ));
      try {
        _controller!.setBackgroundColor(widget.background);
      } catch (_) {
        // Not supported on every platform.
      }
      _load();
    }
  }

  void _load() {
    if (_loaded == widget.html) return;
    _loaded = widget.html;
    _controller?.loadHtmlString(widget.html);
  }

  @override
  void didUpdateWidget(EmailWebView old) {
    super.didUpdateWidget(old);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c != null) return WebViewWidget(controller: c);
    // Fallback renderer.
    return SingleChildScrollView(
      child: Container(
        color: widget.background,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: HtmlWidget(
          widget.html,
          textStyle: TextStyle(color: widget.background.computeLuminance() > 0.5 ? Colors.black87 : Colors.white, fontSize: 14),
          onTapUrl: (url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        ),
      ),
    );
  }
}
