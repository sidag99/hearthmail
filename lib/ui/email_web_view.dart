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
  const EmailWebView({super.key, required this.html, this.background = Colors.white, this.topInset = 0, this.onScroll});

  final String html;
  final Color background;

  /// Empty space above the email, where the app lays the message header so
  /// header and email scroll as one page.
  final double topInset;

  /// Reports how far the email is scrolled.
  final ValueChanged<double>? onScroll;

  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isIOS || Platform.isAndroid) && WebViewPlatform.instance != null;

  @override
  State<EmailWebView> createState() => EmailWebViewState();
}

class EmailWebViewState extends State<EmailWebView> {
  WebViewController? _controller;
  String? _loaded;
  final _fallbackScroll = ScrollController();

  /// Scrolls the email (used for wheel and trackpad scrolling over the header).
  void scrollBy(double dy) {
    final c = _controller;
    if (c != null) {
      c.runJavaScript('window.scrollBy(0, $dy)');
    } else if (_fallbackScroll.hasClients) {
      final p = _fallbackScroll.position;
      _fallbackScroll.jumpTo((p.pixels + dy).clamp(0.0, p.maxScrollExtent));
    }
  }

  /// Applies the header space and reports scrolling. Runs as the app (not
  /// the email), so the email's Content-Security-Policy doesn't block it.
  void _applyInset() => _controller?.runJavaScript(
        "document.documentElement.style.paddingTop='${widget.topInset.toStringAsFixed(1)}px';"
        "if(!window.__hmScroll){window.__hmScroll=1;var t=0;"
        "addEventListener('scroll',function(){if(t)return;t=requestAnimationFrame(function(){t=0;"
        "HearthmailScroll.postMessage(String(window.scrollY));});},{passive:true});}",
      );

  @override
  void dispose() {
    _fallbackScroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (EmailWebView.supported) {
      _controller = WebViewController()
        // Needed only for our own fit-to-width script; the email's own
        // scripts are blocked by its Content-Security-Policy.
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel('HearthmailScroll', onMessageReceived: (m) {
          final y = double.tryParse(m.message);
          if (y != null) widget.onScroll?.call(y);
        })
        ..setNavigationDelegate(NavigationDelegate(
          onPageFinished: (_) => _applyInset(),
          onNavigationRequest: (req) {
            final url = req.url;
            // Only our own page load (loadHtmlString) stays inside.
            if (url.startsWith('about:')) return NavigationDecision.navigate;
            final uri = Uri.tryParse(url);
            // Links open in the browser or mail composer only: file:, smb:,
            // data:, app-specific schemes and the like are ignored.
            if (uri != null && req.isMainFrame && const {'http', 'https', 'mailto'}.contains(uri.scheme.toLowerCase())) {
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
  void didUpdateWidget(EmailWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_loaded != widget.html) widget.onScroll?.call(0);
    _load();
    if (oldWidget.topInset != widget.topInset) _applyInset();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c != null) return WebViewWidget(controller: c);
    // Fallback renderer.
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        widget.onScroll?.call(n.metrics.pixels);
        return false;
      },
      child: SingleChildScrollView(
      controller: _fallbackScroll,
      child: Container(
        color: widget.background,
        padding: EdgeInsets.fromLTRB(20, 16 + widget.topInset, 20, 24),
        child: HtmlWidget(
          widget.html,
          textStyle: TextStyle(color: widget.background.computeLuminance() > 0.5 ? Colors.black87 : Colors.white, fontSize: 14),
          onTapUrl: (url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        ),
      ),
      ),
    );
  }
}
