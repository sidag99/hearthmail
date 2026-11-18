import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' show OauthToken;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/account_config.dart';

/// App-wide preferences (AI setup and the user's writing profile).
class AppSettings {
  const AppSettings({
    this.ollamaUrl = 'http://localhost:11434',
    this.fastModel = '',
    this.writingModel = '',
    this.userName = '',
    this.styleNotes = '',
    this.autoSort = true,
    this.loadRemoteImages = false,
    this.googleClientId = '',
    this.googleClientSecret = '',
    this.microsoftClientId = '',
    this.embeddingModel = '',
    this.semanticSearch = true,
    this.translationModel = '',
    this.myLanguage = 'English',
    this.undoSendSeconds = 10,
    this.indexDepth = 3000,
    this.notifications = true,
    this.groupConversations = true,
    this.writingEngine = 'local',
    this.assistEngine = 'local',
    this.writingCloudModel = '',
    this.assistCloudModel = '',
    this.showCategories = false,
    this.priorityFirst = false,
    this.showContactPhotos = false,
    this.markReadDelay = 0,
    this.sortBy = 'date',
    this.sortAscending = false,
  });

  /// Message list order: date, from, subject, unread, flagged, attachments.
  final String sortBy;
  final bool sortAscending;

  /// Seconds before an opened message is marked read: 0 = at once,
  /// -1 = never (only by hand), like Apple Mail's "Mark as read" setting.
  final int markReadDelay;

  /// Mail's view options (the ⋯ menu above the message list).
  final bool showCategories;
  final bool priorityFirst;
  final bool showContactPhotos;

  /// Show one row per conversation in message lists.
  final bool groupConversations;

  final String ollamaUrl;

  /// Used for quick structured work: sorting, search, summaries.
  final String fastModel;

  /// Used for text you send: drafts, rewrites, digests.
  final String writingModel;
  final String userName;
  final String styleNotes;
  final bool autoSort;
  final bool loadRemoteImages;

  /// The user's own OAuth app registrations (see OAUTH_SETUP.md).
  final String googleClientId;
  final String googleClientSecret;
  final String microsoftClientId;

  /// Embedding model for semantic search (empty: picked automatically).
  final String embeddingModel;
  final bool semanticSearch;

  /// Dedicated translation model (empty: use the writing model).
  final String translationModel;

  /// The language the user reads and writes in.
  final String myLanguage;

  /// How long "Undo send" waits before really sending (0 = off).
  final int undoSendSeconds;

  /// How many recent emails per account to index for semantic search.
  final int indexDepth;

  /// Notify about new unread inbox mail.
  final bool notifications;
  /// Where writing jobs (drafts, rewrites, subjects, digests, outgoing
  /// translation) run: local, claudeApi, openaiApi, claudeCli, codexCli.
  final String writingEngine;

  /// Where everything else (summaries, search, triage, ...) runs.
  final String assistEngine;

  /// Model for the chosen cloud engine ('' = engine default).
  final String writingCloudModel;
  final String assistCloudModel;

  AppSettings copyWith({
    String? ollamaUrl,
    String? fastModel,
    String? writingModel,
    String? userName,
    String? styleNotes,
    bool? autoSort,
    bool? loadRemoteImages,
    String? googleClientId,
    String? googleClientSecret,
    String? microsoftClientId,
    String? embeddingModel,
    bool? semanticSearch,
    String? translationModel,
    String? myLanguage,
    int? undoSendSeconds,
    int? indexDepth,
    bool? notifications,
    bool? groupConversations,
    String? writingEngine,
    String? assistEngine,
    String? writingCloudModel,
    String? assistCloudModel,
    bool? showCategories,
    bool? priorityFirst,
    bool? showContactPhotos,
    int? markReadDelay,
    String? sortBy,
    bool? sortAscending,
  }) =>
      AppSettings(
        groupConversations: groupConversations ?? this.groupConversations,
        ollamaUrl: ollamaUrl ?? this.ollamaUrl,
        fastModel: fastModel ?? this.fastModel,
        writingModel: writingModel ?? this.writingModel,
        userName: userName ?? this.userName,
        styleNotes: styleNotes ?? this.styleNotes,
        autoSort: autoSort ?? this.autoSort,
        loadRemoteImages: loadRemoteImages ?? this.loadRemoteImages,
        googleClientId: googleClientId ?? this.googleClientId,
        googleClientSecret: googleClientSecret ?? this.googleClientSecret,
        microsoftClientId: microsoftClientId ?? this.microsoftClientId,
        embeddingModel: embeddingModel ?? this.embeddingModel,
        semanticSearch: semanticSearch ?? this.semanticSearch,
        translationModel: translationModel ?? this.translationModel,
        myLanguage: myLanguage ?? this.myLanguage,
        undoSendSeconds: undoSendSeconds ?? this.undoSendSeconds,
        indexDepth: indexDepth ?? this.indexDepth,
        notifications: notifications ?? this.notifications,
        writingEngine: writingEngine ?? this.writingEngine,
        assistEngine: assistEngine ?? this.assistEngine,
        writingCloudModel: writingCloudModel ?? this.writingCloudModel,
        assistCloudModel: assistCloudModel ?? this.assistCloudModel,
        showCategories: showCategories ?? this.showCategories,
        priorityFirst: priorityFirst ?? this.priorityFirst,
        showContactPhotos: showContactPhotos ?? this.showContactPhotos,
        markReadDelay: markReadDelay ?? this.markReadDelay,
        sortBy: sortBy ?? this.sortBy,
        sortAscending: sortAscending ?? this.sortAscending,
      );

  Map<String, dynamic> toJson() => {
        'ollamaUrl': ollamaUrl,
        'fastModel': fastModel,
        'writingModel': writingModel,
        'userName': userName,
        'styleNotes': styleNotes,
        'autoSort': autoSort,
        'loadRemoteImages': loadRemoteImages,
        'googleClientId': googleClientId,
        'googleClientSecret': googleClientSecret,
        'microsoftClientId': microsoftClientId,
        'embeddingModel': embeddingModel,
        'semanticSearch': semanticSearch,
        'translationModel': translationModel,
        'myLanguage': myLanguage,
        'undoSendSeconds': undoSendSeconds,
        'indexDepth': indexDepth,
        'notifications': notifications,
        'groupConversations': groupConversations,
        'writingEngine': writingEngine,
        'assistEngine': assistEngine,
        'writingCloudModel': writingCloudModel,
        'assistCloudModel': assistCloudModel,
        'showCategories': showCategories,
        'priorityFirst': priorityFirst,
        'showContactPhotos': showContactPhotos,
        'markReadDelay': markReadDelay,
        'sortBy': sortBy,
        'sortAscending': sortAscending,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        ollamaUrl: j['ollamaUrl'] as String? ?? 'http://localhost:11434',
        fastModel: j['fastModel'] as String? ?? '',
        writingModel: j['writingModel'] as String? ?? '',
        userName: j['userName'] as String? ?? '',
        styleNotes: j['styleNotes'] as String? ?? '',
        autoSort: j['autoSort'] as bool? ?? true,
        loadRemoteImages: j['loadRemoteImages'] as bool? ?? false,
        googleClientId: j['googleClientId'] as String? ?? '',
        googleClientSecret: j['googleClientSecret'] as String? ?? '',
        microsoftClientId: j['microsoftClientId'] as String? ?? '',
        embeddingModel: j['embeddingModel'] as String? ?? '',
        semanticSearch: j['semanticSearch'] as bool? ?? true,
        translationModel: j['translationModel'] as String? ?? '',
        myLanguage: j['myLanguage'] as String? ?? 'English',
        undoSendSeconds: j['undoSendSeconds'] as int? ?? 10,
        indexDepth: j['indexDepth'] as int? ?? 3000,
        notifications: j['notifications'] as bool? ?? true,
        groupConversations: j['groupConversations'] as bool? ?? true,
        writingEngine: j['writingEngine'] as String? ?? 'local',
        assistEngine: j['assistEngine'] as String? ?? 'local',
        writingCloudModel: j['writingCloudModel'] as String? ?? '',
        assistCloudModel: j['assistCloudModel'] as String? ?? '',
        showCategories: j['showCategories'] as bool? ?? false,
        priorityFirst: j['priorityFirst'] as bool? ?? false,
        showContactPhotos: j['showContactPhotos'] as bool? ?? false,
        markReadDelay: j['markReadDelay'] as int? ?? 0,
        sortBy: j['sortBy'] as String? ?? 'date',
        sortAscending: j['sortAscending'] as bool? ?? false,
      );
}

/// Persists settings and accounts. Passwords go to the OS keychain.
class SettingsStore {
  SettingsStore._(this._prefs);

  static Future<SettingsStore> open() async =>
      SettingsStore._(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  static const _secure = FlutterSecureStorage(
    // The classic login keychain works for unsigned/local builds, where the
    // newer data-protection keychain would need a paid developer signature.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  static const _settingsKey = 'settings.v1';
  static const _accountsKey = 'accounts.v1';

  AppSettings loadSettings() {
    final raw = _prefs.getString(_settingsKey);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings s) =>
      _prefs.setString(_settingsKey, jsonEncode(s.toJson()));

  List<AccountConfig> loadAccounts() {
    final raw = _prefs.getString(_accountsKey);
    if (raw == null) return [];
    try {
      return [
        for (final a in jsonDecode(raw) as List)
          AccountConfig.fromJson(a as Map<String, dynamic>)
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAccounts(List<AccountConfig> accounts) => _prefs.setString(
      _accountsKey, jsonEncode([for (final a in accounts) a.toJson()]));

  Future<String?> readPassword(String accountId) =>
      _secure.read(key: 'password.$accountId');
  Future<void> writePassword(String accountId, String password) =>
      _secure.write(key: 'password.$accountId', value: password);
  Future<void> deletePassword(String accountId) async {
    await _secure.delete(key: 'password.$accountId');
    await _secure.delete(key: 'oauth.$accountId');
  }

  /// Generic secrets (API keys) in the keychain.
  Future<String?> readSecret(String key) => _secure.read(key: key);
  Future<void> writeSecret(String key, String value) =>
      _secure.write(key: key, value: value);
  Future<void> deleteSecret(String key) => _secure.delete(key: key);

  Future<OauthToken?> readToken(String accountId) async {
    final raw = await _secure.read(key: 'oauth.$accountId');
    if (raw == null) return null;
    try {
      return OauthToken.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeToken(String accountId, OauthToken token) =>
      _secure.write(key: 'oauth.$accountId', value: jsonEncode(token.toJson()));
}
