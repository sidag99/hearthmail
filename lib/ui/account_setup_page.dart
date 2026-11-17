import 'package:enough_mail/discover.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/account_config.dart';
import '../services/mail_service.dart';
import '../services/settings_store.dart';
import '../state/app_state.dart';

class AccountSetupPage extends StatefulWidget {
  const AccountSetupPage({super.key, this.isFirstRun = false});
  final bool isFirstRun;

  @override
  State<AccountSetupPage> createState() => _AccountSetupPageState();
}

class _AccountSetupPageState extends State<AccountSetupPage> {
  final _email = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _imapHost = TextEditingController();
  final _imapPort = TextEditingController(text: '993');
  final _smtpHost = TextEditingController();
  final _smtpPort = TextEditingController(text: '465');
  final _username = TextEditingController();

  ProviderPreset? _preset;
  bool _advanced = false;
  bool _busy = false;
  bool _discovering = false;
  String? _error;
  String _lastDiscovered = '';

  /// Chosen sign-in method; null while the user is choosing.
  AuthType? _method;
  bool _waitingForBrowser = false;
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();

  @override
  void dispose() {
    for (final c in [
      _email,
      _name,
      _password,
      _imapHost,
      _imapPort,
      _smtpHost,
      _smtpPort,
      _username,
      _clientId,
      _clientSecret,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onEmailChanged(String email) {
    final preset = ProviderPreset.forEmail(email);
    setState(() {
      _preset = preset;
      if (preset != null) {
        _imapHost.text = preset.imapHost;
        _imapPort.text = '${preset.imapPort}';
        _smtpHost.text = preset.smtpHost;
        _smtpPort.text = '${preset.smtpPort}';
      }
    });
  }

  /// For providers we don't know, ask the internet (Mozilla's ISP database,
  /// autoconfig and DNS) for the server settings.
  Future<void> _discover() async {
    final email = _email.text.trim();
    if (_preset != null || !email.contains('@') || email == _lastDiscovered) {
      return;
    }
    _lastDiscovered = email;
    setState(() => _discovering = true);
    try {
      final cfg = await Discover.discover(email);
      final imap = cfg?.preferredIncomingImapServer;
      final smtp = cfg?.preferredOutgoingSmtpServer;
      if (imap != null && smtp != null && mounted) {
        setState(() {
          _imapHost.text = imap.hostname;
          _imapPort.text = '${imap.port}';
          _smtpHost.text = smtp.hostname;
          _smtpPort.text = '${smtp.port}';
        });
      } else if (mounted) {
        setState(() => _advanced = true);
      }
    } catch (_) {
      if (mounted) setState(() => _advanced = true);
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _save() async {
    final email = _email.text.trim();
    if (!email.contains('@') || _password.text.isEmpty) {
      setState(() => _error = 'Enter your email address and app password.');
      return;
    }
    if (_imapHost.text.trim().isEmpty || _smtpHost.text.trim().isEmpty) {
      await _discover();
      if (_imapHost.text.trim().isEmpty) {
        setState(() {
          _advanced = true;
          _error =
              'Enter the IMAP and SMTP server names from your email provider.';
        });
        return;
      }
    }
    final config = AccountConfig(
      id: email.toLowerCase(),
      email: email,
      displayName: _name.text.trim(),
      imapHost: _imapHost.text.trim(),
      imapPort: int.tryParse(_imapPort.text.trim()) ?? 993,
      smtpHost: _smtpHost.text.trim(),
      smtpPort: int.tryParse(_smtpPort.text.trim()) ?? 465,
      username: _username.text.trim(),
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    // Gmail and others display app passwords in groups ("abcd efgh ..."); spaces aren't part of it.
    final password = _preset != null
        ? _password.text.replaceAll(' ', '')
        : _password.text;
    final err = await AppState.testAccount(
      config,
      PasswordCredentials(password),
    );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    final state = context.read<AppState>();
    await state.addAccount(config, password: password);
    if (state.settings.userName.isEmpty && config.displayName.isNotEmpty) {
      await state.updateSettings(
        state.settings.copyWith(userName: config.displayName),
      );
    }
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  // ------------------------------------------------------------ OAuth

  bool _hasClient(AppState state, AuthType t) => t == AuthType.google
      ? state.settings.googleClientId.isNotEmpty
      : state.settings.microsoftClientId.isNotEmpty;

  Future<void> _saveClient(AppState state, AuthType t) async {
    final id = _clientId.text.trim();
    if (id.isEmpty) {
      setState(() => _error = 'Paste the client ID first.');
      return;
    }
    final AppSettings s = t == AuthType.google
        ? state.settings.copyWith(
            googleClientId: id,
            googleClientSecret: _clientSecret.text.trim(),
          )
        : state.settings.copyWith(microsoftClientId: id);
    await state.updateSettings(s);
    setState(() => _error = null);
  }

  Future<void> _oauthSignIn(AuthType t) async {
    final state = context.read<AppState>();
    final client = state.oauthClientFor(t);
    if (client == null) return;
    setState(() {
      _waitingForBrowser = true;
      _error = null;
    });
    try {
      final result = await client.signIn(
        loginHint: _email.text.trim().isEmpty ? null : _email.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _waitingForBrowser = false;
        _busy = true;
      });
      final servers = client.servers;
      final config = AccountConfig(
        id: result.email.toLowerCase(),
        email: result.email,
        displayName: result.name,
        imapHost: servers.imapHost,
        imapPort: servers.imapPort,
        smtpHost: servers.smtpHost,
        smtpPort: servers.smtpPort,
        authType: t,
      );
      final err = await AppState.testAccount(
        config,
        OAuthCredentials(result.token, client),
      );
      if (!mounted) return;
      if (err != null) {
        setState(() {
          _busy = false;
          _error = t == AuthType.microsoft
              ? '$err\n\nSigned in, but the mail server refused the connection. Some universities turn off IMAP for Microsoft 365 accounts; if so, only their IT department can enable it.'
              : err;
        });
        return;
      }
      await state.addAccount(config, token: result.token);
      if (state.settings.userName.isEmpty && result.name.isNotEmpty) {
        await state.updateSettings(
          state.settings.copyWith(userName: result.name),
        );
      }
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _waitingForBrowser = false;
          _busy = false;
          _error = AppState.friendlyError(e);
        });
      }
    }
  }

  List<Widget> _chooser(ThemeData theme) {
    Widget option(IconData icon, String title, String subtitle, AuthType t) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.all(16),
              alignment: Alignment.centerLeft,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => setState(() {
              _method = t;
              _error = null;
              _clientId.clear();
              _clientSecret.clear();
            }),
            child: Row(
              children: [
                Icon(icon, size: 26),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(subtitle, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        );
    return [
      option(
        Icons.g_mobiledata_rounded,
        'Sign in with Google',
        'Gmail and Google Workspace (many university accounts)',
        AuthType.google,
      ),
      option(
        Icons.window_rounded,
        'Sign in with Microsoft',
        'Outlook, Hotmail and Microsoft 365 (many university accounts)',
        AuthType.microsoft,
      ),
      option(
        Icons.key_rounded,
        'Use an app password',
        'Gmail, iCloud, Yahoo, Fastmail or any other IMAP account',
        AuthType.password,
      ),
    ];
  }

  List<Widget> _oauthPanel(ThemeData theme, AuthType t) {
    final state = context.watch<AppState>();
    final google = t == AuthType.google;
    final name = google ? 'Google' : 'Microsoft';
    final back = TextButton.icon(
      style: TextButton.styleFrom(alignment: Alignment.centerLeft),
      onPressed: _waitingForBrowser || _busy
          ? null
          : () => setState(() {
              _method = null;
              _error = null;
            }),
      icon: const Icon(Icons.arrow_back, size: 16),
      label: const Text('Other sign-in options'),
    );
    final error = _error == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SelectableText(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          );

    if (!_hasClient(state, t)) {
      final steps = google
          ? [
              'Go to console.cloud.google.com and create a project (any name).',
              'APIs & Services → Library → enable the "Gmail API".',
              'OAuth consent screen: choose External, fill in an app name and your email. Under Audience → Test users, add every Google address you will sign in with.',
              'Credentials → Create credentials → OAuth client ID → Application type "Desktop app".',
              'Copy the Client ID and Client secret below.',
            ]
          : [
              'Go to entra.microsoft.com (sign in with any personal Microsoft account).',
              'App registrations → New registration. Supported accounts: "Accounts in any organizational directory and personal Microsoft accounts".',
              'Redirect URI: choose "Public client/native (mobile & desktop)" and enter http://localhost',
              'API permissions → Add → APIs my organization uses → "Office 365 Exchange Online" → Delegated → IMAP.AccessAsUser.All and SMTP.Send.',
              'Copy the "Application (client) ID" from the Overview page below.',
            ];
      return [
        back,
        const SizedBox(height: 8),
        Text(
          'One-time setup for $name sign-in',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          'Hearthmail has no company server, so $name needs to know about your own copy of the app. '
          'This free registration takes about 10 minutes and is only needed once for all your $name accounts. '
          'Full instructions are in OAUTH_SETUP.md.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Text('${i + 1}.', style: theme.textTheme.bodySmall),
                ),
                Expanded(
                  child: SelectableText(
                    steps[i],
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        TextButton(
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.zero,
          ),
          onPressed: () => launchUrl(
            Uri.parse(
              google ? 'https://console.cloud.google.com/apis/credentials' : 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade',
            ),
          ),
          child: Text('Open the $name console →'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _clientId,
          decoration: InputDecoration(
            labelText: google ? 'Client ID' : 'Application (client) ID',
          ),
        ),
        if (google) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _clientSecret,
            decoration: const InputDecoration(labelText: 'Client secret'),
          ),
        ],
        ?error,
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => _saveClient(state, t),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Save and continue'),
          ),
        ),
      ];
    }

    return [
      back,
      const SizedBox(height: 8),
      Text('Sign in with $name', style: theme.textTheme.titleMedium),
      const SizedBox(height: 6),
      Text(
        'Your browser will open to $name\'s sign-in page. Hearthmail never sees your password; '
        '$name gives it a key that only works for email, stored in your Mac\'s Keychain.',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _email,
        decoration: const InputDecoration(
          labelText: 'Email address (optional)',
          hintText: 'Pre-fills the sign-in page',
        ),
        keyboardType: TextInputType.emailAddress,
        onSubmitted: (_) => _oauthSignIn(t),
      ),
      ?error,
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _waitingForBrowser || _busy ? null : () => _oauthSignIn(t),
        icon: _waitingForBrowser || _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.open_in_new, size: 18),
        label: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            _waitingForBrowser
                ? 'Waiting for you to finish in the browser…'
                : _busy
                ? 'Connecting to your mailbox…'
                : 'Continue in browser',
          ),
        ),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _waitingForBrowser || _busy
            ? null
            : () async {
                final s = state.settings;
                await state.updateSettings(
                  google
                      ? s.copyWith(googleClientId: '', googleClientSecret: '')
                      : s.copyWith(microsoftClientId: ''),
                );
                setState(() {});
              },
        child: Text('Change $name app registration'),
      ),
    ];
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preset = _preset;
    return Scaffold(
      appBar: widget.isFirstRun
          ? null
          : AppBar(title: const Text('Add account')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.isFirstRun) ...[
                    Icon(
                      Icons.auto_awesome,
                      size: 40,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Welcome to Hearthmail',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Email with a private AI assistant that runs entirely on this Mac.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 28),
                  ],
                  if (_method == null) ..._chooser(theme),
                  if (_method == AuthType.google ||
                      _method == AuthType.microsoft)
                    ..._oauthPanel(theme, _method!),
                  if (_method == AuthType.password) ...[
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        alignment: Alignment.centerLeft,
                      ),
                      onPressed: () => setState(() {
                        _method = null;
                        _error = null;
                      }),
                      icon: const Icon(Icons.arrow_back, size: 16),
                      label: const Text('Other sign-in options'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Your name',
                        hintText: 'Shown to people you email',
                      ),
                      autofillHints: const [AutofillHints.name],
                    ),
                    const SizedBox(height: 12),
                    Focus(
                      onFocusChange: (f) {
                        if (!f) _discover();
                      },
                      child: TextField(
                        controller: _email,
                        decoration: InputDecoration(
                          labelText: 'Email address',
                          suffixIcon: _discovering
                              ? const Padding(
                                  padding: EdgeInsets.all(14),
                                  child: SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : preset == null
                              ? null
                              : Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Text(
                                    preset.name,
                                    style: theme.textTheme.labelMedium,
                                  ),
                                ),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        onChanged: _onEmailChanged,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'App password',
                      ),
                      onSubmitted: (_) => _save(),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            preset?.passwordHelp ??
                                'Use an app password from your email provider, not your normal password. '
                                    'It is stored in your Mac\'s Keychain.',
                            style: theme.textTheme.bodySmall,
                          ),
                          if (preset case ProviderPreset(
                            passwordUrl: final url?,
                          ))
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                              ),
                              onPressed: () => launchUrl(Uri.parse(url)),
                              child: Text(
                                'Create a ${preset.name} app password →',
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        alignment: Alignment.centerLeft,
                      ),
                      onPressed: () => setState(() => _advanced = !_advanced),
                      icon: Icon(
                        _advanced ? Icons.expand_less : Icons.expand_more,
                      ),
                      label: const Text('Server settings'),
                    ),
                    if (_advanced) ...[
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _imapHost,
                              decoration: const InputDecoration(
                                labelText: 'IMAP server',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _imapPort,
                              decoration: const InputDecoration(
                                labelText: 'Port',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _smtpHost,
                              decoration: const InputDecoration(
                                labelText: 'SMTP server',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _smtpPort,
                              decoration: const InputDecoration(
                                labelText: 'Port',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _username,
                        decoration: const InputDecoration(
                          labelText: 'Login name (if different from email)',
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Port 993 = IMAP over TLS, 465 = SMTP over TLS, 587 = SMTP with STARTTLS.',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _save,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Sign in'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
