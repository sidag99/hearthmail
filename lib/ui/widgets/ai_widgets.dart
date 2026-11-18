import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../mac_style.dart';

/// Renders the small subset of Markdown the AI produces: **bold**,
/// "- " bullets and blank-line paragraphs.
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  static List<InlineSpan> inline(String line, TextStyle base) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*');
    var last = 0;
    for (final m in re.allMatches(line)) {
      if (m.start > last) spans.add(TextSpan(text: line.substring(last, m.start)));
      spans.add(TextSpan(text: m[1], style: const TextStyle(fontWeight: FontWeight.w600)));
      last = m.end;
    }
    if (last < line.length) spans.add(TextSpan(text: line.substring(last)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final base = style ?? Theme.of(context).textTheme.bodyMedium!;
    final children = <Widget>[];
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        children.add(const SizedBox(height: 6));
        continue;
      }
      final bullet = RegExp(r'^\s*([-*•]|\d+\.)\s+').firstMatch(line);
      if (bullet != null) {
        final indent = line.indexOf(bullet[1]!) > 1 ? 16.0 : 0.0;
        children.add(Padding(
          padding: EdgeInsets.only(left: indent + 4, top: 2, bottom: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(bullet[1]!.endsWith('.') ? bullet[1]! : '•', style: base),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                  TextSpan(style: base, children: inline(line.substring(bullet.end), base))),
            ),
          ]),
        ));
      } else {
        final heading = RegExp(r'^#{1,6}\s+').firstMatch(line);
        final content = heading == null ? line : line.substring(heading.end);
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text.rich(TextSpan(
            style: heading == null ? base : base.copyWith(fontWeight: FontWeight.w600),
            children: inline(content, base),
          )),
        ));
      }
    }
    return SelectionArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}

/// Runs an AI stream and shows the text as it arrives.
class AiStreamView extends StatefulWidget {
  const AiStreamView({
    super.key,
    required this.start,
    this.onDone,
    this.placeholder = 'Thinking…',
  });

  /// Creates the stream; called once when the widget appears.
  final Stream<String> Function() start;
  final void Function(String text)? onDone;
  final String placeholder;

  @override
  State<AiStreamView> createState() => _AiStreamViewState();
}

class _AiStreamViewState extends State<AiStreamView> {
  final _buf = StringBuffer();
  StreamSubscription<String>? _sub;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = widget.start().listen(
      (chunk) => setState(() => _buf.write(chunk)),
      onError: (Object e) => setState(() => _error = e.toString()),
      onDone: () {
        if (!mounted) return;
        setState(() {});
        widget.onDone?.call(_buf.toString());
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_error != null) {
      return Text(_error!, style: TextStyle(color: theme.colorScheme.error));
    }
    if (_buf.isEmpty) {
      return Row(children: [
        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Text(widget.placeholder, style: theme.textTheme.bodySmall),
      ]);
    }
    // Selectable, so any part can be copied with ⌘C.
    return SelectionArea(child: MarkdownText(_buf.toString()));
  }
}

/// A tinted card that marks content as AI-generated.
class AiCard extends StatelessWidget {
  const AiCard({super.key, required this.title, required this.child, this.onClose, this.trailing});

  final String title;
  final Widget child;
  final VoidCallback? onClose;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = MacColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
      decoration: BoxDecoration(
        color: c.fill.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.separator),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.auto_awesome, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: c.label, fontWeight: FontWeight.w600)),
          const Spacer(),
          ?trailing,
          if (onClose != null)
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
              tooltip: 'Close',
              onPressed: onClose,
            ),
        ]),
        const SizedBox(height: 6),
        Padding(padding: const EdgeInsets.only(right: 6), child: child),
      ]),
    );
  }
}
