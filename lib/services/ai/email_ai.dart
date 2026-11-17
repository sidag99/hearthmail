import '../../models/email_content.dart';
import '../../models/search_plan.dart';
import '../../models/triage.dart';
import 'ai_provider.dart';

/// Ways the user can ask the AI to rework a draft.
enum RewriteStyle {
  improve('Improve', 'Improve clarity and flow while keeping the meaning, length and tone roughly the same.'),
  shorter('Shorter', 'Make it noticeably shorter and more direct. Keep every important point.'),
  longer('More detail', 'Expand it with a little more helpful detail and context. Do not invent facts.'),
  formal('Formal', 'Rewrite in a polished, professional, formal tone.'),
  friendly('Friendly', 'Rewrite in a warm, friendly, conversational tone.'),
  grammar('Fix grammar', 'Only fix spelling, grammar and punctuation. Change nothing else.'),
  format('Format', 'Restructure for easy reading: short paragraphs, and use "- " bullet lists or **bold** labels where they help (Markdown). Keep the wording mostly the same.');

  const RewriteStyle(this.label, this.instruction);
  final String label;
  final String instruction;
}

/// All the email-specific AI features, built on any [AiProvider].
///
/// Two models are used: a [fastModel] for quick structured jobs (sorting,
/// search, summaries, quick replies) and a [writingModel] for anything the
/// user will send (drafts, rewrites, digests).
class EmailAi {
  EmailAi({
    required this.provider,
    required this.fastModel,
    required this.writingModel,
    this.userName = '',
    this.styleNotes = '',
    this.translationModel = '',
    this.embeddingModel = '',
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// A dedicated translation model (e.g. translategemma); empty = use the
  /// writing model.
  final String translationModel;

  /// The model that turns emails into vectors for semantic search; empty =
  /// semantic search is off.
  final String embeddingModel;

  final AiProvider provider;
  final String fastModel;
  final String writingModel;
  final String userName;
  final String styleNotes;
  final DateTime Function() _now;

  String get _firstName => userName.trim().split(RegExp(r'\s+')).first;

  String get _writerRules => [
        'You write emails on behalf of the user${userName.isEmpty ? '' : ', $userName'}.',
        'Output ONLY the email body text: no subject line, no preamble such as "Here is a draft", no explanations, no code fences.',
        'Sound like a real person: natural, concise, specific. Avoid clichés like "I hope this email finds you well".',
        'Never invent facts, opinions, dates, numbers or commitments, and only say what the user asked to say. If something essential is unknown, leave a short placeholder in square brackets, e.g. [time].',
        if (_firstName.isNotEmpty)
          'End with a brief sign-off and the name "$_firstName".'
        else
          'End with a brief sign-off but no name.',
        'You may use light Markdown (**bold**, "- " bullets) only when it genuinely helps readability.',
        if (styleNotes.trim().isNotEmpty)
          'The user\'s personal writing style: ${styleNotes.trim()}',
      ].join('\n');

  // ---------------------------------------------------------------- reading

  /// Short summary with action items and dates, streamed as Markdown.
  Stream<String> summarize(EmailContent email) => provider.chat([
        const AiMessage.system(
            'You summarize emails for a busy person. Be accurate and brief. '
            'Use this Markdown format and omit any section that would be empty:\n'
            '**TL;DR:** one or two sentences.\n\n'
            '**Action items:**\n- ...\n\n'
            '**Key dates & numbers:**\n- ...\n\n'
            'No other text.'),
        AiMessage.user('Summarize this email:\n\n${email.forPrompt()}'),
      ], model: fastModel, temperature: 0.2);

  /// "Catch me up": a digest of many emails grouped by what needs attention.
  Stream<String> digest(List<EmailContent> emails) {
    final list = StringBuffer();
    for (var i = 0; i < emails.length; i++) {
      final e = emails[i];
      list.writeln('#${i + 1} | From: ${e.from} | Subject: ${e.subject}');
      list.writeln('   ${e.forPrompt(maxBodyChars: 700).split('\n').skip(4).join(' ').trim()}');
    }
    return provider.chat([
      const AiMessage.system(
          'You brief a busy person on their inbox. Group the emails into these Markdown sections, '
          'omitting empty ones:\n'
          '**Needs your attention** — replies, decisions, deadlines.\n'
          '**Worth knowing** — useful information.\n'
          '**Can skip** — promotions, newsletters, routine notifications (one line total, just senders).\n'
          'Under each, use "- " bullets of one short sentence that say who and what, and mention deadlines. '
          'Each email appears in exactly one section. Be concrete. No intro or outro.'),
      AiMessage.user('Today is ${_today()}. Here are my emails:\n\n$list'),
    ], model: writingModel, temperature: 0.3);
  }

  // ---------------------------------------------------------------- replying

  /// Three short one-tap reply options.
  Future<List<String>> quickReplies(EmailContent email) async {
    final json = await provider.completeJson([
      AiMessage.system(
          'Suggest exactly 3 distinct short replies the user could send to this email '
          '(for example: accept, decline/defer, ask a question). Each is 1-2 sentences, '
          'complete and ready to send, without greeting or sign-off. '
          'If the email is automated or needs no reply, still suggest 3 brief, sensible replies.'),
      AiMessage.user(email.forPrompt(maxBodyChars: 6000)),
    ], model: fastModel, schema: {
      'type': 'object',
      'properties': {
        'replies': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['replies'],
    }, temperature: 0.5);
    return [
      for (final r in (json['replies'] as List? ?? const []))
        if (r is String && r.trim().isNotEmpty) r.trim()
    ].take(3).toList();
  }

  /// Full reply draft. [instruction] is what the user wants to say, e.g.
  /// "yes but Thursday instead" — may be empty to let the AI decide.
  Stream<String> draftReply(EmailContent email, {String instruction = ''}) =>
      provider.chat([
        AiMessage.system(_writerRules),
        AiMessage.user(
            'Write my reply to the email below.\n'
            '${instruction.trim().isEmpty ? 'Reply appropriately and helpfully.' : 'What I want to say: ${instruction.trim()}'}\n'
            'Match the formality of the original. Greet the sender by first name if it is a person.\n\n'
            '--- Original email ---\n${email.forPrompt()}'),
      ], model: writingModel, temperature: 0.6);

  // ---------------------------------------------------------------- writing

  /// Turns rough notes or a request into a full email.
  Stream<String> compose(String notes, {String to = '', String subject = ''}) =>
      provider.chat([
        AiMessage.system(_writerRules),
        AiMessage.user('Write an email based on these notes.\n'
            '${to.trim().isEmpty ? '' : 'Recipient: $to\n'}'
            '${subject.trim().isEmpty ? '' : 'Subject: $subject\n'}'
            'Notes:\n${notes.trim()}'),
      ], model: writingModel, temperature: 0.6);

  /// Reworks an existing draft in the requested style.
  Stream<String> rewrite(String draft, RewriteStyle style) => provider.chat([
        AiMessage.system('You edit email drafts. ${style.instruction}\n'
            'Output ONLY the revised email text, with no commentary, preamble, subject line or code fences. '
            'Keep the existing greeting and sign-off; do not add a greeting, sign-off or [placeholders] that the draft does not have.'),
        AiMessage.user(draft),
      ], model: writingModel, temperature: style == RewriteStyle.grammar ? 0.1 : 0.5);

  /// Applies a free-form edit request, e.g. "mention the deadline is Friday".
  Stream<String> customEdit(String draft, String request) => provider.chat([
        AiMessage.system(
            'You edit email drafts exactly as the user asks. Output ONLY the full revised email, '
            'with no commentary, preamble or code fences.'),
        AiMessage.user('Edit request: $request\n\n--- Draft ---\n$draft'),
      ], model: writingModel, temperature: 0.5);

  Future<String> suggestSubject(String body) async {
    final s = await provider.complete([
      const AiMessage.system(
          'Write a clear, specific email subject line (max 8 words) for the email. '
          'Output only the subject text, no quotes, no "Subject:" prefix.'),
      AiMessage.user(body),
    ], model: fastModel, temperature: 0.3);
    return s.split('\n').first.replaceAll(RegExp(r'^(subject:\s*)|["“”]', caseSensitive: false), '').trim();
  }

  // ---------------------------------------------------------------- sorting

  /// Categorizes and prioritizes a batch of emails. Returns results keyed by
  /// [EmailContent.id]. Callers should batch ~10-15 emails per call.
  Future<Map<String, Triage>> triage(List<EmailContent> emails) async {
    if (emails.isEmpty) return {};
    final categories = MailCategory.values
        .map((c) => '- ${c.name}: ${c.description}')
        .join('\n');
    final list = StringBuffer();
    for (var i = 0; i < emails.length; i++) {
      final e = emails[i];
      list.writeln('[$i] From: ${e.from}\n    Subject: ${e.subject}\n    Preview: ${e.snippet}');
    }
    final json = await provider.completeJson([
      AiMessage.system(
          'You sort a person\'s inbox. For each email decide:\n'
          'category — one of:\n$categories\n'
          'priority — "high" only if it is from a real person or institution and needs action or attention soon '
          '(deadlines, direct questions, security problems, bills due); "low" for promotions, newsletters and routine notifications; otherwise "normal".\n'
          'needs_reply — true only if a human is personally waiting for the user to answer.\n'
          'suspicious — true only if it looks like phishing or a scam: urgent pressure to click a link, log in, pay, '
          'or share codes or passwords, especially when the sender address does not match the company it claims to be.\n'
          'Return one item per email using its [index] as "index".'),
      AiMessage.user(list.toString()),
    ], model: fastModel, schema: {
      'type': 'object',
      'properties': {
        'items': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'index': {'type': 'integer'},
              'category': {
                'type': 'string',
                'enum': [for (final c in MailCategory.values) c.name],
              },
              'priority': {
                'type': 'string',
                'enum': [for (final p in MailPriority.values) p.name],
              },
              'needs_reply': {'type': 'boolean'},
              'suspicious': {'type': 'boolean'},
            },
            'required': ['index', 'category', 'priority', 'needs_reply', 'suspicious'],
          },
        },
      },
      'required': ['items'],
    });
    final out = <String, Triage>{};
    for (final item in (json['items'] as List? ?? const [])) {
      if (item is! Map) continue;
      final idx = item['index'];
      if (idx is! int || idx < 0 || idx >= emails.length) continue;
      out[emails[idx].id] = Triage.fromJson(item.cast<String, dynamic>());
    }
    return out;
  }

  // ---------------------------------------------------------------- search

  /// Converts a natural-language question into structured search filters.
  Future<SearchPlan> planSearch(String query) async {
    final json = await provider.completeJson([
      AiMessage.system(
          'Convert the user\'s request into email search filters. Today is ${_today()} (${_weekday()}).\n'
          '- keywords: 1-4 short words likely to appear in matching emails. Include useful synonyms '
          '(e.g. "invoice", "receipt"). Do NOT include sender names, dates or filler words. Empty if the request is only about sender/date.\n'
          '- from: who SENT the email (e.g. "bills from chase" -> from "chase"). to: only if the user says who they sent it to. A name, address or domain fragment; prefer one distinctive word (e.g. "amazon", "sarah").\n'
          '- subject: only if the user quotes a subject.\n'
          '- since / before: ISO dates (YYYY-MM-DD) only if the request implies a time range; "before" is exclusive.\n'
          '- unread_only, flagged_only, has_attachment: true only if asked.\n'
          'Use empty strings for unused text fields.'),
      AiMessage.user(query),
    ], model: fastModel, schema: {
      'type': 'object',
      'properties': {
        'keywords': {'type': 'array', 'items': {'type': 'string'}},
        'from': {'type': 'string'},
        'to': {'type': 'string'},
        'subject': {'type': 'string'},
        'since': {'type': 'string'},
        'before': {'type': 'string'},
        'unread_only': {'type': 'boolean'},
        'flagged_only': {'type': 'boolean'},
        'has_attachment': {'type': 'boolean'},
      },
      'required': ['keywords', 'from', 'to', 'since', 'before'],
    });
    return SearchPlan.fromJson(json);
  }

  /// Re-orders search candidates by how well they answer [query], dropping
  /// clearly irrelevant ones. Returns candidate ids, best first.
  Future<List<String>> rankResults(String query, List<EmailContent> candidates) async {
    if (candidates.isEmpty) return [];
    final list = StringBuffer();
    for (var i = 0; i < candidates.length; i++) {
      final e = candidates[i];
      list.writeln('[$i] ${e.date == null ? '' : '${_ymd(e.date!)} '}From: ${e.from} | Subject: ${e.subject} | ${e.snippet}');
    }
    final json = await provider.completeJson([
      const AiMessage.system(
          'You rank email search results. Return the indexes of the emails that are relevant to the '
          'user\'s search, most relevant first. Leave out emails that clearly do not match.'),
      AiMessage.user('Search: $query\n\nEmails:\n$list'),
    ], model: fastModel, schema: {
      'type': 'object',
      'properties': {
        'relevant': {'type': 'array', 'items': {'type': 'integer'}},
      },
      'required': ['relevant'],
    });
    final seen = <int>{};
    return [
      for (final i in (json['relevant'] as List? ?? const []))
        if (i is int && i >= 0 && i < candidates.length && seen.add(i))
          candidates[i].id
    ];
  }

  /// Answers a question using the found emails ("When is my flight?").
  Stream<String> answerFromEmails(String question, List<EmailContent> emails) {
    final ctx = StringBuffer();
    for (var i = 0; i < emails.length; i++) {
      ctx.writeln('=== Email ${i + 1} ===\n${emails[i].forPrompt(maxBodyChars: 2500)}\n');
    }
    return provider.chat([
      AiMessage.system(
          'Answer the user\'s question using only the emails provided. Today is ${_today()}. '
          'Be direct and brief (1-4 sentences or a few bullets). Mention which sender/subject the '
          'answer came from. If the emails do not contain the answer, say so plainly.'),
      AiMessage.user('Question: $question\n\n$ctx'),
    ], model: fastModel, temperature: 0.2);
  }

  // ---------------------------------------------------------------- translation

  /// The language [text] is written in, e.g. "German", or null if unsure.
  /// Tries a fast offline guess first and only asks the model when needed.
  Future<String?> detectLanguage(String text) async {
    final quick = Languages.guess(text);
    if (quick != null) return quick;
    final sample = text.length > 600 ? text.substring(0, 600) : text;
    if (sample.trim().length < 20) return null;
    try {
      final json = await provider.completeJson([
        const AiMessage.system('Identify the main language of the text. Answer with its English name, e.g. "German".'),
        AiMessage.user(sample),
      ], model: fastModel, schema: {
        'type': 'object',
        'properties': {'language': {'type': 'string'}},
        'required': ['language'],
      });
      final l = (json['language'] as String? ?? '').trim();
      return l.isEmpty ? null : l;
    } catch (_) {
      return null;
    }
  }

  /// Translates [text] into [target] (an English language name such as
  /// "Spanish"), streaming the result. Keeps line breaks, names and numbers.
  ///
  /// Reading uses the dedicated [translationModel] when installed (in
  /// tool/model_bench.dart translategemma was the most faithful into
  /// English). With [forSending], the writing model is used instead: it
  /// writes more natural foreign-language text.
  Stream<String> translate(String text, String target, {String? source, bool forSending = false}) async* {
    var input = text.trim();
    if (input.length > 9000) input = '${input.substring(0, 9000)}\n[…]';
    final model = !forSending && translationModel.isNotEmpty ? translationModel : writingModel;
    if (model.contains('translategemma')) {
      final from = source ?? await detectLanguage(input) ?? 'English';
      // TranslateGemma is trained on this exact prompt.
      yield* provider.chat([
        AiMessage.user('You are a professional $from (${Languages.code(from)}) to $target (${Languages.code(target)}) translator. '
            'Your goal is to accurately convey the meaning and nuances of the original $from text while adhering to $target grammar, vocabulary, and cultural sensitivities.\n'
            'Produce only the $target translation, without any additional explanations or commentary. '
            'Please translate the following $from text into $target:\n\n\n$input'),
      ], model: model, temperature: 0.1);
      return;
    }
    yield* provider.chat([
      AiMessage.system('You are a professional translator. Translate the text the user gives you into $target. '
          'Keep the meaning, tone, names, numbers, dates, links, line breaks and "- " bullets. '
          'If parts are already in $target, keep them unchanged. Output only the translation.'),
      AiMessage.user(input),
    ], model: model, temperature: 0.1);
  }

  // ---------------------------------------------------------------- calendar

  /// Finds an appointment, meeting or booking in the email, for "Add to
  /// Calendar". Returns null if there is none.
  Future<EmailEvent?> extractEvent(EmailContent email) async {
    final json = await provider.completeJson([
      AiMessage.system('Find the single most important event, appointment, meeting, flight or deadline in this email. '
          'Today is ${_today()}. The email was sent ${email.date == null ? 'recently' : _ymd(email.date!)}. '
          'Resolve relative dates ("next Tuesday") to real dates. Times are local, ISO format YYYY-MM-DDTHH:MM. '
          'If there is no time, set all_day true and use YYYY-MM-DD. If there is no end, leave end empty. '
          'If the email has no event, set found false.'),
      AiMessage.user(email.forPrompt(maxBodyChars: 5000)),
    ], model: fastModel, schema: {
      'type': 'object',
      'properties': {
        'found': {'type': 'boolean'},
        'title': {'type': 'string'},
        'start': {'type': 'string'},
        'end': {'type': 'string'},
        'all_day': {'type': 'boolean'},
        'location': {'type': 'string'},
      },
      'required': ['found', 'title', 'start', 'end', 'all_day', 'location'],
    });
    if (json['found'] != true) return null;
    final start = DateTime.tryParse(json['start'] as String? ?? '');
    if (start == null) return null;
    final end = DateTime.tryParse(json['end'] as String? ?? '');
    return EmailEvent(
      title: (json['title'] as String? ?? '').trim().isEmpty ? email.subject : (json['title'] as String).trim(),
      start: start,
      end: end != null && end.isAfter(start) ? end : null,
      allDay: json['all_day'] == true,
      location: (json['location'] as String? ?? '').trim(),
    );
  }

  // ---------------------------------------------------------------- helpers

  /// Tidies a finished AI draft: drops code fences, a stray "Subject:" line
  /// and chatty preambles that small models sometimes add anyway.
  static String cleanDraft(String text) {
    var t = text.trim();
    t = t.replaceAll(RegExp(r'^```[a-z]*\n?|\n?```$'), '').trim();
    t = t.replaceFirst(RegExp(r"^(here('s| is)[^\n]*:\s*\n)", caseSensitive: false), '').trim();
    t = t.replaceFirst(RegExp(r'^subject:[^\n]*\n+', caseSensitive: false), '').trim();
    return t;
  }

  String _today() => _ymd(_now());
  String _weekday() => const [
        'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
      ][_now().weekday - 1];
  static String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// An event found in an email.
class EmailEvent {
  const EmailEvent({required this.title, required this.start, this.end, this.allDay = false, this.location = ''});
  final String title;
  final DateTime start;
  final DateTime? end;
  final bool allDay;
  final String location;

  /// An .ics file that Calendar (or any calendar app) can import.
  String toIcs({String description = ''}) {
    String esc(String s) => s.replaceAll('\\', r'\\').replaceAll(';', r'\;').replaceAll(',', r'\,').replaceAll('\n', r'\n');
    String two(int n) => n.toString().padLeft(2, '0');
    String date(DateTime d) => '${d.year}${two(d.month)}${two(d.day)}';
    String dt(DateTime d) => '${date(d)}T${two(d.hour)}${two(d.minute)}00';
    final now = DateTime.now().toUtc();
    final e = end ?? (allDay ? start.add(const Duration(days: 1)) : start.add(const Duration(hours: 1)));
    return [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//Lumen Mail//EN',
      'BEGIN:VEVENT',
      'UID:${now.microsecondsSinceEpoch}@lumen-mail',
      'DTSTAMP:${dt(now)}Z',
      if (allDay) ...['DTSTART;VALUE=DATE:${date(start)}', 'DTEND;VALUE=DATE:${date(e)}']
      else ...['DTSTART:${dt(start)}', 'DTEND:${dt(e)}'],
      'SUMMARY:${esc(title)}',
      if (location.isNotEmpty) 'LOCATION:${esc(location)}',
      if (description.isNotEmpty) 'DESCRIPTION:${esc(description)}',
      'END:VEVENT',
      'END:VCALENDAR',
    ].join('\r\n');
  }
}

/// Language names, codes and a fast offline guess for common languages.
class Languages {
  /// Offered in pickers; any other language name also works.
  static const common = [
    'English', 'Spanish', 'French', 'German', 'Italian', 'Portuguese', 'Dutch', 'Hindi',
    'Chinese', 'Japanese', 'Korean', 'Arabic', 'Russian', 'Turkish', 'Polish', 'Swedish',
  ];

  static const _codes = {
    'english': 'en', 'spanish': 'es', 'french': 'fr', 'german': 'de', 'italian': 'it', 'portuguese': 'pt',
    'dutch': 'nl', 'hindi': 'hi', 'chinese': 'zh', 'japanese': 'ja', 'korean': 'ko', 'arabic': 'ar',
    'russian': 'ru', 'turkish': 'tr', 'polish': 'pl', 'swedish': 'sv', 'danish': 'da', 'norwegian': 'no',
    'finnish': 'fi', 'greek': 'el', 'hebrew': 'he', 'thai': 'th', 'vietnamese': 'vi', 'indonesian': 'id',
    'ukrainian': 'uk', 'czech': 'cs', 'romanian': 'ro', 'hungarian': 'hu', 'bengali': 'bn', 'tamil': 'ta',
    'telugu': 'te', 'marathi': 'mr', 'urdu': 'ur', 'persian': 'fa', 'gujarati': 'gu', 'punjabi': 'pa',
  };

  static String code(String language) => _codes[language.toLowerCase()] ?? language.toLowerCase().substring(0, 2);

  static const _stop = {
    'English': ['the', 'and', 'you', 'that', 'for', 'with', 'this', 'have', 'are', 'your', 'is', 'to', 'of', 'we', 'will'],
    'German': ['der', 'die', 'und', 'das', 'ist', 'nicht', 'sie', 'ich', 'mit', 'für', 'wir', 'ihre', 'bitte', 'den', 'sehr'],
    'French': ['le', 'la', 'les', 'et', 'des', 'est', 'vous', 'pour', 'une', 'pas', 'que', 'nous', 'votre', 'dans', 'avec'],
    'Spanish': ['el', 'la', 'los', 'y', 'que', 'es', 'para', 'por', 'una', 'con', 'su', 'del', 'las', 'usted', 'gracias'],
    'Italian': ['il', 'di', 'che', 'e', 'per', 'non', 'una', 'sono', 'gli', 'della', 'con', 'grazie', 'questo', 'del', 'ti'],
    'Portuguese': ['o', 'de', 'que', 'e', 'para', 'não', 'uma', 'com', 'os', 'você', 'obrigado', 'seu', 'sua', 'do', 'da'],
    'Dutch': ['de', 'het', 'een', 'en', 'van', 'is', 'niet', 'je', 'voor', 'met', 'wij', 'uw', 'graag', 'dat', 'ik'],
  };

  /// A quick guess from the script and common words. Null when unsure.
  static String? guess(String text) {
    final sample = text.length > 2000 ? text.substring(0, 2000) : text;
    var letters = 0;
    final scripts = <String, int>{};
    for (final r in sample.runes) {
      String? s;
      if (r >= 0x0900 && r <= 0x097F) {
        s = 'Hindi';
      } else if ((r >= 0x3040 && r <= 0x30FF)) {
        s = 'Japanese';
      } else if (r >= 0xAC00 && r <= 0xD7AF) {
        s = 'Korean';
      } else if (r >= 0x4E00 && r <= 0x9FFF) {
        s = 'Han';
      } else if (r >= 0x0400 && r <= 0x04FF) {
        s = 'Cyrillic';
      } else if (r >= 0x0600 && r <= 0x06FF) {
        s = 'Arabic';
      } else if (r >= 0x0370 && r <= 0x03FF) {
        s = 'Greek';
      } else if (r >= 0x0590 && r <= 0x05FF) {
        s = 'Hebrew';
      } else if (r >= 0x0E00 && r <= 0x0E7F) {
        s = 'Thai';
      } else if (r >= 0x0980 && r <= 0x09FF) {
        s = 'Bengali';
      } else if (r >= 0x0B80 && r <= 0x0BFF) {
        s = 'Tamil';
      }
      if (s != null) {
        scripts[s] = (scripts[s] ?? 0) + 1;
        letters++;
      } else if ((r >= 65 && r <= 90) || (r >= 97 && r <= 122) || (r >= 0xC0 && r <= 0x24F)) {
        letters++;
      }
    }
    if (letters < 15) return null;
    if (scripts.isNotEmpty) {
      final top = scripts.entries.reduce((a, b) => a.value >= b.value ? a : b);
      if (top.value > letters * 0.3) {
        if (top.key == 'Han') return (scripts['Japanese'] ?? 0) > 0 ? 'Japanese' : 'Chinese';
        if (top.key == 'Cyrillic' || top.key == 'Arabic') return null; // several languages share these scripts
        return top.key;
      }
    }
    final words = RegExp(r"[a-zA-Zà-ÿßäöüÄÖÜ']+").allMatches(sample.toLowerCase()).map((m) => m[0]!).toList();
    if (words.length < 6) return null;
    final scores = <String, int>{};
    for (final MapEntry(key: lang, value: stop) in _stop.entries) {
      final set = stop.toSet();
      scores[lang] = words.where(set.contains).length;
    }
    final ranked = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final best = ranked[0], second = ranked[1];
    // Confident only with a clear winner.
    if (best.value >= 3 && best.value >= second.value * 2 && best.value >= words.length * 0.06) return best.key;
    return null;
  }
}
