import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';

/// A switch for "Notify me about new mail". Drop it into any settings list:
///
///     const NotificationsSetting()
class NotificationsSetting extends StatelessWidget {
  const NotificationsSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return SwitchListTile(
      title: const Text('Notifications'),
      subtitle: const Text('Notify me about new mail. Muted, blocked and promotional messages stay quiet.'),
      value: state.settings.notifications,
      onChanged: (v) => state.updateSettings(state.settings.copyWith(notifications: v)),
    );
  }
}
