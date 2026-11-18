import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart';
import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';
import 'package:material_ui/material_ui.dart';

/// Colors and sizes that follow the macOS design guidelines, so the app
/// looks at home next to Apple's own apps.
@immutable
class MacColors extends ThemeExtension<MacColors> {
  const MacColors({
    required this.accent,
    required this.window,
    required this.sidebar,
    required this.separator,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.hover,
    required this.sidebarSelection,
    required this.fill,
  });

  final Color accent;
  final Color window;
  final Color sidebar;
  final Color separator;
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color hover;
  final Color sidebarSelection;

  /// Light fill for search fields, pills and chips.
  final Color fill;

  static const light = MacColors(
    accent: Color(0xFF007AFF),
    window: Color(0xFFFFFFFF),
    sidebar: Color(0xFFEFEFF1),
    separator: Color(0x1F000000),
    label: Color(0xFF1D1D1F),
    secondaryLabel: Color(0xFF86868B),
    tertiaryLabel: Color(0xFFB0B0B5),
    hover: Color(0x0F000000),
    sidebarSelection: Color(0x1A000000),
    fill: Color(0x0D000000),
  );

  static const dark = MacColors(
    accent: Color(0xFF0A84FF),
    window: Color(0xFF1E1E1E),
    sidebar: Color(0xFF2A2A2C),
    separator: Color(0x24FFFFFF),
    label: Color(0xFFF5F5F7),
    secondaryLabel: Color(0xFF98989D),
    tertiaryLabel: Color(0xFF636366),
    hover: Color(0x14FFFFFF),
    sidebarSelection: Color(0x26FFFFFF),
    fill: Color(0x1AFFFFFF),
  );

  static MacColors of(BuildContext context) =>
      Theme.of(context).extension<MacColors>() ?? (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  MacColors copyWith() => this;

  @override
  MacColors lerp(MacColors? other, double t) => t < 0.5 || other == null ? this : other;
}

/// The app theme: macOS system font sizes (13 pt body), the system accent
/// blue, hairline separators and flat, quiet controls.
ThemeData buildMacTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? MacColors.dark : MacColors.light;
  final scheme = ColorScheme.fromSeed(seedColor: c.accent, brightness: brightness).copyWith(
    primary: c.accent,
    onPrimary: Colors.white,
    surface: c.window,
    onSurface: c.label,
    onSurfaceVariant: c.secondaryLabel,
    outlineVariant: c.separator,
    surfaceContainerLow: c.sidebar,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
  TextStyle? s(TextStyle? t, double size, [FontWeight? w]) =>
      t?.copyWith(fontSize: size, fontWeight: w, letterSpacing: 0, color: c.label, height: 1.3);
  final tt = base.textTheme;
  return base.copyWith(
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: c.window,
    canvasColor: c.window,
    dividerColor: c.separator,
    dividerTheme: DividerThemeData(color: c.separator, thickness: 0.5, space: 0.5),
    splashFactory: NoSplash.splashFactory,
    // Mac apps don't slide pages around: switch screens instantly.
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.macOS: _InstantTransitions(),
      TargetPlatform.windows: _InstantTransitions(),
      TargetPlatform.linux: _InstantTransitions(),
    }),
    highlightColor: Colors.transparent,
    hoverColor: c.hover,
    extensions: [c],
    textTheme: tt.copyWith(
      headlineSmall: s(tt.headlineSmall, 20, FontWeight.w700),
      titleLarge: s(tt.titleLarge, 17, FontWeight.w700),
      titleMedium: s(tt.titleMedium, 13, FontWeight.w600),
      titleSmall: s(tt.titleSmall, 12, FontWeight.w600),
      bodyLarge: s(tt.bodyLarge, 14),
      bodyMedium: s(tt.bodyMedium, 13),
      bodySmall: s(tt.bodySmall, 12)?.copyWith(color: c.secondaryLabel),
      labelLarge: s(tt.labelLarge, 13, FontWeight.w500),
      labelMedium: s(tt.labelMedium, 12, FontWeight.w500),
      labelSmall: s(tt.labelSmall, 11, FontWeight.w500)?.copyWith(color: c.secondaryLabel),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.window,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 52,
      titleTextStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.label),
      iconTheme: IconThemeData(color: c.secondaryLabel, size: 18),
      shape: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
    ),
    iconTheme: IconThemeData(color: c.secondaryLabel, size: 18),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.label,
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        side: BorderSide(color: c.separator),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(fontSize: 13),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        minimumSize: const Size(0, 24),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      labelStyle: TextStyle(color: c.secondaryLabel, fontSize: 13),
      hintStyle: TextStyle(color: c.tertiaryLabel, fontSize: 13),
      helperStyle: TextStyle(color: c.secondaryLabel, fontSize: 11),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.separator)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.separator)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: brightness == Brightness.dark ? const Color(0xFF2C2C2E) : const Color(0xFFF6F6F6),
      elevation: 6,
      shadowColor: Colors.black38,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: c.separator, width: 0.5)),
      textStyle: TextStyle(fontSize: 13, color: c.label),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: brightness == Brightness.dark ? const Color(0xFF2C2C2E) : const Color(0xFFF6F6F6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      titleTextStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.label),
      contentTextStyle: TextStyle(fontSize: 12, color: c.label),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 420,
      backgroundColor: brightness == Brightness.dark ? const Color(0xFF3A3A3C) : const Color(0xFF323234),
      contentTextStyle: const TextStyle(fontSize: 13, color: Colors.white),
      actionTextColor: brightness == Brightness.dark ? MacColors.dark.accent : const Color(0xFF64B5FF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 600),
      textStyle: TextStyle(fontSize: 11, color: c.label),
      decoration: BoxDecoration(
        color: brightness == Brightness.dark ? const Color(0xFF3A3A3C) : const Color(0xFFF6F6F6),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.separator, width: 0.5),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.fill),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : null),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      titleTextStyle: TextStyle(fontSize: 13, color: c.label),
      subtitleTextStyle: TextStyle(fontSize: 11, color: c.secondaryLabel),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.secondaryLabel, linearTrackColor: c.fill),
  );
}

/// True for the real macOS app (not tests), where the window gets a
/// translucent sidebar and a unified title bar.
final bool useMacWindow =
    !kIsWeb && Platform.isMacOS && !Platform.environment.containsKey('FLUTTER_TEST');

/// Height of the unified title bar + toolbar, where the window buttons sit.
const double kToolbarHeight52 = 52;

/// Apple Mail's flag colours, by index (see MailService.flagColorNames).
const kFlagColors = [
  Color(0xFFFF3B30), Color(0xFFFF9500), Color(0xFFFFCC00), Color(0xFF34C759),
  Color(0xFF007AFF), Color(0xFFAF52DE), Color(0xFF8E8E93),
];

/// Room the window's close/minimize/zoom buttons need at the top left of
/// whichever pane touches the window's left edge.
const double kTitlebarInset = 78;

/// Sets up the native window: transparent unified title bar and room for a
/// translucent sidebar.
Future<void> setUpMacWindow() async {
  if (!useMacWindow) return;
  await WindowManipulator.initialize();
  await WindowManipulator.setMaterial(NSVisualEffectViewMaterial.windowBackground);
  await WindowManipulator.makeTitlebarTransparent();
  await WindowManipulator.enableFullSizeContentView();
  await WindowManipulator.hideTitle();
  // An (empty) unified toolbar makes the title bar 52 pt tall and centers
  // the window buttons in it, like Mail.
  await WindowManipulator.addToolbar();
  await WindowManipulator.setToolbarStyle(toolbarStyle: NSWindowToolbarStyle.unified);
}

/// Lets clicks reach Flutter widgets placed in the title bar area.
class ToolbarItem extends StatelessWidget {
  const ToolbarItem({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => useMacWindow ? MacosToolbarPassthrough(child: child) : child;
}

/// A borderless toolbar button that highlights on hover, like in Mail.
class ToolButton extends StatelessWidget {
  const ToolButton({super.key, required this.icon, required this.tooltip, this.onPressed, this.color, this.size = 17});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return ToolbarItem(
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          hoverColor: c.hover,
          child: SizedBox(
            width: 32,
            height: 28,
            child: Icon(icon,
                size: size, color: onPressed == null ? c.tertiaryLabel : (color ?? c.secondaryLabel)),
          ),
        ),
      ),
    );
  }
}

/// A 0.5 pt separator line.
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.vertical = false, this.indent = 0});
  final bool vertical;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final color = MacColors.of(context).separator;
    return vertical
        ? Container(width: 0.5, color: color)
        : Container(height: 0.5, margin: EdgeInsets.only(left: indent), color: color);
  }
}

/// Small gray section title (sidebar, settings).
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(18, 14, 10, 4)});
  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(children: [
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: MacColors.of(context).secondaryLabel)),
          ),
          ?trailing,
        ]),
      );
}

/// A rounded search field like the one in Mail's toolbar.
class MacSearchField extends StatelessWidget {
  const MacSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onSubmitted,
    this.focusNode,
    this.onChanged,
    this.leading,
    this.trailing,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String>? onChanged;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return ToolbarItem(
      child: SizedBox(
        height: 28,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onSubmitted: onSubmitted,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          style: TextStyle(fontSize: 13, color: c.label),
          decoration: InputDecoration(
            filled: true,
            fillColor: c.fill,
            hintText: hint,
            contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            prefixIcon: leading ?? Icon(CupertinoIcons.search, size: 14, color: c.secondaryLabel),
            prefixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            suffixIcon: trailing,
            suffixIconConstraints: const BoxConstraints(minWidth: 24, minHeight: 28),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7), borderSide: BorderSide(color: c.accent.withValues(alpha: 0.6), width: 2)),
          ),
        ),
      ),
    );
  }
}

/// A gray rounded avatar with initials, like Mail's sender picture.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar(this.name, {super.key, this.size = 36});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final parts = name.replaceAll(RegExp(r'[^\p{L}\s]', unicode: true), ' ').trim().split(RegExp(r'\s+'));
    final initials = parts.isEmpty || parts.first.isEmpty
        ? '?'
        : (parts.first.characters.first + (parts.length > 1 ? parts.last.characters.first : '')).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFA5A5AB), Color(0xFF85858B)],
        ),
      ),
      child: Text(initials, style: TextStyle(color: Colors.white, fontSize: size * 0.4, fontWeight: FontWeight.w600)),
    );
  }
}


/// No page transition animation (instant switch), like a Mac app.
class _InstantTransitions extends PageTransitionsBuilder {
  const _InstantTransitions();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      child;
}

/// The top bar of a full-window page (Add Account, …): back button and
/// title, clear of the window's traffic lights, like a Mac toolbar.
class MacPageBar extends StatelessWidget implements PreferredSizeWidget {
  const MacPageBar({super.key, required this.title, this.actions = const []});
  final String title;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight52 + 0.5);

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return Material(
      color: c.window,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          height: kToolbarHeight52,
          child: Row(children: [
            SizedBox(width: useMacWindow ? kTitlebarInset : 8),
            ToolButton(
              icon: Icons.arrow_back_ios_new,
              size: 14,
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.label)),
            ),
            ...actions,
            const SizedBox(width: 8),
          ]),
        ),
        const Hairline(),
      ]),
    );
  }
}
