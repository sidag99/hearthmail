import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

const _blockTags = {
  'p', 'div', 'br', 'tr', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'table', 'section', 'article', 'header', 'footer', 'blockquote', 'hr', 'ul', 'ol',
};

/// Converts an HTML email into readable plain text (for AI and previews).
String htmlToText(String html) {
  final doc = html_parser.parse(html);
  doc.querySelectorAll('script, style, head, title, noscript').forEach((e) => e.remove());
  final buf = StringBuffer();

  void walk(dom.Node node) {
    if (node is dom.Text) {
      buf.write(node.text.replaceAll(RegExp(r'\s+'), ' '));
      return;
    }
    if (node is dom.Element) {
      final tag = node.localName ?? '';
      if (tag == 'li') buf.write('\n- ');
      for (final child in node.nodes) {
        walk(child);
      }
      if (tag == 'a') {
        // Keep link targets that differ from the visible text; useful context.
        final href = node.attributes['href'] ?? '';
        if (href.startsWith('http') && !node.text.contains(href) && href.length < 120) {
          buf.write(' ($href)');
        }
      }
      if (_blockTags.contains(tag)) buf.write('\n');
      return;
    }
    for (final child in node.nodes) {
      walk(child);
    }
  }

  walk(doc.body ?? doc.documentElement ?? doc);
  return buf
      .toString()
      .split('\n')
      .map((l) => l.trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// Removes remote images (tracking pixels) unless the user allows them.
String blockRemoteImages(String html) {
  final doc = html_parser.parse(html);
  var blocked = 0;
  for (final img in doc.querySelectorAll('img')) {
    final src = img.attributes['src'] ?? '';
    if (src.startsWith('http')) {
      img.remove();
      blocked++;
    }
  }
  return blocked == 0 ? html : doc.outerHtml;
}
