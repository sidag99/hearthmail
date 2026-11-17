import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'services/sandbox_migration.dart';
import 'services/settings_store.dart';
import 'state/app_state.dart';
import 'ui/account_setup_page.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SandboxMigration.run();
  final store = await SettingsStore.open();
  final state = AppState(store);
  runApp(ChangeNotifierProvider.value(value: state, child: const HearthmailApp()));
  // Connect after the first frame so the window appears immediately.
  await state.init();
}

class HearthmailApp extends StatelessWidget {
  const HearthmailApp({super.key});

  static ThemeData buildTheme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF5B5BD6), brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.6), space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, width: 420),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasAccount = context.select<AppState, bool>((s) => s.accounts.isNotEmpty);
    return MaterialApp(
      title: 'Hearthmail',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: hasAccount ? const HomePage() : const AccountSetupPage(isFirstRun: true),
    );
  }
}
