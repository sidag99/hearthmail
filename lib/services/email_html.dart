import 'dart:convert';
import 'dart:math';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Turns an email body into a safe, self-contained web page for display.
///
/// - Scripts in the email never run (Content-Security-Policy with a nonce:
///   only our own tiny fit-to-width script may run).
/// - Remote images, styles and fonts are blocked unless allowed, so
///   tracking pixels cannot tell the sender you opened the email.
/// - Inline images (cid:) are embedded from the message itself.
/// - Wide newsletters are scaled to fit the pane, like Apple Mail does.
/// - Quoted replies are folded away behind "•••", like Gmail does.
class EmailDocument {
  EmailDocument._(this.html, this.blockedImages);

  final String html;

  /// How many remote images were held back.
  final int blockedImages;

  static String _nonce() {
    final r = Random.secure();
    return base64Url.encode(List.generate(12, (_) => r.nextInt(256)));
  }

  static String _csp(String nonce, bool allowRemote) => [
        "default-src 'none'",
        "script-src 'nonce-$nonce'",
        "style-src 'unsafe-inline'${allowRemote ? ' https: http:' : ''}",
        "img-src data: cid:${allowRemote ? ' https: http:' : ''}",
        "font-src data:${allowRemote ? ' https:' : ''}",
        "media-src data:",
        "frame-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
      ].join('; ');

  static const _baseCss = '''
html, body { margin: 0; padding: 0; }
body {
  padding: 16px 20px 28px;
  font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
  color: #1d1d1f; background: #ffffff;
  overflow-wrap: break-word; word-wrap: break-word;
  -webkit-text-size-adjust: 100%;
}
img { max-width: 100%; height: auto; }
img[data-lm-blocked] { display: inline-block; min-width: 1px; min-height: 1px; background: #f2f2f5; }
pre, code { white-space: pre-wrap; }
a { color: #0a66d8; }
details.lm-quote > summary {
  display: inline-block; list-style: none; cursor: pointer; margin: 8px 0; padding: 0 8px;
  border-radius: 8px; background: #e8e8ed; color: #555; font-size: 12px; line-height: 18px; letter-spacing: 1px;
}
details.lm-quote > summary::-webkit-details-marker { display: none; }
details.lm-quote[open] > summary { margin-bottom: 4px; }
''';

  static const _plainCss = '''
body { white-space: pre-wrap; }
blockquote { margin: 4px 0; padding-left: 10px; border-left: 3px solid #c7c7cc; color: #5a5a5f; }
.lm-sig { color: #6e6e73; }
''';

  static const _darkCss = '''
body { color: #e8e8ea; background: #1f1f22; }
a { color: #6cb0ff; }
blockquote { border-left-color: #55555a; color: #a8a8ad; }
.lm-sig { color: #98989d; }
details.lm-quote > summary { background: #3a3a3e; color: #ccc; }
''';

  /// Scales content that is wider than the window down to fit (once the
  /// page and its images have loaded, and on every resize).
  static String _fitScript(String nonce) => '''
<script nonce="$nonce">
(function(){
  function fit(){
    var b=document.body; if(!b) return;
    b.style.zoom='';
    var d=document.documentElement, w=Math.max(d.scrollWidth,b.scrollWidth), v=d.clientWidth||window.innerWidth;
    if(w>v+4){ b.style.zoom=Math.max(0.35,v/w); }
  }
  window.addEventListener('load',fit); window.addEventListener('resize',fit);
  document.addEventListener('DOMContentLoaded',fit); setTimeout(fit,60); setTimeout(fit,600);
})();
</script>''';

  /// An HTML email.
  /// [inlineImage] returns a data: URI for a Content-ID, if available.
  static EmailDocument fromHtml(
    String source, {
    required bool allowRemote,
    String? Function(String cid)? inlineImage,
  }) {
    final doc = html_parser.parse(source);
    final nonce = _nonce();

    // Anything that could run code, navigate or reload is dropped.
    doc.querySelectorAll('script, iframe, frame, frameset, object, embed, applet, base, meta[http-equiv], link[rel="import"], noscript').forEach((e) => e.remove());
    for (final e in doc.querySelectorAll('*')) {
      e.attributes.removeWhere((k, v) {
        final name = k.toString().toLowerCase();
        return name.startsWith('on') || (name == 'href' && v.trim().toLowerCase().startsWith('javascript:'));
      });
    }
    if (!allowRemote) {
      doc.querySelectorAll('link[rel="stylesheet"]').forEach((e) => e.remove());
    }

    var blocked = 0;
    for (final img in doc.querySelectorAll('img')) {
      final src = (img.attributes['src'] ?? '').trim();
      if (src.toLowerCase().startsWith('cid:')) {
        final data = inlineImage?.call(src.substring(4).replaceAll(RegExp(r'^<|>$'), ''));
        if (data != null) img.attributes['src'] = data;
      } else if (!allowRemote && (src.startsWith('http') || src.startsWith('//'))) {
        // A transparent pixel keeps the layout without a broken-image icon.
        img.attributes['src'] = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
        img.attributes.remove('srcset');
        img.attributes['data-lm-blocked'] = '1';
        // Tracking pixels are 1x1; anything else keeps its space and shape.
        final w = int.tryParse(img.attributes['width'] ?? '');
        final h = int.tryParse(img.attributes['height'] ?? '');
        if ((w != null && w <= 2) || (h != null && h <= 2)) {
          img.remove();
        } else if (w != null && h != null) {
          img.attributes['style'] = 'aspect-ratio: $w / $h; ${img.attributes['style'] ?? ''}';
        }
        blocked++;
      }
    }
    if (!allowRemote) {
      // Remote background images in style attributes are blocked by CSP too.
      blocked += doc.querySelectorAll('[background]').length;
    }

    _foldQuotes(doc);

    final head = doc.head ?? (doc.documentElement!..insertBefore(dom.Element.tag('head'), doc.body));
    final ours = html_parser.parseFragment(
      '<meta charset="utf-8">'
      '<meta http-equiv="Content-Security-Policy" content="${_csp(nonce, allowRemote)}">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<meta name="color-scheme" content="light">'
      '<style>$_baseCss</style>',
    );
    final first = head.nodes.isEmpty ? null : head.nodes.first;
    for (final n in [...ours.nodes]) {
      head.insertBefore(n, first);
    }
    final body = doc.body ?? doc.documentElement!;
    body.append(html_parser.parseFragment(_fitScript(nonce)));
    return EmailDocument._('<!DOCTYPE html>\n${doc.outerHtml}', blocked);
  }

  /// A plain-text email: links become clickable, quoted replies are folded
  /// and the signature is dimmed.
  static EmailDocument fromPlain(String text, {bool dark = false}) {
    final nonce = _nonce();
    final body = plainToHtml(text);
    return EmailDocument._(
      '<!DOCTYPE html><html><head>'
      '<meta charset="utf-8">'
      '<meta http-equiv="Content-Security-Policy" content="${_csp(nonce, false)}">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<meta name="color-scheme" content="${dark ? 'dark' : 'light'}">'
      '<style>$_baseCss$_plainCss${dark ? _darkCss : ''}</style>'
      '</head><body>$body${_fitScript(nonce)}</body></html>',
      0,
    );
  }

  static final _url = RegExp(r'''\b(https?://[^\s<>"']+[^\s<>"'.,;:!?)\]])|\b(www\.[^\s<>"']+[^\s<>"'.,;:!?)\]])|\b([\w.+-]+@[\w-]+\.[\w.-]+\w)''');

  static String _linkify(String escapedLine) => escapedLine.replaceAllMapped(_url, (m) {
        final t = m[0]!;
        final href = m[1] != null
            ? t
            : m[2] != null
                ? 'https://$t'
                : 'mailto:$t';
        return '<a href="${href.replaceAll('"', '%22')}">$t</a>';
      });

  /// Plain text to HTML, kept separate for testing.
  static String plainToHtml(String text) {
    const esc = HtmlEscape(HtmlEscapeMode.element);
    final lines = const LineSplitter().convert(text.replaceAll('\r\n', '\n'));
    final out = StringBuffer();
    var quoteDepth = 0;
    var inSig = false;
    var folded = false;

    // Where the quoted part of a reply starts ("On … wrote:" or "> ").
    final attribution = RegExp(r'^(On .{4,200}wrote:|Am .{4,200}schrieb .{1,100}:|Le .{4,200}a écrit\s?:|El .{4,200}escribió:|-{2,} ?Original Message ?-{2,}|-{2,} ?Ursprüngliche Nachricht ?-{2,}|From: .+)$', caseSensitive: false);
    int firstQuote = -1;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].trimLeft();
      if (l.startsWith('>') || (attribution.hasMatch(lines[i].trim()) && i + 1 < lines.length)) {
        // Only fold when the rest is (mostly) quoted text.
        final rest = lines.sublist(i).where((x) => x.trim().isNotEmpty).toList();
        final quoted = rest.where((x) => x.trimLeft().startsWith('>')).length;
        if (rest.isNotEmpty && quoted >= rest.length * 0.6) {
          firstQuote = i;
          break;
        }
      }
    }

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      if (i == firstQuote && !folded) {
        while (quoteDepth > 0) {
          out.write('</blockquote>');
          quoteDepth--;
        }
        out.write('<details class="lm-quote"><summary title="Show quoted text">•••</summary>');
        folded = true;
      }
      var depth = 0;
      var content = raw;
      final m = RegExp(r'^((?:\s?>)+)\s?').firstMatch(raw);
      if (m != null) {
        depth = '>'.allMatches(m[1]!).length;
        content = raw.substring(m[0]!.length);
      }
      while (quoteDepth < depth) {
        out.write('<blockquote>');
        quoteDepth++;
      }
      while (quoteDepth > depth) {
        out.write('</blockquote>');
        quoteDepth--;
      }
      if (depth == 0 && !inSig && (raw == '-- ' || raw == '--')) {
        inSig = true;
        out.write('<span class="lm-sig">');
      }
      out.write(_linkify(esc.convert(content)));
      out.write('\n');
    }
    while (quoteDepth > 0) {
      out.write('</blockquote>');
      quoteDepth--;
    }
    if (inSig) out.write('</span>');
    if (folded) out.write('</details>');
    return out.toString().replaceAll(RegExp(r'\n+$'), '');
  }

  /// Folds quoted history in HTML replies (Gmail, Apple Mail, Outlook).
  static void _foldQuotes(dom.Document doc) {
    final candidates = <dom.Element>[
      ...doc.querySelectorAll('div.gmail_quote, blockquote[type="cite"], div#appendonsend, div.yahoo_quoted, div#divRplyFwdMsg'),
    ];
    for (final q in candidates) {
      if (q.parent == null || q.text.trim().length < 40) continue;
      // Skip quotes nested in one we already folded.
      var p = q.parent;
      var nested = false;
      while (p != null) {
        if (p.localName == 'details' && p.classes.contains('lm-quote')) nested = true;
        p = p.parent;
      }
      if (nested) continue;
      final details = dom.Element.tag('details')..classes.add('lm-quote');
      details.append(dom.Element.tag('summary')
        ..attributes['title'] = 'Show quoted text'
        ..text = '•••');
      q.parent!.insertBefore(details, q);
      // Outlook puts the "From: … Sent: …" header before the quote: fold
      // everything after it.
      if (q.id == 'divRplyFwdMsg' || q.id == 'appendonsend') {
        var n = q as dom.Node?;
        final move = <dom.Node>[];
        while (n != null) {
          move.add(n);
          n = n.nextNode();
        }
        for (final x in move) {
          details.append(x);
        }
      } else {
        details.append(q);
      }
    }
  }
}

extension on dom.Node {
  dom.Node? nextNode() {
    final p = parentNode;
    if (p == null) return null;
    final i = p.nodes.indexOf(this);
    return i + 1 < p.nodes.length ? p.nodes[i + 1] : null;
  }
}
