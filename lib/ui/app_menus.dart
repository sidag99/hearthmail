import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// What the menu bar items do. A null callback disables its item.
class AppMenuActions {
  const AppMenuActions({
    this.about,
    this.settings,
    this.newMessage,
    this.print,
    this.find,
    this.toggleSidebar,
    this.sidebarVisible = true,
    this.getNewMail,
    this.newMailbox,
    this.renameMailbox,
    this.deleteMailbox,
    this.reply,
    this.replyAll,
    this.forward,
    this.archive,
    this.junk,
    this.delete,
    this.flag,
    this.markUnread,
    this.remind,
    this.help,
  });

  final VoidCallback? about;
  final VoidCallback? settings;
  final VoidCallback? newMessage;
  final VoidCallback? print;
  final VoidCallback? find;
  final VoidCallback? toggleSidebar;

  /// Decides whether the View item reads "Hide Sidebar" or "Show Sidebar".
  final bool sidebarVisible;
  final VoidCallback? getNewMail;
  final VoidCallback? newMailbox;
  final VoidCallback? renameMailbox;
  final VoidCallback? deleteMailbox;
  final VoidCallback? reply;
  final VoidCallback? replyAll;
  final VoidCallback? forward;
  final VoidCallback? archive;
  final VoidCallback? junk;
  final VoidCallback? delete;
  final VoidCallback? flag;
  final VoidCallback? markUnread;
  final VoidCallback? remind;
  final VoidCallback? help;
}

/// The Apple Mail style menu bar. On macOS the menus are native; on other
/// platforms [child] is returned unchanged.
class AppMenus extends StatelessWidget {
  const AppMenus({super.key, required this.child, required this.actions});

  final Widget child;
  final AppMenuActions actions;

  @visibleForTesting
  static bool? debugForceEnabled;

  static bool get _enabled => debugForceEnabled ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return child;
    return PlatformMenuBar(menus: buildMenus(actions), child: child);
  }

  /// The menu tree (public so tests can inspect labels).
  @visibleForTesting
  static List<PlatformMenuItem> buildMenus(AppMenuActions a) {
    PlatformMenuItem item(String label, VoidCallback? onTap, [MenuSerializableShortcut? shortcut]) =>
        PlatformMenuItem(label: label, shortcut: shortcut, onSelected: onTap);

    SingleActivator key(LogicalKeyboardKey k, {bool shift = false, bool control = false, bool meta = true}) =>
        SingleActivator(k, meta: meta, shift: shift, control: control);

    // Text editing commands go to whatever text field has focus.
    PlatformMenuItem edit(String label, Intent Function() intent, LogicalKeyboardKey k, {bool shift = false}) =>
        PlatformMenuItem(
          label: label,
          shortcut: key(k, shift: shift),
          onSelected: () {
            final ctx = FocusManager.instance.primaryFocus?.context;
            if (ctx != null) Actions.maybeInvoke(ctx, intent());
          },
        );

    return [
      PlatformMenu(label: 'Hearthmail', menus: [
        PlatformMenuItemGroup(members: [
          item('About Hearthmail', a.about),
        ]),
        PlatformMenuItemGroup(members: [
          item('Settings…', a.settings, key(LogicalKeyboardKey.comma)),
        ]),
        const PlatformMenuItemGroup(members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
        ]),
        const PlatformMenuItemGroup(members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
        ]),
        const PlatformMenuItemGroup(members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
        ]),
      ]),
      PlatformMenu(label: 'File', menus: [
        PlatformMenuItemGroup(members: [
          item('New Message', a.newMessage, key(LogicalKeyboardKey.keyN)),
        ]),
        PlatformMenuItemGroup(members: [
          item('Print…', a.print, key(LogicalKeyboardKey.keyP)),
        ]),
      ]),
      PlatformMenu(label: 'Edit', menus: [
        PlatformMenuItemGroup(members: [
          edit('Undo', () => const UndoTextIntent(SelectionChangedCause.keyboard), LogicalKeyboardKey.keyZ),
          edit('Redo', () => const RedoTextIntent(SelectionChangedCause.keyboard), LogicalKeyboardKey.keyZ,
              shift: true),
        ]),
        PlatformMenuItemGroup(members: [
          edit('Cut', () => CopySelectionTextIntent.cut(SelectionChangedCause.keyboard), LogicalKeyboardKey.keyX),
          edit('Copy', () => CopySelectionTextIntent.copy, LogicalKeyboardKey.keyC),
          edit('Paste', () => const PasteTextIntent(SelectionChangedCause.keyboard), LogicalKeyboardKey.keyV),
          edit('Select All', () => const SelectAllTextIntent(SelectionChangedCause.keyboard),
              LogicalKeyboardKey.keyA),
        ]),
        PlatformMenuItemGroup(members: [
          item('Find', a.find, key(LogicalKeyboardKey.keyF)),
        ]),
      ]),
      PlatformMenu(label: 'View', menus: [
        PlatformMenuItemGroup(members: [
          item(a.sidebarVisible ? 'Hide Sidebar' : 'Show Sidebar', a.toggleSidebar,
              key(LogicalKeyboardKey.keyS, control: true)),
        ]),
        const PlatformMenuItemGroup(members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
        ]),
      ]),
      PlatformMenu(label: 'Mailbox', menus: [
        PlatformMenuItemGroup(members: [
          item('Get All New Mail', a.getNewMail, key(LogicalKeyboardKey.keyN, shift: true)),
        ]),
        PlatformMenuItemGroup(members: [
          item('New Mailbox…', a.newMailbox),
          item('Rename Mailbox…', a.renameMailbox),
          item('Delete Mailbox…', a.deleteMailbox),
        ]),
      ]),
      PlatformMenu(label: 'Message', menus: [
        PlatformMenuItemGroup(members: [
          item('Reply', a.reply, key(LogicalKeyboardKey.keyR)),
          item('Reply All', a.replyAll, key(LogicalKeyboardKey.keyR, shift: true)),
          item('Forward', a.forward, key(LogicalKeyboardKey.keyF, shift: true)),
        ]),
        PlatformMenuItemGroup(members: [
          item('Archive', a.archive, key(LogicalKeyboardKey.keyA, control: true)),
          item('Move to Junk', a.junk, key(LogicalKeyboardKey.keyJ, shift: true)),
          item('Delete', a.delete, key(LogicalKeyboardKey.backspace)),
        ]),
        PlatformMenuItemGroup(members: [
          item('Flag', a.flag, key(LogicalKeyboardKey.keyL, shift: true)),
          item('Mark as Unread', a.markUnread, key(LogicalKeyboardKey.keyU, shift: true)),
          item('Remind Me…', a.remind),
        ]),
      ]),
      const PlatformMenu(label: 'Window', menus: [
        PlatformMenuItemGroup(members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
        ]),
        PlatformMenuItemGroup(members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
        ]),
      ]),
      PlatformMenu(label: 'Help', menus: [
        item('Hearthmail Help', a.help),
      ]),
    ];
  }
}
