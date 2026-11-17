/// How an account signs in: an app password, or Google/Microsoft OAuth.
enum AuthType { password, google, microsoft }

/// Connection settings for one email account. The password is stored
/// separately in the system keychain, never in this object's JSON.
class AccountConfig {
  const AccountConfig({
    required this.id,
    required this.email,
    required this.displayName,
    required this.imapHost,
    required this.smtpHost,
    this.imapPort = 993,
    this.smtpPort = 465,
    this.username = '',
    this.authType = AuthType.password,
  });

  final String id;
  final AuthType authType;
  final String email;
  final String displayName;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;

  /// Login name if different from the email address.
  final String username;

  String get loginName => username.trim().isEmpty ? email : username.trim();

  /// Port 465 means TLS from the start; 587/25 means upgrade with STARTTLS.
  bool get smtpUsesStartTls => smtpPort != 465;
  bool get imapUsesStartTls => imapPort == 143;

  bool get isGmail =>
      imapHost.toLowerCase().contains('gmail.com') ||
      imapHost.toLowerCase().contains('googlemail.com');

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'displayName': displayName,
        'imapHost': imapHost,
        'imapPort': imapPort,
        'smtpHost': smtpHost,
        'smtpPort': smtpPort,
        'username': username,
        'authType': authType.name,
      };

  factory AccountConfig.fromJson(Map<String, dynamic> j) => AccountConfig(
        id: j['id'] as String,
        email: j['email'] as String,
        displayName: j['displayName'] as String? ?? '',
        imapHost: j['imapHost'] as String,
        imapPort: j['imapPort'] as int? ?? 993,
        smtpHost: j['smtpHost'] as String,
        smtpPort: j['smtpPort'] as int? ?? 465,
        username: j['username'] as String? ?? '',
        authType: AuthType.values.firstWhere(
          (t) => t.name == j['authType'],
          orElse: () => AuthType.password,
        ),
      );
}

/// Known providers, so most people only type their email and app password.
class ProviderPreset {
  const ProviderPreset({
    required this.name,
    required this.imapHost,
    required this.smtpHost,
    this.imapPort = 993,
    this.smtpPort = 465,
    this.domains = const [],
    this.passwordHelp = '',
    this.passwordUrl,
  });

  final String name;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
  final List<String> domains;
  final String passwordHelp;
  final String? passwordUrl;

  static const gmail = ProviderPreset(
    name: 'Gmail',
    imapHost: 'imap.gmail.com',
    smtpHost: 'smtp.gmail.com',
    domains: ['gmail.com', 'googlemail.com'],
    passwordHelp:
        'Gmail needs an app password (requires 2-Step Verification). Create one in your Google Account under Security → App passwords.',
    passwordUrl: 'https://myaccount.google.com/apppasswords',
  );
  static const icloud = ProviderPreset(
    name: 'iCloud',
    imapHost: 'imap.mail.me.com',
    smtpHost: 'smtp.mail.me.com',
    smtpPort: 587,
    domains: ['icloud.com', 'me.com', 'mac.com'],
    passwordHelp:
        'iCloud needs an app-specific password. Create one at account.apple.com under Sign-In and Security → App-Specific Passwords.',
    passwordUrl: 'https://account.apple.com/account/manage',
  );
  static const fastmail = ProviderPreset(
    name: 'Fastmail',
    imapHost: 'imap.fastmail.com',
    smtpHost: 'smtp.fastmail.com',
    domains: ['fastmail.com', 'fastmail.fm'],
    passwordHelp: 'Fastmail needs an app password: Settings → Privacy & Security → App passwords.',
    passwordUrl: 'https://app.fastmail.com/settings/security/apppasswords',
  );
  static const yahoo = ProviderPreset(
    name: 'Yahoo',
    imapHost: 'imap.mail.yahoo.com',
    smtpHost: 'smtp.mail.yahoo.com',
    domains: ['yahoo.com', 'ymail.com'],
    passwordHelp: 'Yahoo needs an app password: Account Info → Account Security → Generate app password.',
    passwordUrl: 'https://login.yahoo.com/account/security',
  );

  static const all = [gmail, icloud, fastmail, yahoo];

  static ProviderPreset? forEmail(String email) {
    final at = email.lastIndexOf('@');
    if (at < 0) return null;
    final domain = email.substring(at + 1).toLowerCase().trim();
    for (final p in all) {
      if (p.domains.contains(domain)) return p;
    }
    return null;
  }
}
