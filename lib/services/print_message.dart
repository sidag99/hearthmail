import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../state/app_state.dart';
import 'email_html.dart';
import 'mail_service.dart';

String _esc(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s);

const _printCss = '''
body { padding: 0 !important; font: 12px/1.45 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; }
.lm-print-head { border-bottom: 1px solid #c8c8cc; padding-bottom: 10px; margin-bottom: 16px; }
.lm-print-head h1 { font-size: 17px; margin: 0 0 8px; font-weight: 600; }
.lm-print-head table { border-collapse: collapse; }
.lm-print-head td { padding: 1px 0; vertical-align: top; font-size: 12px; }
.lm-print-head td.k { color: #6e6e73; text-align: right; padding-right: 8px; white-space: nowrap; }
details.lm-quote > summary { display: none; }
img { max-width: 100%; height: auto; }
''';

/// Builds the printable page: a header block (From, To, Cc, Date, Subject)
/// followed by the message. [bodyDocument] is a complete HTML document, e.g.
/// from [EmailDocument]; its scripts are dropped, folded quotes are opened and
/// its own content security policy is kept (so remote content stays blocked
/// when it was blocked). Pure, so it can be tested.
String buildPrintHtml({
  required String from,
  required String to,
  String cc = '',
  DateTime? date,
  required String subject,
  required String bodyDocument,
}) {
  final doc = html_parser.parse(bodyDocument);
  doc.querySelectorAll('script').forEach((e) => e.remove());
  for (final d in doc.querySelectorAll('details.lm-quote')) {
    d.attributes['open'] = '';
  }

  String row(String k, String v) => v.trim().isEmpty ? '' : '<tr><td class="k">${_esc(k)}:</td><td>${_esc(v)}</td></tr>';
  final dateText = date == null ? '' : DateFormat.yMMMMEEEEd().add_jm().format(date.toLocal());
  final header = '<div class="lm-print-head"><h1>${_esc(subject)}</h1><table>'
      '${row('From', from)}${row('To', to)}${row('Cc', cc)}${row('Date', dateText)}'
      '</table></div>';

  final head = doc.head ?? (doc.documentElement!..insertBefore(dom.Element.tag('head'), doc.body));
  head.append(html_parser.parseFragment('<title>${_esc(subject)}</title><style>$_printCss</style>'));
  final body = doc.body ?? doc.documentElement!;
  body.insertBefore(html_parser.parseFragment(header), body.nodes.isEmpty ? null : body.nodes.first);
  return '<!DOCTYPE html>\n${doc.outerHtml}';
}

String? _inlineImage(MimeMessage m, String cid) {
  final part = m.getPartWithContentId(cid);
  final bytes = part?.decodeContentBinary();
  if (part == null || bytes == null) return null;
  final type = part.getHeaderContentType()?.mediaType.text ?? 'image/png';
  return 'data:$type;base64,${base64Encode(bytes)}';
}

/// The printable HTML for [m] (remote images are never loaded).
String printHtmlFor(MimeMessage m) {
  final html = m.decodeTextHtmlPart();
  final body = (html != null && html.trim().isNotEmpty)
      ? EmailDocument.fromHtml(html, allowRemote: false, inlineImage: (cid) => _inlineImage(m, cid))
      : EmailDocument.fromPlain(m.decodeTextPlainPart() ?? MailService.bodyText(m));
  return buildPrintHtml(
    from: MailService.senderOf(m)?.toString() ?? 'Unknown',
    to: MailService.addressList(m.to ?? m.envelope?.to),
    cc: MailService.addressList(m.cc ?? m.envelope?.cc),
    date: MailService.dateOf(m),
    subject: MailService.subjectOf(m),
    bodyDocument: body.html,
  );
}

/// Opens the native print dialog (which also offers Save as PDF) for [m].
/// Downloads the body first if only headers are loaded.
Future<void> printMessage(MimeMessage m, AppState state) async {
  try {
    var message = m;
    if (!MailService.hasBody(message)) {
      await state.openMessage(message);
      message = state.selected ?? message;
    }
    final html = printHtmlFor(message);
    final name = MailService.subjectOf(message);
    await Printing.layoutPdf(
      name: name,
      // ignore: deprecated_member_use
      onLayout: (format) => Printing.convertHtml(format: format, html: html),
    );
  } catch (e) {
    debugPrint('print failed: $e');
    state.toast('Could not print: ${AppState.friendlyError(e)}');
  }
}
