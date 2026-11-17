import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:enough_mail/enough_mail.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/account_config.dart';

/// "Sign in with Google / Microsoft" using OAuth 2.0 with PKCE and a
/// loopback redirect: the browser signs in, then hands a one-time code back
/// to a tiny web server this app runs on 127.0.0.1 for a few minutes.
///
/// Needs the user's own free app registration (client ID); see
/// OAUTH_SETUP.md.
class OAuthClient {
  OAuthClient.google({required this.clientId, required String clientSecret, http.Client? httpClient, this.openBrowser})
      : kind = AuthType.google,
        clientSecret = clientSecret.trim().isEmpty ? null : clientSecret.trim(),
        _http = httpClient;

  OAuthClient.microsoft({required this.clientId, http.Client? httpClient, this.openBrowser})
      : kind = AuthType.microsoft,
        clientSecret = null,
        _http = httpClient;

  final http.Client? _http;

  /// Opens the sign-in page; defaults to the system browser (overridable for tests).
  final Future<bool> Function(Uri url)? openBrowser;

  final AuthType kind;
  final String clientId;
  final String? clientSecret;

  bool get _google => kind == AuthType.google;

  Uri get _authUrl => _google
      ? Uri.parse('https://accounts.google.com/o/oauth2/v2/auth')
      : Uri.parse('https://login.microsoftonline.com/common/oauth2/v2.0/authorize');

  Uri get _tokenUrl => _google
      ? Uri.parse('https://oauth2.googleapis.com/token')
      : Uri.parse('https://login.microsoftonline.com/common/oauth2/v2.0/token');

  List<String> get _scopes => _google
      ? const ['https://mail.google.com/', 'openid', 'email', 'profile']
      : const [
          'https://outlook.office.com/IMAP.AccessAsUser.All',
          'https://outlook.office.com/SMTP.Send',
          'offline_access',
          'openid',
          'email',
          'profile',
        ];

  /// Server settings that go with this provider.
  ({String imapHost, int imapPort, String smtpHost, int smtpPort}) get servers => _google
      ? (imapHost: 'imap.gmail.com', imapPort: 993, smtpHost: 'smtp.gmail.com', smtpPort: 465)
      : (imapHost: 'outlook.office365.com', imapPort: 993, smtpHost: 'smtp.office365.com', smtpPort: 587);

  /// Opens the browser for sign-in and waits for the result.
  Future<OAuthResult> signIn({String? loginHint}) async {
    final verifier = _randomString(64);
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final state = _randomString(24);

    final v4 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    HttpServer? v6;
    try {
      // "localhost" may resolve to ::1 in the browser; listen there too.
      v6 = await HttpServer.bind(InternetAddress.loopbackIPv6, v4.port);
    } catch (_) {}
    // Google wants the IP literal; Microsoft registrations use "localhost"
    // (and ignore the port for it).
    final redirect = _google ? 'http://127.0.0.1:${v4.port}' : 'http://localhost:${v4.port}';

    final done = Completer<Map<String, String>>();
    Future<void> handle(HttpRequest req) async {
      final q = req.uri.queryParameters;
      if (!q.containsKey('code') && !q.containsKey('error')) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final ok = q['state'] == state && q.containsKey('code');
      req.response.headers.contentType = ContentType.html;
      req.response.write('<html><body style="font-family:-apple-system,sans-serif;text-align:center;padding-top:80px">'
          '<h2>${ok ? 'Signed in to Lumen Mail' : 'Sign-in did not complete'}</h2>'
          '<p>You can close this tab and return to the app.</p></body></html>');
      await req.response.close();
      if (!done.isCompleted) done.complete(q);
    }

    final subs = [v4.listen(handle), if (v6 != null) v6.listen(handle)];
    try {
      final url = _authUrl.replace(queryParameters: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirect,
        'scope': _scopes.join(' '),
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        if (_google) ...{'access_type': 'offline', 'prompt': 'consent'} else 'prompt': 'select_account',
        'login_hint': ?loginHint,
      });
      final opened = openBrowser != null
          ? await openBrowser!(url)
          : await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!opened) {
        throw OAuthException('Could not open the web browser.');
      }
      final q = await done.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw OAuthException('Sign-in timed out. Please try again.'),
      );
      if (q['error'] != null) {
        throw OAuthException(_describeError(q['error']!, q['error_description']));
      }
      if (q['state'] != state) throw OAuthException('Sign-in response did not match. Please try again.');

      final json = await _post({
        'grant_type': 'authorization_code',
        'code': q['code']!,
        'redirect_uri': redirect,
        'client_id': clientId,
        'code_verifier': verifier,
        'client_secret': ?clientSecret,
        if (!_google) 'scope': _scopes.join(' '),
      });
      final token = _token(json);
      if (token.refreshToken.isEmpty) {
        throw OAuthException('The provider did not allow offline access, so you would be signed out within an hour.');
      }
      final claims = _idClaims(json['id_token'] as String?);
      final email = (claims['email'] ?? claims['preferred_username'] ?? loginHint ?? '').toString();
      if (!email.contains('@')) throw OAuthException('Could not read your email address from the sign-in.');
      return OAuthResult(token: token, email: email, name: (claims['name'] ?? '').toString());
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      await v4.close(force: true);
      await v6?.close(force: true);
    }
  }

  /// Gets a fresh access token. Access tokens last about an hour.
  Future<OauthToken> refresh(String refreshToken) async {
    final json = await _post({
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
      'client_secret': ?clientSecret,
      if (!_google) 'scope': _scopes.join(' '),
    });
    return _token(json, fallbackRefresh: refreshToken);
  }

  Future<Map<String, dynamic>> _post(Map<String, String> body) async {
    final http.Response res;
    try {
      final client = _http;
      res = await (client == null ? http.post(_tokenUrl, body: body) : client.post(_tokenUrl, body: body))
          .timeout(const Duration(seconds: 30));
    } on SocketException {
      throw OAuthException('No internet connection.');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw OAuthException(_describeError(
          json['error']?.toString() ?? 'HTTP ${res.statusCode}', json['error_description']?.toString()));
    }
    return json;
  }

  OauthToken _token(Map<String, dynamic> j, {String fallbackRefresh = ''}) => OauthToken(
        accessToken: j['access_token'] as String,
        expiresIn: (j['expires_in'] as num?)?.toInt() ?? 3600,
        refreshToken: (j['refresh_token'] as String?) ?? fallbackRefresh,
        scope: (j['scope'] as String?) ?? _scopes.join(' '),
        tokenType: (j['token_type'] as String?) ?? 'Bearer',
        created: DateTime.now().toUtc(),
        provider: kind.name,
      );

  static Map<String, dynamic> _idClaims(String? idToken) {
    if (idToken == null) return const {};
    final parts = idToken.split('.');
    if (parts.length < 2) return const {};
    try {
      return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  String _describeError(String code, String? description) {
    final d = description ?? '';
    if (code == 'access_denied') return 'Sign-in was cancelled or not allowed.';
    if (d.contains('AADSTS65001') || d.contains('AADSTS90094') || d.contains('admin')) {
      return 'Your organization requires an administrator to approve this app. '
          'Ask your university IT to allow it, or use Outlook/Apple Mail for this account.';
    }
    if (code == 'invalid_client' || d.contains('AADSTS700016')) {
      return 'The sign-in app registration was not found. Check the client ID in Settings → Sign-in apps.';
    }
    if (code == 'org_internal' || d.contains('org_internal')) {
      return 'This Google sign-in app only allows accounts from its own organization.';
    }
    return d.isEmpty ? 'Sign-in failed ($code).' : 'Sign-in failed: ${d.split('\r\n').first}';
  }

  static String _randomString(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

class OAuthResult {
  const OAuthResult({required this.token, required this.email, required this.name});
  final OauthToken token;
  final String email;
  final String name;
}

class OAuthException implements Exception {
  OAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}
