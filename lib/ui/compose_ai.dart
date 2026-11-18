import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/email_content.dart';
import '../models/intent.dart';
import '../services/ai/ai_provider.dart';
import '../services/ai/engines.dart';
import '../state/app_state.dart';
import 'mac_style.dart';

/// A small pill button, used for the composer's AI actions.
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, this.icon, this.onTap, this.selected = false, this.tooltip});
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool selected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    final fg = onTap == null ? c.tertiaryLabel : (selected ? Colors.white : c.label);
    final pill = Material(
      color: selected ? c.accent : c.fill,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 12, color: selected ? Colors.white : c.secondaryLabel), const SizedBox(width: 4)],
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: fg))),
          ]),
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip!, child: pill);
  }
}

/// One click to see and change which model writes: "✨ Claude Sonnet 5.5 ▾".
class WriterSwitcher extends StatelessWidget {
  const WriterSwitcher({super.key, this.onChanged});

  /// Called after the user picked a different model.
  final VoidCallback? onChanged;

  static String _group(String engine) => switch (engine) {
        AiEngine.local => 'On this Mac',
        AiEngine.claudeApi || AiEngine.claudeCli => 'Claude',
        AiEngine.openaiApi || AiEngine.codexCli => 'ChatGPT',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = MacColors.of(context);
    final current = state.currentWritingChoice;
    final choices = state.writingChoices;
    return ToolbarItem(
      child: PopupMenuButton<WritingChoice>(
        popUpAnimationStyle: AnimationStyle.noAnimation,
        tooltip: 'Model that writes for you',
        onSelected: (w) async {
          if (w == current) return;
          await state.setWritingChoice(w);
          onChanged?.call();
        },
        itemBuilder: (_) {
          final items = <PopupMenuEntry<WritingChoice>>[];
          String? group;
          for (final w in choices) {
            final g = _group(w.engine);
            if (g != group) {
              if (group != null) items.add(const PopupMenuDivider());
              items.add(PopupMenuItem(
                enabled: false,
                height: 24,
                child: Text(g, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c.secondaryLabel)),
              ));
              group = g;
            }
            items.add(CheckedPopupMenuItem(value: w, checked: w == current, height: 30, child: Text(w.label)));
          }
          if (choices.isEmpty) {
            items.add(const PopupMenuItem(enabled: false, child: Text('No models yet: add one in Settings > AI')));
          }
          return items;
        },
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(12)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(CupertinoIcons.sparkles, size: 12, color: c.accent),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(current.label,
                  overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.label, fontWeight: FontWeight.w500)),
            ),
            const SizedBox(width: 3),
            Icon(CupertinoIcons.chevron_down, size: 10, color: c.secondaryLabel),
          ]),
        ),
      ),
    );
  }
}

/// A friendly one-line reason for an AI failure.
String describeAiError(Object e, WritingChoice who) => switch (e) {
      AiLimitException() => '${who.label} hit its usage limit.',
      AiAuthException() => '${who.label} is not signed in or not set up.',
      _ => '${who.label} failed: $e',
    };

/// "What should it say?": the local model suggests what the email could
/// convey as short options; the user taps the ones they want and the
/// writer model writes the email.
class IntentPanel extends StatefulWidget {
  const IntentPanel({
    super.key,
    required this.notes,
    required this.onWrite,
    required this.onClose,
    this.replyTo,
    this.to = '',
    this.subject = '',
  });

  /// What the user typed in their own words (kept by the composer).
  final TextEditingController notes;
  final EmailContent? replyTo;
  final String to;
  final String subject;
  final void Function(IntentChoice choice) onWrite;
  final VoidCallback onClose;

  @override
  State<IntentPanel> createState() => _IntentPanelState();
}

class _IntentPanelState extends State<IntentPanel> {
  IntentOptions? _options;
  bool _loading = false;
  String? _error;
  String? _goal;
  final _points = <String>{};
  String? _tone;

  @override
  void initState() {
    super.initState();
    // For replies there is enough to go on straight away.
    if (widget.replyTo != null) unawaited(_suggest());
    widget.notes.addListener(_changed);
  }

  @override
  void dispose() {
    widget.notes.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _suggest() async {
    final ai = context.read<AppState>().ai;
    if (ai == null) return;
    if (widget.replyTo == null && widget.notes.text.trim().isEmpty) {
      setState(() => _error = 'Type a few words about the email first.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final o = await ai.suggestIntents(
          replyTo: widget.replyTo, notes: widget.notes.text, to: widget.to, subject: widget.subject);
      if (!mounted) return;
      setState(() {
        _options = o;
        _goal = o.goals.isEmpty ? null : o.goals.first;
        _points.clear();
        _tone = null;
        if (o.isEmpty) _error = 'No suggestions. Type what you want to say and press Write.';
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not suggest options: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  IntentChoice get _choice =>
      IntentChoice(goal: _goal, points: _points.toList(), tone: _tone, notes: widget.notes.text);

  void _write() {
    final choice = _choice;
    if (choice.isEmpty) {
      setState(() => _error = 'Pick an option or type what you want to say.');
      return;
    }
    widget.onWrite(choice);
  }

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    final o = _options;
    Widget row(String title, List<Widget> chips) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 76,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(title, style: TextStyle(fontSize: 12, color: c.secondaryLabel)),
              ),
            ),
            Expanded(child: Wrap(spacing: 6, runSpacing: 6, children: chips)),
          ]),
        );

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.separator),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(widget.replyTo == null ? 'What should the email say?' : 'How do you want to reply?',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.label)),
          const Spacer(),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
            ),
          ToolButton(icon: CupertinoIcons.xmark, tooltip: 'Close', size: 13, onPressed: widget.onClose),
        ]),
        if (o != null && o.goals.isNotEmpty)
          row('Main point', [
            for (final g in o.goals)
              Pill(label: g, selected: _goal == g, onTap: () => setState(() => _goal = _goal == g ? null : g)),
          ]),
        if (o != null && o.points.isNotEmpty)
          row('Also say', [
            for (final p in o.points)
              Pill(
                label: p,
                icon: _points.contains(p) ? CupertinoIcons.checkmark : CupertinoIcons.plus,
                selected: _points.contains(p),
                onTap: () => setState(() => _points.contains(p) ? _points.remove(p) : _points.add(p)),
              ),
          ]),
        if (o != null && o.tones.isNotEmpty)
          row('Tone', [
            for (final t in o.tones)
              Pill(label: t, selected: _tone == t, onTap: () => setState(() => _tone = _tone == t ? null : t)),
          ]),
        if (o == null && _loading)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Reading the email for options…', style: TextStyle(fontSize: 12, color: c.secondaryLabel)),
          ),
        const SizedBox(height: 10),
        TextField(
          controller: widget.notes,
          autofocus: widget.replyTo == null,
          minLines: 1,
          maxLines: 4,
          style: const TextStyle(fontSize: 13),
          onSubmitted: (_) => _write(),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: c.fill,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
            hintText: widget.replyTo == null
                ? 'A few words, e.g. "landlord, sink leaking, need plumber this week, home after 5"'
                : 'Or say it in your own words (optional)',
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_error!, style: TextStyle(fontSize: 12, color: c.secondaryLabel)),
          ),
        const SizedBox(height: 8),
        Row(children: [
          const WriterSwitcher(),
          const Spacer(),
          TextButton(
            onPressed: _loading ? null : _suggest,
            child: Text(o == null ? 'Suggest Options' : 'New Options'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: _loading && o == null ? null : _write,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: const Text('Write'),
          ),
        ]),
      ]),
    );
  }
}
