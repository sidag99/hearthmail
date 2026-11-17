import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hearthmail/models/account_config.dart';
import 'package:hearthmail/services/oauth.dart';

String _jwt(Map<String, Object> claims) =>
    'x.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.sig';

/// Plays the browser: checks the sign-in URL, then follows the redirect
/// back to the app's loopback server, like Google/Microsoft would.
Future<bool> Function(Uri) fakeBrowser(
  void Function(Uri) inspect, {
  bool tamperState = false,
  String? error,
}) =>
    (url) async {
      inspect(url);
      final q = url.queryParameters;
      final back = Uri.parse(q['redirect_uri']!).replace(queryParameters: {
        if (error == null) 'code': 'the-code' else 'error': error,
        'state': tamperState ? 'evil' : q['state']!,
      });
      // Fire-and-forget like a real browser; the app must not depend on order.
      () async {
        final c = HttpClient();
        try {
          final req = await c.getUrl(back.replace(host: '127.0.0.1'));
          final res = await req.close();
          await res.drain<void>();
        } finally {
          c.close();
        }
      }();
      return true;
    };

void main() {
  test('Google sign-in: PKCE, loopback redirect and token exchange', () async {
    late Uri authUrl;
    Map<String, String>? tokenRequest;
    final client = OAuthClient.google(
      clientId: 'cid',
      clientSecret: 'sec',
      openBrowser: fakeBrowser((u) => authUrl = u),
      httpClient: MockClient((req) async {
        tokenRequest = Uri.splitQueryString(req.body);
        return http.Response(
          jsonEncode({
            'access_token': 'at',
            'refresh_token': 'rt',
            'expires_in': 3599,
            'token_type': 'Bearer',
            'scope': 'https://mail.google.com/',
            'id_token': _jwt({'email': 'alex@uni.example.edu', 'name': 'Alex R'}),
          }),
          200,
        );
      }),
    );

    final result = await client.signIn(loginHint: 'alex@uni.example.edu');

    final q = authUrl.queryParameters;
    expect(authUrl.host, 'accounts.google.com');
    expect(q['client_id'], 'cid');
    expect(q['scope'], contains('https://mail.google.com/'));
    expect(q['access_type'], 'offline');
    expect(q['code_challenge_method'], 'S256');
    expect(q['redirect_uri'], startsWith('http://127.0.0.1:'));
    expect(q['login_hint'], 'alex@uni.example.edu');
    // The verifier sent with the code must hash to the challenge we opened with.
    final verifier = tokenRequest!['code_verifier']!;
    final expected = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    expect(q['code_challenge'], expected);
    expect(tokenRequest!['code'], 'the-code');
    expect(tokenRequest!['client_secret'], 'sec');
    expect(tokenRequest!['redirect_uri'], q['redirect_uri']);

    expect(result.email, 'alex@uni.example.edu');
    expect(result.name, 'Alex R');
    expect(result.token.accessToken, 'at');
    expect(result.token.refreshToken, 'rt');
    expect(client.servers.imapHost, 'imap.gmail.com');
  });

  test('Microsoft sign-in uses localhost redirect, no secret, IMAP+SMTP scopes', () async {
    late Uri authUrl;
    Map<String, String>? tokenRequest;
    final client = OAuthClient.microsoft(
      clientId: 'ms',
      openBrowser: fakeBrowser((u) => authUrl = u),
      httpClient: MockClient((req) async {
        tokenRequest = Uri.splitQueryString(req.body);
        return http.Response(
          jsonEncode({
            'access_token': 'at',
            'refresh_token': 'rt',
            'expires_in': 3600,
            'token_type': 'Bearer',
            'scope': 'IMAP',
            'id_token': _jwt({'preferred_username': 'alex@student.example.edu', 'name': 'Alex'}),
          }),
          200,
        );
      }),
    );
    final result = await client.signIn();
    expect(authUrl.host, 'login.microsoftonline.com');
    expect(authUrl.queryParameters['redirect_uri'], startsWith('http://localhost:'));
    expect(authUrl.queryParameters['scope'], contains('IMAP.AccessAsUser.All'));
    expect(authUrl.queryParameters['scope'], contains('SMTP.Send'));
    expect(authUrl.queryParameters['scope'], contains('offline_access'));
    expect(tokenRequest!.containsKey('client_secret'), isFalse);
    expect(result.email, 'alex@student.example.edu');
    expect(client.kind, AuthType.microsoft);
    expect(client.servers.smtpPort, 587);
  });

  test('rejects a redirect with the wrong state', () async {
    final client = OAuthClient.google(
      clientId: 'cid',
      clientSecret: '',
      openBrowser: fakeBrowser((_) {}, tamperState: true),
      httpClient: MockClient((_) async => http.Response('{}', 500)),
    );
    await expectLater(client.signIn(), throwsA(isA<OAuthException>()));
  });

  test('explains admin-consent errors from universities', () async {
    final client = OAuthClient.microsoft(
      clientId: 'ms',
      openBrowser: fakeBrowser((_) {}, error: 'access_denied'),
    );
    await expectLater(
      client.signIn(),
      throwsA(isA<OAuthException>().having((e) => e.message, 'message', contains('cancelled or not allowed'))),
    );
  });

  test('refresh keeps the old refresh token when none is returned', () async {
    final client = OAuthClient.google(
      clientId: 'cid',
      clientSecret: 's',
      httpClient: MockClient((req) async {
        expect(Uri.splitQueryString(req.body)['grant_type'], 'refresh_token');
        return http.Response(jsonEncode({'access_token': 'new', 'expires_in': 3600}), 200);
      }),
    );
    final t = await client.refresh('keep-me');
    expect(t.accessToken, 'new');
    expect(t.refreshToken, 'keep-me');
  });
}
