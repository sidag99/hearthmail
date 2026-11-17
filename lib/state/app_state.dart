import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/account_config.dart';
import '../models/email_content.dart';
import '../models/search_plan.dart';
import '../models/triage.dart';
import '../services/ai/ai_provider.dart';
import '../services/ai/email_ai.dart';
import '../services/ai/ollama_provider.dart';
import '../services/mail_service.dart';
import '../services/oauth.dart';
import '../services/settings_store.dart';
import '../services/triage_cache.dart';
import '../services/user_data.dart';
import '../services/vector_index.dart';

/// What the message list is showing.
enum ViewKind { allInboxes, folder, priority, needsReply, category, search, vip, snoozed, scheduled, followUp }

/// Quick filters above the message list.
enum ListFilter { all, unread, flagged, attachments }

class MailView {
  const MailView.allInboxes() : kind = ViewKind.allInboxes, category = null, accountId = null, path = null;
  const MailView.folder(String this.accountId, String this.path) : kind = ViewKind.folder, category = null;
  const MailView.priority() : kind = ViewKind.priority, category = null, accountId = null, path = null;
  const MailView.needsReply() : kind = ViewKind.needsReply, category = null, accountId = null, path = null;
  const MailView.category(MailCategory this.category) : kind = ViewKind.category, accountId = null, path = null;
  const MailView.search() : kind = ViewKind.search, category = null, accountId = null, path = null;
  const MailView.vip() : kind = ViewKind.vip, category = null, accountId = null, path = null;
  const MailView.snoozed() : kind = ViewKind.snoozed, category = null, accountId = null, path = null;
  const MailView.scheduled() : kind = ViewKind.scheduled, category = null, accountId = null, path = null;
  const MailView.followUp() : kind = ViewKind.followUp, category = null, accountId = null, path = null;

  final ViewKind kind;
  final MailCategory? category;
  final String? accountId;
  final String? path;

  /// Views built from every account's inbox.
  bool get isInboxBased =>
      kind == ViewKind.allInboxes ||
      kind == ViewKind.priority ||
      kind == ViewKind.needsReply ||
      kind == ViewKind.category ||
      kind == ViewKind.vip ||
      kind == ViewKind.snoozed;

  @override
  bool operator ==(Object other) =>
      other is MailView && other.kind == kind && other.category == category && other.accountId == accountId && other.path == path;
  @override
  int get hashCode => Object.hash(kind, category, accountId, path);
}

enum ConnectionStatus { none, connecting, connected, failed }

/// A short message for the UI, optionally with a button.
class Toast {
  const Toast(this.message, {this.action, this.onAction, this.duration = const Duration(seconds: 3)});
  final String message;
  final String? action;
  final VoidCallback? onAction;
  final Duration duration;
}

/// Everything needed to send (or re-open) one message.
class OutgoingMail {
  OutgoingMail({
    required this.from,
    required this.to,
    this.cc = '',
    this.bcc = '',
    required this.subject,
    required this.body,
    this.inReplyTo,
    this.files = const [],
    this.sendAt,
    this.followUpDays,
  });

  final AccountSession from;
  final String to, cc, bcc, subject, body;
  final MimeMessage? inReplyTo;
  final List<File> files;

  /// Send later at this time instead of now.
  final DateTime? sendAt;

  /// Remind me if nobody replies within this many days.
  final int? followUpDays;
}

/// One connected account: its server connection, folders and inbox.
class AccountSession {
  AccountSession(this.config);

  final AccountConfig config;
  MailService? service;
  ConnectionStatus status = ConnectionStatus.none;
  String? error;
  List<Mailbox> mailboxes = [];
  Mailbox? inbox;
  List<MimeMessage> inboxMessages = [];
  int inboxPage = 1;
  bool inboxHasMore = true;
  bool loading = false;
  TriageCache? triage;

  /// Semantic search index and its background connection.
  VectorIndex? vectors;
  MailService? indexService;
  bool indexing = false;

  String get id => config.id;
  bool get connected => status == ConnectionStatus.connected && service != null;
}

class AppState extends ChangeNotifier {
  AppState(this._store) : settings = _store.loadSettings() {
    sessions = [for (final a in _store.loadAccounts()) AccountSession(a)];
  }

  final SettingsStore _store;
  AppSettings settings;
  late List<AccountSession> sessions;

  List<AccountConfig> get accounts => [for (final s in sessions) s.config];

  /// One-off messages for the UI to show as toasts.
  final _toasts = StreamController<Toast>.broadcast();
  Stream<Toast> get toasts => _toasts.stream;
  void toast(String msg) => _toasts.add(Toast(msg));
  void showToast(Toast t) => _toasts.add(t);

  /// Sends the user cancelled with "Undo", to re-open in the composer.
  final _undone = StreamController<OutgoingMail>.broadcast();
  Stream<OutgoingMail> get undoneSends => _undone.stream;

  /// Local organization data (VIPs, reminders, scheduled mail, …).
  UserData userData = UserData.memory();
  ListFilter listFilter = ListFilter.all;

  // ------------------------------------------------------------------ AI

  AiProvider? _provider;
  EmailAi? _ai;
  List<String> availableModels = [];
  String? aiError;

  /// The AI features, or null if no model is available yet.
  EmailAi? get ai => _ai;
  bool get aiReady => _ai != null;

  Future<void> refreshAi() async {
    _provider?.close();
    _provider = OllamaProvider(baseUrl: settings.ollamaUrl);
    try {
      availableModels = await _provider!.listModels();
      aiError = availableModels.isEmpty ? 'Ollama is running but has no models. Run: ollama pull gemma4:12b' : null;
    } on AiException catch (e) {
      availableModels = [];
      aiError = e.message;
    }
    if (availableModels.isNotEmpty) {
      var fast = settings.fastModel;
      var writing = settings.writingModel;
      if (!availableModels.contains(fast) || !isChatModel(fast)) fast = _pickDefault(availableModels);
      if (!availableModels.contains(writing)) writing = fast;
      if (fast != settings.fastModel || writing != settings.writingModel) {
        settings = settings.copyWith(fastModel: fast, writingModel: writing);
        await _store.saveSettings(settings);
      }
    }
    _rebuildAi();
    notifyListeners();
  }

  /// Prefers a mid-sized model: capable enough to write well, small
  /// enough to stay responsive and leave memory for everything else.
  /// Models that can chat (not embedding or translation-only models).
  static bool isChatModel(String m) => !m.contains('embed') && !m.contains('translategemma') && !m.contains('bge-');

  static bool isEmbeddingModel(String m) => m.contains('embed') || m.contains('bge-');

  /// The embedding model in use: the chosen one if installed, otherwise the
  /// best installed one (embeddinggemma tested best for email search).
  String get embeddingModel {
    if (!settings.semanticSearch) return '';
    if (availableModels.contains(settings.embeddingModel)) return settings.embeddingModel;
    final installed = availableModels.where(isEmbeddingModel).toList();
    if (installed.isEmpty) return '';
    return installed.firstWhere((m) => m.contains('embeddinggemma'), orElse: () => installed.first);
  }

  /// The translation model in use ('' = the writing model).
  String get translationModel {
    if (settings.translationModel == 'auto' || settings.translationModel.isEmpty) {
      return availableModels.firstWhere((m) => m.startsWith('translategemma'), orElse: () => '');
    }
    return availableModels.contains(settings.translationModel) ? settings.translationModel : '';
  }

  static String _pickDefault(List<String> models) {
    double sizeOf(String name) {
      final m = RegExp(r'(\d+(?:\.\d+)?)b', caseSensitive: false).firstMatch(name.split(':').last);
      return m == null ? 8 : double.parse(m[1]!);
    }

    final chat = models.where(isChatModel).toList();
    if (chat.isEmpty) return models.first;
    chat.sort((a, b) => (sizeOf(a) - 12).abs().compareTo((sizeOf(b) - 12).abs()));
    return chat.first;
  }

  void _rebuildAi() {
    final p = _provider;
    final name = settings.userName.isNotEmpty
        ? settings.userName
        : sessions.map((s) => s.config.displayName).firstWhere((n) => n.isNotEmpty, orElse: () => '');
    _ai = (p == null || availableModels.isEmpty)
        ? null
        : EmailAi(
            provider: p,
            fastModel: settings.fastModel,
            writingModel: settings.writingModel,
            userName: name,
            styleNotes: settings.styleNotes,
            translationModel: translationModel,
            embeddingModel: embeddingModel,
          );
  }

  Future<void> updateSettings(AppSettings s) async {
    final urlChanged = s.ollamaUrl != settings.ollamaUrl;
    final oldEmbedding = embeddingModel;
    settings = s;
    await _store.saveSettings(s);
    if (urlChanged) {
      await refreshAi();
    } else {
      _rebuildAi();
      notifyListeners();
    }
    if (embeddingModel != oldEmbedding) {
      for (final x in sessions) {
        x.vectors = null;
      }
      unawaited(indexAll());
    }
  }

  // ------------------------------------------------------------------ accounts

  Timer? _refreshTimer;

  /// Which account and folder each loaded message came from.
  final _owner = Expando<AccountSession>('owner');
  final _box = Expando<Mailbox>('mailbox');

  void _tag(List<MimeMessage> msgs, AccountSession s, Mailbox box) {
    for (final m in msgs) {
      _owner[m] = s;
      _box[m] = box;
    }
  }

  AccountSession? sessionOf(MimeMessage m) => _owner[m];
  Mailbox? mailboxOf(MimeMessage m) => _box[m];
  int indexOf(AccountSession s) => sessions.indexOf(s);
  AccountSession? sessionById(String? id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  OAuthClient? oauthClientFor(AuthType type) => switch (type) {
        AuthType.google when settings.googleClientId.isNotEmpty =>
          OAuthClient.google(clientId: settings.googleClientId, clientSecret: settings.googleClientSecret),
        AuthType.microsoft when settings.microsoftClientId.isNotEmpty =>
          OAuthClient.microsoft(clientId: settings.microsoftClientId),
        _ => null,
      };

  Future<void> init() async {
    userData = await UserData.open();
    await refreshAi();
    _tickTimer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    await Future.wait([for (final s in sessions) _connect(s)]);
    _refreshTimer = Timer.periodic(const Duration(minutes: 3), (_) => refresh(quiet: true));
    if (settings.autoSort) unawaited(sortInboxes());
    unawaited(_tick());
    unawaited(indexAll());
  }

  Future<MailCredentials?> _credentialsFor(AccountConfig config) async {
    if (config.authType == AuthType.password) {
      final password = await _store.readPassword(config.id);
      return password == null ? null : PasswordCredentials(password);
    }
    final token = await _store.readToken(config.id);
    final client = oauthClientFor(config.authType);
    if (token == null) return null;
    if (client == null) {
      throw Exception('Set up the ${config.authType == AuthType.google ? 'Google' : 'Microsoft'} sign-in app in Settings first.');
    }
    return OAuthCredentials(token, client, onTokenRefreshed: (t) => _store.writeToken(config.id, t));
  }

  Future<void> _connect(AccountSession s) async {
    await s.service?.disconnect();
    s.service = null;
    s.status = ConnectionStatus.connecting;
    s.error = null;
    notifyListeners();
    try {
      final creds = await _credentialsFor(s.config);
      if (creds == null) throw Exception('No saved sign-in for ${s.config.email}. Remove and re-add the account.');
      final service = MailService(s.config, creds);
      await service.connect();
      s.service = service;
      s.triage ??= await TriageCache.open(s.id);
      s.mailboxes = await service.mailboxes();
      s.inbox = s.mailboxes.firstWhere((b) => b.isInbox, orElse: () => s.mailboxes.first);
      s.status = ConnectionStatus.connected;
      notifyListeners();
      await _loadInbox(s);
    } catch (e) {
      s.status = ConnectionStatus.failed;
      s.error = friendlyError(e);
      notifyListeners();
    }
  }

  Future<void> reconnect(AccountSession s) async {
    await _connect(s);
    if (settings.autoSort) unawaited(sortInboxes());
  }

  Future<void> _loadInbox(AccountSession s) async {
    final service = s.service;
    final box = s.inbox;
    if (service == null || box == null) return;
    s.loading = true;
    notifyListeners();
    try {
      final msgs = await service.fetchPage(box);
      _tag(msgs, s, box);
      s.inboxMessages = msgs;
      unawaited(_afterFetch(s, msgs));
      s.inboxPage = 1;
      s.inboxHasMore = msgs.length >= 40;
    } catch (e) {
      toast('${s.config.email}: ${friendlyError(e)}');
    } finally {
      s.loading = false;
      _mergedCache = null;
      notifyListeners();
    }
  }

  /// Checks credentials before saving a new account.
  static Future<String?> testAccount(AccountConfig config, MailCredentials creds) async {
    final service = MailService(config, creds);
    try {
      await service.connect();
      await service.mailboxes();
      return null;
    } catch (e) {
      return friendlyError(e);
    } finally {
      await service.disconnect();
    }
  }

  Future<void> addAccount(AccountConfig config, {String? password, OauthToken? token}) async {
    if (password != null) await _store.writePassword(config.id, password);
    if (token != null) await _store.writeToken(config.id, token);
    final existing = sessionById(config.id);
    if (existing != null) {
      await existing.service?.disconnect();
      sessions.remove(existing);
    }
    final s = AccountSession(config);
    sessions = [...sessions, s];
    await _store.saveAccounts(accounts);
    _rebuildAi();
    notifyListeners();
    await _connect(s);
    _refreshTimer ??= Timer.periodic(const Duration(minutes: 3), (_) => refresh(quiet: true));
    if (settings.autoSort) unawaited(sortInboxes());
    unawaited(indexAll());
  }

  Future<void> removeAccount(AccountConfig config) async {
    final s = sessionById(config.id);
    await _store.deletePassword(config.id);
    await s?.service?.disconnect();
    await s?.triage?.clear();
    await s?.indexService?.disconnect();
    await (s?.vectors ?? await VectorIndex.open(config.id, '')).delete();
    sessions = sessions.where((x) => x.id != config.id).toList();
    await _store.saveAccounts(accounts);
    if (view.accountId == config.id) view = const MailView.allInboxes();
    if (selected != null && sessionOf(selected!) == s) selected = null;
    searchResults.removeWhere((m) => sessionOf(m) == s);
    _mergedCache = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ views

  MailView view = const MailView.allInboxes();
  MimeMessage? selected;
  bool loadingSelected = false;

  AccountSession? folderSession;
  Mailbox? folderBox;
  List<MimeMessage> folderMessages = [];
  int _folderPage = 1;
  bool folderHasMore = false;
  bool folderLoading = false;

  bool get loadingMessages =>
      view.kind == ViewKind.folder ? folderLoading : sessions.any((s) => s.loading);

  bool get anyConnecting => sessions.any((s) => s.status == ConnectionStatus.connecting);

  List<MimeMessage>? _mergedCache;

  /// Every account's inbox, newest first.
  List<MimeMessage> get allInboxMessages {
    return _mergedCache ??= [for (final s in sessions) ...s.inboxMessages]
      ..sort((a, b) => _sortDate(b).compareTo(_sortDate(a)));
  }

  /// A message whose reminder has come up sorts as if it just arrived.
  DateTime _sortDate(MimeMessage m) {
    final z = snoozeOf(m);
    final d = MailService.dateOf(m) ?? DateTime(0);
    return z != null && z.isDue && z.until.isAfter(d) ? z.until : d;
  }

  Snooze? snoozeOf(MimeMessage m) {
    if (userData.snoozes.isEmpty) return null;
    final box = _box[m];
    return userData.snoozes[MailService.keyOf(m, box?.path ?? '')];
  }

  bool isVipMessage(MimeMessage m) {
    final f = MailService.senderOf(m)?.email;
    return f != null && userData.isVip(f);
  }

  /// Hidden from inbox views: snoozed (until due), blocked, muted.
  bool _hiddenFromInbox(MimeMessage m) {
    final z = snoozeOf(m);
    if (z != null && !z.isDue) return true;
    final f = MailService.senderOf(m)?.email;
    if (f != null && userData.isBlocked(f)) return true;
    if (userData.mutedThreads.isNotEmpty && userData.mutedThreads.contains(MailService.threadKeyOf(m))) return true;
    return false;
  }

  List<MimeMessage> get _inbox => allInboxMessages.where((m) => !_hiddenFromInbox(m)).toList();

  bool _passesFilter(MimeMessage m) => switch (listFilter) {
        ListFilter.all => true,
        ListFilter.unread => !m.isSeen,
        ListFilter.flagged => m.isFlagged,
        ListFilter.attachments => m.hasAttachments(),
      };

  void setFilter(ListFilter f) {
    listFilter = f;
    notifyListeners();
  }

  void setView(MailView v) {
    view = v;
    selected = null;
    if (v.kind != ViewKind.search) _clearSearch();
    notifyListeners();
  }

  Future<void> openFolder(AccountSession s, Mailbox box) async {
    if (box.isInbox) {
      // An account's inbox is already loaded; show just that account's part.
      folderSession = s;
      folderBox = box;
      folderMessages = s.inboxMessages;
      folderHasMore = s.inboxHasMore;
      setView(MailView.folder(s.id, box.path));
      return;
    }
    final service = s.service;
    if (service == null) return;
    folderSession = s;
    folderBox = box;
    folderMessages = [];
    _folderPage = 1;
    folderHasMore = false;
    folderLoading = true;
    setView(MailView.folder(s.id, box.path));
    try {
      final msgs = await service.fetchPage(box);
      if (folderBox != box) return;
      _tag(msgs, s, box);
      folderMessages = msgs;
      folderHasMore = msgs.length >= 40;
    } catch (e) {
      toast('Could not load ${box.name}: ${friendlyError(e)}');
    } finally {
      folderLoading = false;
      notifyListeners();
    }
  }

  /// Messages for the current view.
  List<MimeMessage> get visibleMessages {
    final all = _viewMessages(view);
    return listFilter == ListFilter.all || view.kind == ViewKind.search ? all : all.where(_passesFilter).toList();
  }

  List<MimeMessage> _viewMessages(MailView view) {
    switch (view.kind) {
      case ViewKind.allInboxes:
        return _inbox;
      case ViewKind.folder:
        return folderBox?.isInbox == true ? folderMessages.where((m) => !_hiddenFromInbox(m)).toList() : folderMessages;
      case ViewKind.search:
        return searchResults;
      case ViewKind.priority:
        return _inbox.where((m) => triageOf(m)?.priority == MailPriority.high || isVipMessage(m)).toList();
      case ViewKind.needsReply:
        return _inbox.where((m) => triageOf(m)?.needsReply == true && !m.isAnswered).toList();
      case ViewKind.category:
        return _inbox.where((m) => triageOf(m)?.category == view.category).toList();
      case ViewKind.vip:
        return _inbox.where(isVipMessage).toList();
      case ViewKind.snoozed:
        return allInboxMessages.where((m) => snoozeOf(m)?.isDue == false).toList();
      case ViewKind.scheduled:
      case ViewKind.followUp:
        return const [];
    }
  }

  /// Unread count for a sidebar entry.
  int unreadFor(MailView v) {
    switch (v.kind) {
      case ViewKind.folder:
        final s = sessionById(v.accountId);
        return s != null && s.inbox?.path == v.path ? s.inboxMessages.where((m) => !m.isSeen && !_hiddenFromInbox(m)).length : 0;
      case ViewKind.search:
        return 0;
      case ViewKind.snoozed:
        return _viewMessages(v).length;
      case ViewKind.scheduled:
        return userData.scheduled.length;
      case ViewKind.followUp:
        return dueFollowUps.length;
      default:
        return _viewMessages(v).where((m) => !m.isSeen).length;
    }
  }

  bool get canLoadMore => switch (view.kind) {
        ViewKind.folder => folderHasMore,
        ViewKind.search => false,
        _ => sessions.any((s) => s.connected && s.inboxHasMore),
      };

  Future<void> loadMore() async {
    if (loadingMessages) return;
    if (view.kind == ViewKind.folder) {
      final s = folderSession;
      final box = folderBox;
      if (s?.service == null || box == null || !folderHasMore) return;
      if (box.isInbox) {
        await _loadMoreInbox(s!);
        folderMessages = s.inboxMessages;
        folderHasMore = s.inboxHasMore;
        notifyListeners();
        return;
      }
      folderLoading = true;
      notifyListeners();
      try {
        final more = await s!.service!.fetchPage(box, page: _folderPage + 1);
        if (folderBox != box) return;
        _folderPage++;
        _tag(more, s, box);
        final known = folderMessages.map((m) => m.uid).toSet();
        folderMessages = [...folderMessages, ...more.where((m) => !known.contains(m.uid))];
        folderHasMore = more.length >= 40;
      } catch (e) {
        toast('Could not load more: ${friendlyError(e)}');
      } finally {
        folderLoading = false;
        notifyListeners();
      }
      return;
    }
    await Future.wait([for (final s in sessions) if (s.connected && s.inboxHasMore) _loadMoreInbox(s)]);
    if (settings.autoSort) unawaited(sortInboxes());
  }

  Future<void> _loadMoreInbox(AccountSession s) async {
    final box = s.inbox;
    if (box == null || s.loading) return;
    s.loading = true;
    notifyListeners();
    try {
      final more = await s.service!.fetchPage(box, page: s.inboxPage + 1);
      s.inboxPage++;
      _tag(more, s, box);
      final known = s.inboxMessages.map((m) => m.uid).toSet();
      s.inboxMessages = [...s.inboxMessages, ...more.where((m) => !known.contains(m.uid))];
      s.inboxHasMore = more.length >= 40;
    } catch (e) {
      toast('${s.config.email}: ${friendlyError(e)}');
    } finally {
      s.loading = false;
      _mergedCache = null;
      notifyListeners();
    }
  }

  /// Fetches the newest mail and merges anything new at the top.
  Future<void> refresh({bool quiet = false}) async {
    if (view.kind == ViewKind.folder && folderBox != null && !folderBox!.isInbox && !quiet) {
      await openFolder(folderSession!, folderBox!);
      return;
    }
    var gotNew = false;
    await Future.wait([
      for (final s in sessions)
        if (s.status == ConnectionStatus.failed && quiet)
          _connect(s) // retry broken accounts in the background
        else if (s.connected && !s.loading)
          () async {
            try {
              final latest = await s.service!.fetchPage(s.inbox!);
              _tag(latest, s, s.inbox!);
              final known = s.inboxMessages.map((m) => m.uid).toSet();
              final fresh = latest.where((m) => !known.contains(m.uid)).toList();
              if (fresh.isNotEmpty) {
                s.inboxMessages = [...fresh, ...s.inboxMessages];
                gotNew = true;
                unawaited(_afterFetch(s, fresh));
              }
            } catch (e) {
              if (!quiet) toast('${s.config.email}: ${friendlyError(e)}');
            }
          }(),
    ]);
    _mergedCache = null;
    if (view.kind == ViewKind.folder && folderBox?.isInbox == true) {
      folderMessages = folderSession!.inboxMessages;
    }
    notifyListeners();
    if (gotNew && settings.autoSort) unawaited(sortInboxes());
    if (gotNew) unawaited(indexAll());
  }

  Triage? triageOf(MimeMessage m) {
    final s = _owner[m];
    final box = _box[m];
    if (s == null || box == null) return null;
    return s.triage?[MailService.keyOf(m, box.path)];
  }

  EmailContent contentOf(MimeMessage m) => MailService.toContent(m, _box[m]?.path ?? '');

  Future<void> openMessage(MimeMessage m) async {
    final s = _owner[m];
    final box = _box[m];
    final service = s?.service;
    selected = m;
    notifyListeners();
    if (service == null || box == null) return;
    if (!MailService.hasBody(m)) {
      loadingSelected = true;
      notifyListeners();
      try {
        final full = await service.ensureFull(box, m);
        _owner[full] = s;
        _box[full] = box;
        _replaceMessage(m, full);
        if (selected == m) selected = full;
      } catch (e) {
        toast('Could not open message: ${friendlyError(e)}');
      } finally {
        loadingSelected = false;
        notifyListeners();
      }
    }
    final current = selected;
    if (current != null && !current.isSeen) {
      try {
        await service.setSeen(box, current, true);
        notifyListeners();
      } catch (_) {}
    }
  }

  void _replaceMessage(MimeMessage old, MimeMessage updated) {
    for (final list in [folderMessages, searchResults, for (final s in sessions) s.inboxMessages]) {
      final i = list.indexOf(old);
      if (i >= 0) list[i] = updated;
    }
    _mergedCache = null;
  }

  Future<void> toggleRead(MimeMessage m) => _act(m, (svc, box) => svc.setSeen(box, m, !m.isSeen));
  Future<void> toggleFlag(MimeMessage m) => _act(m, (svc, box) => svc.setFlagged(box, m, !m.isFlagged));
  Future<void> deleteMessage(MimeMessage m) =>
      _act(m, (svc, box) => svc.delete(box, m), removes: true, done: 'Moved to Trash');
  Future<void> archiveMessage(MimeMessage m) =>
      _act(m, (svc, box) => svc.archive(box, m), removes: true, done: 'Archived');
  Future<void> junkMessage(MimeMessage m) =>
      _act(m, (svc, box) => svc.junk(box, m), removes: true, done: 'Moved to Junk');
  Future<void> moveMessage(MimeMessage m, Mailbox target) =>
      _act(m, (svc, box) => svc.moveTo(box, m, target), removes: true, done: 'Moved to ${target.name}');

  Future<void> _act(MimeMessage m, Future<void> Function(MailService svc, Mailbox box) action,
      {bool removes = false, String? done}) async {
    final s = _owner[m];
    final box = _box[m];
    if (s?.service == null || box == null) return;
    try {
      final before = visibleMessages;
      final idx = before.indexOf(m);
      await action(s!.service!, box);
      if (removes) {
        for (final list in [folderMessages, searchResults, for (final x in sessions) x.inboxMessages]) {
          list.remove(m);
        }
        _mergedCache = null;
        if (selected == m) {
          final next = visibleMessages;
          selected = next.isEmpty ? null : next[idx.clamp(0, next.length - 1)];
          if (selected != null) unawaited(openMessage(selected!));
        }
      }
      if (done != null) toast(done);
    } catch (e) {
      toast(friendlyError(e));
    }
    notifyListeners();
  }

  /// The account a new message should come from by default.
  AccountSession? get defaultSendingSession =>
      (view.kind == ViewKind.folder ? folderSession : null) ??
      sessions.where((s) => s.connected).firstOrNull ??
      sessions.firstOrNull;

  // ------------------------------------------------------------ sending

  final _pendingSends = <OutgoingMail, Timer>{};

  /// Sends [mail]: later if it has a send time, otherwise after the
  /// "Undo send" delay. Returns once it is queued; problems arrive as toasts.
  Future<void> sendMail(OutgoingMail mail) async {
    if (mail.sendAt != null) {
      await _schedule(mail);
      return;
    }
    final delay = settings.undoSendSeconds;
    if (delay <= 0) {
      await _deliver(mail);
      return;
    }
    _pendingSends[mail] = Timer(Duration(seconds: delay), () {
      _pendingSends.remove(mail);
      _deliver(mail);
    });
    showToast(Toast(
      'Sending in $delay seconds…',
      action: 'Undo',
      duration: Duration(seconds: delay),
      onAction: () {
        final t = _pendingSends.remove(mail);
        if (t == null) return;
        t.cancel();
        _undone.add(mail);
      },
    ));
  }

  Future<void> _deliver(OutgoingMail mail) async {
    final service = mail.from.service;
    try {
      if (service == null) throw Exception('${mail.from.config.email} is not connected.');
      final message = service.build(
        to: MailService.parseAddresses(mail.to),
        cc: MailService.parseAddresses(mail.cc),
        bcc: MailService.parseAddresses(mail.bcc),
        subject: mail.subject,
        markdownBody: mail.body,
        inReplyTo: mail.inReplyTo,
        files: mail.files,
      );
      final r = mail.inReplyTo;
      await service.sendBuilt(message, inReplyTo: r, inReplyToBox: r == null ? null : _box[r]);
      _afterSent(mail.from, message, mail.followUpDays);
      toast('Message sent');
    } catch (e) {
      showToast(Toast(
        'Could not send "${mail.subject}": ${friendlyError(e)}',
        action: 'Open',
        duration: const Duration(seconds: 10),
        onAction: () => _undone.add(mail),
      ));
    }
    notifyListeners();
  }

  void _afterSent(AccountSession from, MimeMessage message, int? followUpDays) {
    for (final a in [...?message.to, ...?message.cc, ...?message.bcc]) {
      userData.noteContact(a.email, a.personalName, weight: 5);
    }
    final id = message.getHeaderValue('message-id');
    if (followUpDays != null && id != null) {
      userData.followUps.add(FollowUp(
        messageId: id.trim(),
        accountId: from.id,
        subject: MailService.subjectOf(message),
        to: MailService.displayList(message.to),
        due: DateTime.now().add(Duration(days: followUpDays)),
      ));
    }
    unawaited(userData.save());
  }

  Future<void> _schedule(OutgoingMail mail) async {
    // Copy attachments so they still exist when it is time to send.
    final dir = await getApplicationSupportDirectory();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final paths = <String>[];
    for (final f in mail.files) {
      final dest = File('${dir.path}/outbox/$id/${f.uri.pathSegments.last}');
      await dest.parent.create(recursive: true);
      await f.copy(dest.path);
      paths.add(dest.path);
    }
    final r = mail.inReplyTo;
    userData.scheduled.add(ScheduledMail(
      id: id,
      accountId: mail.from.id,
      sendAt: mail.sendAt!,
      to: mail.to,
      cc: mail.cc,
      bcc: mail.bcc,
      subject: mail.subject,
      body: mail.body,
      inReplyToId: r?.getHeaderValue('message-id')?.trim(),
      references: r?.getHeaderValue('references')?.trim(),
      attachmentPaths: paths,
    ));
    userData.scheduled.sort((a, b) => a.sendAt.compareTo(b.sendAt));
    await userData.save();
    toast('Scheduled. It will be sent while Lumen Mail is open on this computer.');
    notifyListeners();
  }

  Future<void> cancelScheduled(ScheduledMail m) async {
    userData.scheduled.removeWhere((x) => x.id == m.id);
    await userData.save();
    for (final p in m.attachmentPaths) {
      try {
        await File(p).delete();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> sendScheduledNow(ScheduledMail m) => _sendScheduled(m);

  Future<void> _sendScheduled(ScheduledMail m) async {
    final s = sessionById(m.accountId);
    final service = s?.service;
    if (s == null || service == null) return; // try again on the next tick
    userData.scheduled.removeWhere((x) => x.id == m.id);
    await userData.save();
    try {
      final message = service.build(
        to: MailService.parseAddresses(m.to),
        cc: MailService.parseAddresses(m.cc),
        bcc: MailService.parseAddresses(m.bcc),
        subject: m.subject,
        markdownBody: m.body,
        inReplyToId: m.inReplyToId,
        references: m.references,
        files: [for (final p in m.attachmentPaths) if (File(p).existsSync()) File(p)],
      );
      await service.sendBuilt(message);
      _afterSent(s, message, null);
      toast('Scheduled message "${m.subject}" sent');
      for (final p in m.attachmentPaths) {
        try {
          await File(p).delete();
        } catch (_) {}
      }
    } catch (e) {
      // Put it back so nothing is lost; it is retried on the next tick.
      userData.scheduled.add(m);
      await userData.save();
      toast('Could not send scheduled "${m.subject}": ${friendlyError(e)}');
    }
    notifyListeners();
  }

  Future<void> saveDraft(OutgoingMail mail) async {
    final service = mail.from.service;
    if (service == null) throw Exception('${mail.from.config.email} is not connected.');
    final message = service.build(
      to: mail.to.trim().isEmpty ? const [] : MailService.parseAddresses(mail.to),
      cc: mail.cc.trim().isEmpty ? const [] : MailService.parseAddresses(mail.cc),
      bcc: mail.bcc.trim().isEmpty ? const [] : MailService.parseAddresses(mail.bcc),
      subject: mail.subject,
      markdownBody: mail.body,
      inReplyTo: mail.inReplyTo,
      files: mail.files,
    );
    await service.saveDraft(message);
    toast('Draft saved to ${mail.from.config.email}');
  }

  // ------------------------------------------------------------ timers

  Timer? _tickTimer;
  bool _ticking = false;

  /// Every 30 seconds: send scheduled mail, bring back reminders, and check
  /// follow-ups.
  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final now = DateTime.now();
      for (final m in [...userData.scheduled]) {
        if (!m.sendAt.isAfter(now)) await _sendScheduled(m);
      }
      var changed = false;
      for (final z in [...userData.snoozes.values]) {
        if (!z.isDue || _remindedKeys.contains(z.key)) continue;
        _remindedKeys.add(z.key);
        await _bringBack(z);
        changed = true;
      }
      // A follow-up is done once a reply arrives.
      final before = userData.followUps.length;
      userData.followUps.removeWhere((f) => allInboxMessages.any((m) {
            final refs = '${m.getHeaderValue('in-reply-to') ?? ''} ${m.getHeaderValue('references') ?? ''}';
            return refs.contains(f.messageId);
          }));
      if (userData.followUps.length != before) {
        changed = true;
        await userData.save();
      }
      if (changed) {
        _mergedCache = null;
        notifyListeners();
      }
    } finally {
      _ticking = false;
    }
  }

  final _remindedKeys = <String>{};

  /// A reminder is due: make sure the message is in the inbox list, unread
  /// and on top.
  Future<void> _bringBack(Snooze z) async {
    final s = sessionById(z.accountId);
    if (s == null) return;
    final loaded = s.inboxMessages.where((m) => MailService.keyOf(m, s.inbox?.path ?? '') == z.key).firstOrNull;
    var m = loaded;
    if (m == null && s.service != null && z.uid > 0) {
      final box = s.mailboxes.where((b) => b.path == z.path).firstOrNull;
      if (box != null) {
        try {
          final found = await s.service!.fetchByUids(box, [z.uid]);
          if (found.isNotEmpty) {
            m = found.first;
            _tag([m], s, box);
            if (box.isInbox) s.inboxMessages = [m, ...s.inboxMessages];
          }
        } catch (_) {}
      }
    }
    if (m != null && m.isSeen) {
      final box = _box[m];
      if (box != null) {
        try {
          await s.service?.setSeen(box, m, false);
        } catch (_) {}
      }
    }
    showToast(Toast('Reminder: ${z.subject}', duration: const Duration(seconds: 6)));
  }

  // ------------------------------------------------------------ organizing

  Future<void> snooze(MimeMessage m, DateTime until) async {
    final s = _owner[m];
    final box = _box[m];
    if (s == null || box == null) return;
    final key = MailService.keyOf(m, box.path);
    userData.snoozes[key] = Snooze(
      key: key,
      accountId: s.id,
      until: until,
      subject: MailService.subjectOf(m),
      path: box.path,
      uid: m.uid ?? 0,
    );
    _remindedKeys.remove(key);
    await userData.save();
    if (selected == m) selected = null;
    _mergedCache = null;
    toast('I\'ll remind you ${_friendlyWhen(until)}');
    notifyListeners();
  }

  Future<void> unsnooze(MimeMessage m) async {
    final z = snoozeOf(m);
    if (z == null) return;
    userData.snoozes.remove(z.key);
    await userData.save();
    _mergedCache = null;
    notifyListeners();
  }

  static String _friendlyWhen(DateTime d) {
    final now = DateTime.now();
    final day = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    final time = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (day == 0) return 'today at $time';
    if (day == 1) return 'tomorrow at $time';
    return 'on ${d.day}/${d.month} at $time';
  }

  Future<void> toggleVip(String email) async {
    final e = email.toLowerCase();
    userData.vips.contains(e) ? userData.vips.remove(e) : userData.vips.add(e);
    await userData.save();
    toast(userData.vips.contains(e) ? '$email is now a VIP' : '$email is no longer a VIP');
    notifyListeners();
  }

  /// Blocks a sender: their mail goes to Junk, now and in future.
  Future<void> blockSender(String email) async {
    userData.blocked.add(email.toLowerCase());
    await userData.save();
    for (final s in sessions) {
      await _applyRules(s, s.inboxMessages);
    }
    toast('Blocked $email. Their mail now goes to Junk.');
    notifyListeners();
  }

  Future<void> unblock(String entry) async {
    userData.blocked.remove(entry);
    await userData.save();
    _mergedCache = null;
    notifyListeners();
  }

  /// Mutes a conversation: new replies are archived and marked read.
  Future<void> muteThread(MimeMessage m) async {
    final key = MailService.threadKeyOf(m);
    if (userData.mutedThreads.remove(key)) {
      toast('Conversation unmuted');
    } else {
      userData.mutedThreads.add(key);
      toast('Conversation muted. New replies are archived automatically.');
      final s = _owner[m];
      if (s != null) await _applyRules(s, s.inboxMessages);
    }
    await userData.save();
    _mergedCache = null;
    notifyListeners();
  }

  bool isMuted(MimeMessage m) => userData.mutedThreads.contains(MailService.threadKeyOf(m));

  /// Learns contacts and applies block/mute rules to freshly fetched mail.
  Future<void> _afterFetch(AccountSession s, List<MimeMessage> msgs) async {
    var learned = false;
    for (final m in msgs) {
      final f = MailService.senderOf(m);
      if (f != null && userData.noteContact(f.email, f.personalName)) learned = true;
    }
    if (learned) unawaited(userData.save());
    await _applyRules(s, msgs);
    await _indexMessages(s, msgs, s.inbox);
  }

  Future<void> _applyRules(AccountSession s, List<MimeMessage> msgs) async {
    final service = s.service;
    final inbox = s.inbox;
    if (service == null || inbox == null) return;
    var moved = false;
    for (final m in [...msgs]) {
      if (_box[m]?.path != inbox.path) continue;
      final from = MailService.senderOf(m)?.email;
      try {
        if (from != null && userData.isBlocked(from)) {
          await service.junk(inbox, m);
          s.inboxMessages.remove(m);
          moved = true;
        } else if (userData.mutedThreads.contains(MailService.threadKeyOf(m)) && !m.isFlagged) {
          if (!m.isSeen) await service.setSeen(inbox, m, true);
          await service.archive(inbox, m);
          s.inboxMessages.remove(m);
          moved = true;
        }
      } catch (_) {
        // Hidden from view anyway; retried on the next fetch.
      }
    }
    if (moved) {
      _mergedCache = null;
      notifyListeners();
    }
  }

  Future<void> markAllRead() async {
    final targets = visibleMessages.where((m) => !m.isSeen).toList();
    for (final m in targets) {
      final s = _owner[m];
      final box = _box[m];
      if (s?.service == null || box == null) continue;
      try {
        await s!.service!.setSeen(box, m, true);
      } catch (_) {}
    }
    notifyListeners();
  }

  List<FollowUp> get dueFollowUps =>
      userData.followUps.where((f) => !f.due.isAfter(DateTime.now())).toList()..sort((a, b) => a.due.compareTo(b.due));

  Future<void> dismissFollowUp(FollowUp f) async {
    userData.followUps.remove(f);
    await userData.save();
    notifyListeners();
  }

  /// Leaves a mailing list: one-click when the sender supports it (RFC 8058),
  /// otherwise by email or by opening their unsubscribe page.
  Future<String> unsubscribe(MimeMessage m) async {
    final u = MailService.unsubscribeOf(m);
    if (u == null) return 'This email has no unsubscribe option.';
    if (u.oneClick && u.web != null) {
      final res = await http.post(u.web!,
          headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: 'List-Unsubscribe=One-Click');
      if (res.statusCode < 400) return 'Unsubscribed. It can take a few days for the emails to stop.';
    }
    if (u.mail != null) {
      final s = _owner[m];
      final service = s?.service;
      if (service != null) {
        final to = MailAddress(null, u.mail!.path);
        final subject = u.mail!.queryParameters['subject'] ?? 'unsubscribe';
        await service.sendBuilt(service.build(to: [to], subject: subject, markdownBody: u.mail!.queryParameters['body'] ?? 'unsubscribe'));
        return 'Unsubscribe request sent by email.';
      }
    }
    if (u.web != null) {
      await launchUrl(u.web!, mode: LaunchMode.externalApplication);
      return 'Opened the sender\'s unsubscribe page in your browser.';
    }
    return 'Could not unsubscribe automatically.';
  }

  // ------------------------------------------------------------ attachments

  /// Downloads an attachment. With [open], opens it in its default app;
  /// otherwise saves it to Downloads. Returns the file.
  Future<File> saveAttachment(MimeMessage m, ContentInfo info, {bool open = false}) async {
    final s = _owner[m];
    final box = _box[m];
    if (s?.service == null || box == null) throw Exception('Not connected.');
    final part = await s!.service!.fetchPart(box, m, info.fetchId);
    final bytes = part.decodeContentBinary();
    if (bytes == null) throw Exception('The attachment is empty.');
    final name = (info.fileName ?? 'attachment').replaceAll(RegExp(r'[/\\:]'), '_');
    final Directory dir;
    if (open) {
      dir = Directory('${(await getTemporaryDirectory()).path}/attachments/${DateTime.now().millisecondsSinceEpoch}');
    } else {
      dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    }
    await dir.create(recursive: true);
    var file = File('${dir.path}/$name');
    if (!open) {
      var i = 1;
      final dot = name.lastIndexOf('.');
      while (await file.exists()) {
        final stem = dot > 0 ? name.substring(0, dot) : name;
        final ext = dot > 0 ? name.substring(dot) : '';
        file = File('${dir.path}/$stem ($i)$ext');
        i++;
      }
    }
    await file.writeAsBytes(bytes);
    if (open) await launchUrl(Uri.file(file.path));
    return file;
  }

  /// Saves all of [m]'s attachments to temporary files (for forwarding).
  Future<List<File>> attachmentFiles(MimeMessage m) async {
    final out = <File>[];
    for (final info in m.findContentInfo(disposition: ContentDisposition.attachment)) {
      final s = _owner[m];
      final box = _box[m];
      if (s?.service == null || box == null) break;
      final part = await s!.service!.fetchPart(box, m, info.fetchId);
      final bytes = part.decodeContentBinary();
      if (bytes == null) continue;
      final dir = Directory('${(await getTemporaryDirectory()).path}/forward/${DateTime.now().microsecondsSinceEpoch}');
      await dir.create(recursive: true);
      final f = File('${dir.path}/${(info.fileName ?? 'attachment').replaceAll(RegExp(r'[/\\:]'), '_')}');
      await f.writeAsBytes(bytes);
      out.add(f);
    }
    return out;
  }

  /// Opens an .ics file for [event] in the Calendar app.
  Future<void> addToCalendar(EmailEvent event, MimeMessage m) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/events');
    await dir.create(recursive: true);
    final f = File('${dir.path}/event_${DateTime.now().millisecondsSinceEpoch}.ics');
    await f.writeAsString(event.toIcs(description: 'From email: ${MailService.subjectOf(m)}'));
    await launchUrl(Uri.file(f.path));
  }

  // ------------------------------------------------------------ semantic index

  bool _indexRunning = false;
  bool _indexAgain = false;

  /// Number of emails in the semantic index, across accounts.
  int get indexedCount => sessions.fold(0, (n, s) => n + (s.vectors?.length ?? 0));
  bool get indexing => sessions.any((s) => s.indexing);

  /// Indexes recent mail of every account for semantic search, on a separate
  /// connection so it never slows down what you are doing.
  Future<void> indexAll() async {
    if (embeddingModel.isEmpty || _provider == null) return;
    if (_indexRunning) {
      _indexAgain = true;
      return;
    }
    _indexRunning = true;
    try {
      for (final s in [...sessions]) {
        if (!s.connected) continue;
        await _indexAccount(s);
      }
    } finally {
      _indexRunning = false;
    }
    if (_indexAgain) {
      _indexAgain = false;
      unawaited(indexAll());
    }
  }

  Future<VectorIndex?> _vectorsFor(AccountSession s) async {
    final model = embeddingModel;
    if (model.isEmpty) return null;
    if (s.vectors?.model != model) s.vectors = await VectorIndex.open(s.id, model);
    return s.vectors;
  }

  /// Embeds the given (already downloaded) messages.
  Future<void> _indexMessages(AccountSession s, List<MimeMessage> msgs, Mailbox? box) async {
    final model = embeddingModel;
    final provider = _provider;
    if (box == null || provider == null || model.isEmpty) return;
    final index = await _vectorsFor(s);
    if (index == null) return;
    final todo = [for (final m in msgs) if (!index.contains(MailService.keyOf(m, box.path))) m];
    final fmt = EmbeddingFormat(model);
    for (var i = 0; i < todo.length; i += 16) {
      final chunk = todo.sublist(i, (i + 16).clamp(0, todo.length));
      final contents = [for (final m in chunk) MailService.toContent(m, box.path)];
      final vectors = await provider.embed([for (final c in contents) fmt.document(c)], model: model);
      for (var j = 0; j < chunk.length && j < vectors.length; j++) {
        index.add(
          IndexedMail(contents[j].id, box.path, chunk[j].uid ?? 0, contents[j].date ?? DateTime(1970)),
          vectors[j],
        );
      }
    }
    if (todo.isNotEmpty) {
      index.scheduleSave();
      notifyListeners();
    }
  }

  Future<void> _indexAccount(AccountSession s) async {
    final index = await _vectorsFor(s);
    if (index == null) return;
    final folders = <Mailbox>[
      ?s.service!.searchFolder(s.mailboxes),
      // Gmail's All Mail already contains sent mail.
      if (!s.config.isGmail) ?s.mailboxes.where((b) => b.isSent).firstOrNull,
    ];
    s.indexing = true;
    notifyListeners();
    try {
      final creds = await _credentialsFor(s.config);
      if (creds == null) return;
      final svc = s.indexService ??= MailService(s.config, creds);
      if (!svc.client.isConnected) await svc.connect();
      for (final box in folders) {
        var skip = 0;
        final depth = box.isSent ? settings.indexDepth ~/ 3 : settings.indexDepth;
        var unchangedPages = 0;
        while (skip < depth) {
          // Headers first (cheap), then full text only for what is new.
          final heads = await svc.fetchRange(box, skip: skip, count: 100, headersOnly: true);
          if (heads.isEmpty) break;
          skip += heads.length;
          final missing = [
            for (final m in heads)
              if (m.uid != null && !index.contains(MailService.keyOf(m, box.path))) m.uid!
          ];
          if (missing.isEmpty) {
            // Already indexed further down: stop after a few known pages.
            if (++unchangedPages >= 3) break;
            continue;
          }
          unchangedPages = 0;
          for (var i = 0; i < missing.length; i += 25) {
            final full = await svc.fetchByUids(box, missing.sublist(i, (i + 25).clamp(0, missing.length)));
            await _indexMessages(s, full, box);
          }
        }
      }
    } catch (e) {
      debugPrint('Indexing ${s.config.email} stopped: $e');
    } finally {
      s.indexing = false;
      await index.save();
      await s.indexService?.disconnect();
      s.indexService = null;
      notifyListeners();
    }
  }

  Future<void> rebuildIndex() async {
    for (final s in sessions) {
      await (s.vectors ?? await VectorIndex.open(s.id, embeddingModel)).delete();
      s.vectors = null;
    }
    notifyListeners();
    await indexAll();
  }

  /// Emails whose meaning matches [query], best first (across [targets]).
  Future<List<MimeMessage>> _semanticSearch(String query, List<(AccountSession, Mailbox)> targets, {bool folderOnly = false}) async {
    final model = embeddingModel;
    final provider = _provider;
    if (model.isEmpty || provider == null) return [];
    final List<double> q;
    try {
      q = (await provider.embed([EmbeddingFormat(model).query(query)], model: model)).first;
    } catch (_) {
      return [];
    }
    final scored = <(MimeMessage, double)>[];
    await Future.wait([
      for (final (s, scope) in targets)
        () async {
          final index = await _vectorsFor(s);
          if (index == null || index.length == 0 || s.service == null) return;
          // Measured with embeddinggemma: right answers score 0.25-0.7, unrelated
          // mail about 0.22 (tool/model_bench.dart).
          var hits = index.search(q, limit: 25, minScore: 0.25);
          if (folderOnly) hits = hits.where((h) => h.$1.path == scope.path).toList();
          final byPath = <String, List<(IndexedMail, double)>>{};
          for (final h in hits) {
            (byPath[h.$1.path] ??= []).add(h);
          }
          for (final MapEntry(key: path, value: list) in byPath.entries) {
            final box = s.mailboxes.where((b) => b.path == path).firstOrNull;
            if (box == null) continue;
            try {
              final msgs = await s.service!.fetchByUids(box, [for (final h in list) h.$1.uid]);
              _tag(msgs, s, box);
              final byKey = {for (final m in msgs) MailService.keyOf(m, path): m};
              for (final (mail, score) in list) {
                final m = byKey[mail.key];
                if (m == null) {
                  index.remove(mail.key); // deleted or moved since indexing
                } else {
                  scored.add((m, score));
                }
              }
            } catch (_) {}
          }
          index.scheduleSave();
        }(),
    ]);
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    _lastScores = {for (final (m, sc) in scored) m: sc};
    return [for (final (m, _) in scored) m];
  }

  Map<MimeMessage, double> _lastScores = {};

  // ------------------------------------------------------------ AI sorting

  bool sorting = false;
  int sortDone = 0;
  int sortTotal = 0;
  bool _resortRequested = false;

  /// Sorts any not-yet-sorted inbox messages across all accounts.
  Future<void> sortInboxes({bool force = false}) async {
    final ai = _ai;
    if (ai == null) return;
    if (sorting) {
      _resortRequested = true;
      return;
    }
    if (force) {
      for (final s in sessions) {
        await s.triage?.clear();
      }
    }
    final todo = <(AccountSession, EmailContent)>[];
    for (final s in sessions) {
      final cache = s.triage;
      final box = s.inbox;
      if (cache == null || box == null) continue;
      for (final m in s.inboxMessages) {
        final c = MailService.toContent(m, box.path);
        if (!cache.contains(c.id)) todo.add((s, c));
      }
    }
    if (todo.isEmpty) return;
    // Newest first, so what you see first gets sorted first.
    todo.sort((a, b) => (b.$2.date ?? DateTime(0)).compareTo(a.$2.date ?? DateTime(0)));
    sorting = true;
    sortDone = 0;
    sortTotal = todo.length;
    notifyListeners();
    try {
      const batch = 10;
      for (var i = 0; i < todo.length; i += batch) {
        final chunk = todo.sublist(i, (i + batch).clamp(0, todo.length));
        final result = await ai.triage([for (final t in chunk) t.$2]);
        for (final (s, c) in chunk) {
          final r = result[c.id];
          if (r != null) await s.triage!.putAll({c.id: r});
        }
        sortDone += chunk.length;
        notifyListeners();
      }
    } on AiException catch (e) {
      toast('AI sorting stopped: ${e.message}');
    } catch (e) {
      toast('AI sorting stopped: $e');
    } finally {
      sorting = false;
      notifyListeners();
    }
    if (_resortRequested) {
      _resortRequested = false;
      unawaited(sortInboxes());
    }
  }

  // ------------------------------------------------------------ search

  String searchQuery = '';
  bool searching = false;
  String searchStatus = '';
  SearchPlan? searchPlan;
  List<MimeMessage> searchResults = [];
  bool lastSearchWasAi = false;
  MailView _beforeSearch = const MailView.allInboxes();

  void _clearSearch() {
    searchQuery = '';
    searching = false;
    searchStatus = '';
    searchPlan = null;
    searchResults = [];
  }

  void clearSearch() {
    _clearSearch();
    if (view.kind == ViewKind.search) view = _beforeSearch;
    selected = null;
    notifyListeners();
  }

  /// Where to search: the open folder, or all mail in every account.
  List<(AccountSession, Mailbox)> _searchTargets() {
    final scope = view.kind == ViewKind.search ? _beforeSearch : view;
    if (scope.kind == ViewKind.folder && folderSession?.service != null && folderBox != null) {
      return [(folderSession!, folderBox!)];
    }
    return [
      for (final s in sessions)
        if (s.connected)
          if (s.service!.searchFolder(s.mailboxes) case final box?) (s, box)
    ];
  }

  String get searchScopeLabel {
    final t = _searchTargets();
    if (t.length == 1 && (view.kind == ViewKind.folder || _beforeSearch.kind == ViewKind.folder)) {
      return t.first.$2.isInbox ? 'Inbox' : t.first.$2.name;
    }
    return sessions.length > 1 ? 'all accounts' : 'all mail';
  }

  /// Plain keyword search, or AI search when [useAi] is true: the AI turns
  /// the question into filters, the servers search, then the AI ranks.
  Future<void> search(String query, {required bool useAi}) async {
    if (query.trim().isEmpty) return;
    final targets = _searchTargets();
    if (targets.isEmpty) return;
    final scope = searchScopeLabel;
    if (view.kind != ViewKind.search) _beforeSearch = view;
    searchQuery = query.trim();
    searching = true;
    lastSearchWasAi = useAi && _ai != null;
    searchResults = [];
    searchPlan = null;
    selected = null;
    view = const MailView.search();
    searchStatus = lastSearchWasAi ? 'Understanding your question…' : 'Searching $scope…';
    notifyListeners();

    Future<List<MimeMessage>> runAll(SearchPlan plan) async {
      final perAccount = await Future.wait([
        for (final (s, box) in targets)
          s.service!.search(box, plan, limit: 30).then((msgs) {
            _tag(msgs, s, box);
            return msgs;
          }).catchError((Object e) {
            toast('${s.config.email}: search failed (${friendlyError(e)})');
            return <MimeMessage>[];
          }),
      ]);
      return [for (final l in perAccount) ...l]
        ..sort((a, b) => (MailService.dateOf(b) ?? DateTime(0)).compareTo(MailService.dateOf(a) ?? DateTime(0)));
    }

    final folderOnly = (view.kind == ViewKind.search ? _beforeSearch : view).kind == ViewKind.folder ||
        _beforeSearch.kind == ViewKind.folder;
    // Meaning-based matches from the local index, found in parallel.
    final semanticF = _semanticSearch(searchQuery, targets, folderOnly: folderOnly);
    String keyOf(MimeMessage m) => MailService.keyOf(m, _box[m]?.path ?? '');

    try {
      if (!lastSearchWasAi) {
        final words = searchQuery.split(RegExp(r'\s+'));
        searchPlan = SearchPlan(keywords: words.length > 4 ? [searchQuery] : words);
        final exact = await runAll(searchPlan!);
        final seen = {for (final m in exact) keyOf(m)};
        // Keyword matches first, then closely related ones by meaning.
        final related = [
          for (final m in await semanticF)
            if ((_lastScores[m] ?? 0) >= 0.4 && seen.add(keyOf(m))) m
        ].take(10).toList();
        searchResults = [...exact, ...related];
        searchStatus = related.isEmpty
            ? '${exact.length} results in $scope'
            : '${exact.length} results in $scope, plus ${related.length} related';
      } else {
        final ai = _ai!;
        var plan = await ai.planSearch(searchQuery);
        searchPlan = plan;
        searchStatus = 'Searching $scope for ${plan.describe()}…';
        notifyListeners();
        var found = await runAll(plan);
        if (found.isEmpty && plan.keywords.isNotEmpty) {
          // Keywords may have been too narrow; widen and let the AI judge.
          plan = plan.withoutKeywords();
          if (!plan.isEmpty) found = await runAll(plan);
        }
        // Fuse with the meaning-based matches (reciprocal rank fusion), so
        // the AI ranks the best of both: exact words and similar meaning.
        final semantic = await semanticF;
        if (semantic.isNotEmpty) {
          final score = <String, double>{};
          final byKey = <String, MimeMessage>{};
          for (final list in [found, semantic]) {
            for (var i = 0; i < list.length; i++) {
              final k = keyOf(list[i]);
              byKey[k] ??= list[i];
              score[k] = (score[k] ?? 0) + 1 / (60 + i);
            }
          }
          found = [...byKey.keys.map((k) => byKey[k]!)]..sort((a, b) => score[keyOf(b)]!.compareTo(score[keyOf(a)]!));
        }
        if (found.isEmpty) {
          searchStatus = 'Nothing found in $scope for ${searchPlan!.describe()}.';
        } else {
          searchStatus = 'Ranking ${found.length} matches…';
          notifyListeners();
          final top = found.take(30).toList();
          final contents = [for (final m in top) contentOf(m)];
          final ranked = await ai.rankResults(searchQuery, contents);
          final byId = {for (var i = 0; i < contents.length; i++) contents[i].id: top[i]};
          final ordered = [for (final id in ranked) ?byId[id]];
          searchResults = ordered.isEmpty ? found : ordered;
          searchStatus = ordered.isEmpty
              ? '${found.length} results in $scope for ${searchPlan!.describe()}'
              : '${ordered.length} relevant results in $scope';
        }
      }
    } catch (e) {
      searchStatus = 'Search failed: ${friendlyError(e)}';
    } finally {
      searching = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------ misc

  static String friendlyError(Object e) {
    final s = e.toString();
    final lower = s.toLowerCase();
    if (e is OAuthException) return e.message;
    if (lower.contains('authenticationfailed') ||
        lower.contains('invalid credentials') ||
        lower.contains('login failed') ||
        lower.contains('authentication failed') ||
        lower.contains('authenticate failed') ||
        lower.contains('[auth')) {
      return 'Login failed. Check the email address and app password, or whether your provider allows IMAP.';
    }
    if (lower.contains('unable to refresh token') || lower.contains('invalid_grant')) {
      return 'Your sign-in expired. Remove the account and sign in again.';
    }
    if (lower.contains('failed host lookup') || lower.contains('nodename nor servname')) {
      return 'Could not reach the mail server. Check your internet connection.';
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return 'The mail server took too long to respond.';
    }
    if (lower.contains('operation not permitted')) {
      return 'macOS blocked the network connection (app sandbox).';
    }
    return s.replaceFirst(RegExp(r'^(Exception|MailException|ImapException):\s*'), '');
  }

  /// Loads sample data without a server, for UI tests and screenshots.
  @visibleForTesting
  void debugLoad({
    required List<({AccountConfig account, List<Mailbox> mailboxes, List<MimeMessage> messages, Map<String, Triage> triage})> data,
    EmailAi? ai,
    MimeMessage? selected,
  }) {
    sessions = [];
    for (final d in data) {
      final s = AccountSession(d.account)
        ..status = ConnectionStatus.connected
        ..mailboxes = d.mailboxes
        ..inbox = d.mailboxes.first
        ..inboxMessages = d.messages
        ..inboxHasMore = false
        ..triage = TriageCache.memory(d.triage);
      _tag(d.messages, s, s.inbox!);
      sessions.add(s);
    }
    _mergedCache = null;
    if (ai != null) {
      _ai = ai;
      availableModels = [ai.fastModel];
      aiError = null;
    }
    this.selected = selected;
    notifyListeners();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _tickTimer?.cancel();
    for (final t in _pendingSends.values) {
      t.cancel();
    }
    _undone.close();
    for (final s in sessions) {
      s.indexService?.disconnect();
      s.vectors?.save();
    }
    for (final s in sessions) {
      s.service?.disconnect();
    }
    _provider?.close();
    _toasts.close();
    super.dispose();
  }
}
