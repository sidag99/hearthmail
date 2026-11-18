import 'package:enough_mail/enough_mail.dart' show MailAddress;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../services/mail_service.dart';
import 'mac_style.dart';

/// An address field like Mail's: finished addresses become tokens; the
/// text still lives in [controller] as a comma-separated list, so the rest
/// of the composer is unchanged.
class RecipientField extends StatefulWidget {
  const RecipientField({super.key, required this.controller, required this.suggest});

  final TextEditingController controller;

  /// (email, name) suggestions for what is being typed.
  final Iterable<(String, String)> Function(String query) suggest;

  @override
  State<RecipientField> createState() => _RecipientFieldState();
}

class _RecipientFieldState extends State<RecipientField> {
  final _input = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  List<String> _tokens = [];

  @override
  void initState() {
    super.initState();
    _tokens = MailService.splitAddresses(widget.controller.text);
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit(_input.text);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _sync() => widget.controller.text = [..._tokens, if (_input.text.trim().isNotEmpty) _input.text.trim()].join(', ');

  void _commit(String text) {
    final parts = MailService.splitAddresses(text);
    if (parts.isEmpty) return;
    setState(() {
      _tokens = [..._tokens, ...parts];
      _input.clear();
    });
    _sync();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.backspace && _input.text.isEmpty && _tokens.isNotEmpty) {
      setState(() => _tokens = _tokens.sublist(0, _tokens.length - 1));
      _sync();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static bool _valid(String a) {
    try {
      return MailAddress.parse(a).email.contains('@');
    } catch (_) {
      return false;
    }
  }

  static String _short(String a) {
    try {
      final m = MailAddress.parse(a);
      return (m.personalName?.trim().isNotEmpty ?? false) ? m.personalName!.trim() : m.email;
    } catch (_) {
      return a;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (var i = 0; i < _tokens.length; i++)
          Tooltip(
            message: _tokens[i],
            child: Container(
              height: 22,
              padding: const EdgeInsets.only(left: 8, right: 2),
              decoration: BoxDecoration(
                color: _valid(_tokens[i]) ? c.accent.withValues(alpha: 0.12) : Theme.of(context).colorScheme.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_short(_tokens[i]),
                    style: TextStyle(fontSize: 13, color: _valid(_tokens[i]) ? c.label : Theme.of(context).colorScheme.error)),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    setState(() => _tokens = [..._tokens]..removeAt(i));
                    _sync();
                  },
                  child: Padding(padding: const EdgeInsets.all(3), child: Icon(Icons.close, size: 11, color: c.secondaryLabel)),
                ),
              ]),
            ),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 160, maxWidth: 520),
          child: IntrinsicWidth(
            child: RawAutocomplete<(String, String)>(
              textEditingController: _input,
              focusNode: _focus,
              optionsBuilder: (v) => v.text.trim().length < 2 ? const [] : widget.suggest(v.text.trim()),
              displayStringForOption: (o) => o.$1,
              onSelected: (o) {
                final addr = o.$2.isEmpty ? o.$1 : '${o.$2.contains(',') ? '"${o.$2}"' : o.$2} <${o.$1}>';
                _input.clear();
                _commit(addr);
                _focus.requestFocus();
              },
              fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
                controller: controller,
                focusNode: focusNode,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 5),
                ),
                onChanged: (t) {
                  // A comma or semicolon finishes an address.
                  if (t.contains(',') || t.contains(';')) {
                    _commit(t);
                  } else {
                    _sync();
                  }
                },
                onSubmitted: (t) {
                  _commit(t);
                  focusNode.requestFocus();
                },
              ),
              optionsViewBuilder: (context, onSelected, options) => Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  color: c.window,
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420, maxHeight: 260),
                    child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 4), children: [
                      for (final o in options)
                        InkWell(
                          onTap: () => onSelected(o),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(o.$2.isEmpty ? o.$1 : o.$2, style: TextStyle(fontSize: 13, color: c.label)),
                              if (o.$2.isNotEmpty) Text(o.$1, style: TextStyle(fontSize: 11, color: c.secondaryLabel)),
                            ]),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
