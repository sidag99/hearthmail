import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'services/settings_store.dart';
import 'state/app_state.dart';
import 'ui/account_setup_page.dart';
import 'ui/home_page.dart';
import 'ui/mac_style.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setUpMacWindow();
  final store = await SettingsStore.open();
  final state = AppState(store);
  runApp(ChangeNotifierProvider.value(value: state, child: const HearthmailApp()));
  // Connect after the first frame so the window appears immediately.
  await state.init();
}

class HearthmailApp extends StatelessWidget {
  const HearthmailApp({super.key});

  static ThemeData buildTheme(Brightness b) => buildMacTheme(b);

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
