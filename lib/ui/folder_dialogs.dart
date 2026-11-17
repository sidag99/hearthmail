import 'package:enough_mail/enough_mail.dart';
import 'package:material_ui/material_ui.dart';

import '../services/mail_service.dart';
import '../state/app_state.dart';

/// Asks for a name and creates a mailbox (inside [parent] when given).
/// Returns true if one was created.
Future<bool> showNewMailboxDialog(
  BuildContext context,
  AppState state,
  AccountSession session, {
  Mailbox? parent,
}) async {
  final done = await _nameDialog(
    context,
    title: parent == null ? 'New Mailbox' : 'New Mailbox in "${parent.name}"',
    action: 'Create',
    initial: '',
    submit: (name) => state.createMailbox(session, name, parent: parent),
  );
  return done;
}

/// Asks for a new name for [box]. System folders are refused with a message.
Future<bool> showRenameMailboxDialog(
  BuildContext context,
  AppState state,
  AccountSession session,
  Mailbox box,
) async {
  if (MailService.isProtectedMailbox(box)) {
    await _notice(context, 'Cannot Rename', '"${box.name}" is a system mailbox and cannot be renamed.');
    return false;
  }
  return _nameDialog(
    context,
    title: 'Rename Mailbox',
    action: 'Rename',
    initial: box.name,
    submit: (name) => name.trim() == box.name ? Future.value(null) : state.renameMailbox(session, box, name),
  );
}

/// Confirms, then deletes [box]. System folders are refused with a message.
Future<bool> confirmDeleteMailbox(
  BuildContext context,
  AppState state,
  AccountSession session,
  Mailbox box,
) async {
  if (MailService.isProtectedMailbox(box)) {
    await _notice(context, 'Cannot Delete', '"${box.name}" is a system mailbox and cannot be deleted.');
    return false;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Delete "${box.name}"?'),
      content: const Text('The mailbox and all messages in it will be deleted from the server. '
          'This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
      ],
    ),
  );
  if (ok != true) return false;
  final error = await state.deleteMailbox(session, box);
  if (error != null && context.mounted) {
    await _notice(context, 'Could Not Delete', error);
    return false;
  }
  return error == null;
}

Future<void> _notice(BuildContext context, String title, String message) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );

Future<bool> _nameDialog(
  BuildContext context, {
  required String title,
  required String action,
  required String initial,
  required Future<String?> Function(String name) submit,
}) async {
  final controller = TextEditingController(text: initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  String? error;
  var busy = false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (c) => StatefulBuilder(builder: (c, setState) {
      Future<void> go() async {
        if (busy) return;
        setState(() {
          busy = true;
          error = null;
        });
        final result = await submit(controller.text);
        if (!c.mounted) return;
        if (result == null) {
          Navigator.pop(c, true);
        } else {
          setState(() {
            busy = false;
            error = result;
          });
        }
      }

      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: controller,
            autofocus: true,
            enabled: !busy,
            decoration: InputDecoration(labelText: 'Name', errorText: error),
            onSubmitted: (_) => go(),
          ),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: busy ? null : go, child: Text(action)),
        ],
      );
    }),
  );
  controller.dispose();
  return ok ?? false;
}
