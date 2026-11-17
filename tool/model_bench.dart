// ignore_for_file: avoid_print
// Compares local models on the jobs this app gives them.
//
//   dart run tool/model_bench.dart embed      # search (embedding) models
//   dart run tool/model_bench.dart chat       # speed + sorting accuracy
//   dart run tool/model_bench.dart translate  # translation quality/speed
//
// Needs Ollama running with the models listed below.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

const base = 'http://localhost:11434';

// ------------------------------------------------------------------ data

/// (subject, body) pairs. Queries below refer to them by index.
const emails = <(String, String)>[
  ('Your flight to Lisbon is confirmed', 'Booking ref KX72PQ. TAP Air Portugal TP1153 departs Berlin BER 14 Dec 07:25, arrives Lisbon 09:50. Check-in opens 24h before departure.'),
  ('Invoice #4471 from Hetzner Online', 'Your invoice for November is attached. Amount due: 23.80 EUR. It will be charged to your card on file on 1 December.'),
  ('CS 6210 – Project 2 deadline extended', 'Hi all, the deadline for the distributed shuffle project is now Friday 11:59pm. Office hours move to Thursday 3pm in Klaus 1116.'),
  ('Your package has shipped', 'Your order of Anker USB-C charger (65W) has shipped with DHL. Tracking number JD014600003828. Expected delivery Wednesday.'),
  ('Lunch next week?', 'Hey Alex, it has been ages! Are you free for lunch Tuesday or Wednesday next week? There is a new ramen place near the office. – Priya'),
  ('Security alert: new sign-in on Mac', 'We noticed a new sign-in to your Google Account on a Mac device. If this was you, you don\'t need to do anything. If not, we\'ll help you secure your account.'),
  ('Apartment viewing confirmation', 'Dear Mr. Rivera, we confirm your viewing of the 2-room apartment at Schönhauser Allee 12 on Saturday at 11:00. Please bring proof of income (last 3 payslips).'),
  ('Weekly digest: top stories in AI', 'This week: new open-weight models, a deep dive on retrieval-augmented generation, and why evals matter. Read more on our site.'),
  ('Rent increase notice', 'In accordance with §558 BGB we inform you that your monthly rent will increase from 950 EUR to 1,010 EUR starting 1 February.'),
  ('Re: Thesis draft feedback', 'Alex, I went through chapter 3. The related-work section needs more on time-series anomaly detection; also please fix figure 4 axis labels. Let\'s meet Monday.'),
  ('Your Netflix payment failed', 'We couldn\'t process your payment. Please update your payment information to keep watching. Your membership will be paused on 20 November.'),
  ('Team offsite agenda', 'Attached is the agenda for the offsite in Potsdam on 5 December: strategy review in the morning, workshops after lunch, dinner at 7pm. Please RSVP by Friday.'),
  ('Doctor appointment reminder', 'This is a reminder of your appointment with Dr. Schulz (dermatology) on 19 November at 08:30. Please bring your insurance card.'),
  ('Black Friday: 40% off everything', 'Our biggest sale of the year is here. Use code BF40 at checkout. Free shipping on orders over 50 EUR. Ends Monday.'),
  ('Tax return documents needed', 'Hello, to finish your 2025 Steuererklärung we still need your Lohnsteuerbescheinigung and the receipts for your home-office equipment. Kind regards, Steuerbüro Weber'),
  ('Your GitHub Actions run failed', 'Run #482 failed for myapp/main: test job exited with code 1. View the logs for details.'),
  ('Wedding invitation – save the date!', 'Ananya & Rohan are getting married! Save the date: 14 March 2027 in Jaipur. Formal invitation to follow.'),
  ('Library book due soon', 'The book "Designing Data-Intensive Applications" is due back on 22 November. You can renew it online twice.'),
  ('Interview invitation – Software Engineer', 'Thank you for applying to Zalando. We would like to invite you to a 45-minute technical interview. Please pick a slot using the link below.'),
  ('Gym membership renewal', 'Your annual membership at Urban Sports Club renews on 1 December for 89 EUR/month. Reply to this email to cancel.'),
  ('Train ticket: Berlin – Munich', 'Your Deutsche Bahn ticket: ICE 1003, 21 Dec, Berlin Hbf 09:34 → München Hbf 13:39, car 7 seat 64. Order number 7XQ2KM.'),
  ('Re: borrowed camera', 'No rush, but could you bring back my Sony camera when you get a chance? I need it for a trip in January. Thanks! – Max'),
  ('Electricity bill October', 'Your Vattenfall bill for October: 64.20 EUR, debited on 15 November. Consumption: 182 kWh.'),
  ('Conference talk accepted', 'Congratulations! Your talk "Shuffling at scale" has been accepted for DataConf Berlin 2027. Please confirm by 30 November.'),
  ('Rückruf erbeten – Versicherung', 'Sehr geehrter Herr Rivera, bitte rufen Sie uns bezüglich Ihres Schadensfalls (Fahrradiebstahl) zurück. Ihre Allianz Versicherung.'),
  ('Facture de votre séjour', 'Merci pour votre séjour à l\'Hôtel du Marais. Veuillez trouver ci-joint la facture de 312 EUR pour les nuits du 3 au 5 octobre.'),
  ('Password reset requested', 'Someone requested a password reset for your Spotify account. If this was you, use the link below. Otherwise ignore this email.'),
  ('Mom\'s birthday plan', 'Let\'s do a video call on Sunday for mom\'s birthday at 6pm IST. I\'ll order the cake to be delivered at home. – Neha'),
  ('Scholarship disbursement', 'Your DAAD scholarship installment of 934 EUR for December has been transferred to your account ending 4471.'),
  ('Coffee machine broken (office)', 'FYI the coffee machine on floor 3 is broken again. Facilities are on it. Use the one on floor 2 in the meantime.'),
  // 30+: look-alike distractors
  ('Flight deals to Lisbon from 39 EUR', 'Fly to Lisbon, Porto and Madeira this winter. Book by Sunday. Flights from Berlin BER.'),
  ('Your Ryanair booking FR8842', 'Booking confirmed: Berlin BER to Barcelona BCN, 2 Feb 2027 06:10. Priority boarding not included.'),
  ('Invoice #9921 from Figma', 'Your Figma Professional invoice: 15.00 USD for November, charged to Visa ending 0912.'),
  ('CS 6400 – Homework 4 posted', 'Homework 4 on query optimization is posted on Canvas. Due in two weeks.'),
  ('Your Amazon order has been delivered', 'Your package with a phone case was delivered and left at the front door.'),
  ('Dinner on Friday?', 'Hi, we are hosting a small dinner at our place on Friday, 8pm. Let me know if you can come! – Lena'),
  ('New listings matching your search', '3 new apartments in Prenzlauer Berg match your saved search: 2 rooms, up to 1,100 EUR warm.'),
  ('Re: Thesis defense scheduling', 'The committee is available on 12 or 13 February for your defense. Please send the room booking.'),
  ('Your Spotify Premium receipt', 'Thanks for your payment of 10.99 EUR for Spotify Premium Individual.'),
  ('Dentist: time for your check-up', 'It has been 6 months since your last visit. Book your next check-up online.'),
  ('Steuer-Newsletter November', 'Neue Regeln für die Pendlerpauschale 2026 und was Sie jetzt beachten sollten.'),
  ('GitHub: new sign-in from Chrome', 'A new sign-in to your GitHub account was detected from Chrome on Windows.'),
  ('Recruiter: exciting opportunity', 'Hi Alex, I came across your profile and think you would be a great fit for a senior role at a fast-growing fintech.'),
  ('Your BVG monthly ticket', 'Your Deutschlandticket for December is ready in the app. 58 EUR will be debited on 1 December.'),
  ('Can I borrow your drill?', 'Hey, do you still have that Bosch drill? I need to hang some shelves this weekend. – Jonas'),
  ('Haftpflicht: Ihre Jahresrechnung', 'Ihre Privathaftpflicht-Versicherung: Jahresbeitrag 59,90 EUR wird am 1. Januar abgebucht.'),
  ('Votre réservation – Hôtel Lumière Lyon', 'Nous confirmons votre réservation du 14 au 16 janvier. Montant : 240 EUR, payable à l\'arrivée.'),
  ('Family WhatsApp group photos', 'Uploaded all the Diwali photos to the shared album. Check them out! – Neha'),
  ('Erasmus grant information', 'Information about Erasmus+ mobility grants for the summer semester. Applications close 15 January.'),
  ('Gas bill October', 'Your gas bill for October: 41.10 EUR. Consumption: 395 kWh. Thank you for choosing E.ON.'),
];


/// (query, index of the email that answers it)
const queries = <(String, int)>[
  ('when does my flight leave', 0),
  ('how much do I pay for my server hosting', 1),
  ('project deadline for my university course', 2),
  ('where is my charger delivery', 3),
  ('someone wants to grab food with me', 4),
  ('what documents do I need for the flat visit', 6),
  ('is my rent going up', 8),
  ('what did my supervisor say about my thesis', 9),
  ('subscription payment problem', 10),
  ('when is my skin doctor appointment', 12),
  ('what does the accountant need from me', 14),
  ('my CI build is broken', 15),
  ('job interview', 18),
  ('train seat number', 20),
  ('who wants their camera back', 21),
  ('insurance claim bike stolen', 24),
  ('hotel bill paris', 25),
  ('family video call', 27),
  ('how much scholarship money did I get', 28),
  ('energy consumption last month', 22),
  // harder: paraphrases and cross-language
  ('when do I need to be at the airport for portugal', 0),
  ('cloud server bill', 1),
  ('extension for the distributed systems assignment', 2),
  ('tracking number for the thing I ordered', 3),
  ('Priya ramen', 4),
  ('payslips for the landlord viewing', 6),
  ('Mieterhöhung', 8),
  ('feedback on chapter 3', 9),
  ('my streaming membership will be paused', 10),
  ('Hautarzt Termin', 12),
  ('Lohnsteuerbescheinigung', 14),
  ('insurance wants me to call back', 24),
  ('how much was the hotel in the Marais', 25),
  ('phone call for mom on sunday', 27),
  ('DAAD money', 28),
  ('power bill', 22),
  ('ICE to Munich', 20),
  ('Max Sony', 21),
  ('wedding in Jaipur', 16),
  ('cancel gym', 19),
];


// ------------------------------------------------------------------ helpers

Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) async {
  final res = await http.post(Uri.parse('$base$path'),
      headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
  if (res.statusCode != 200) throw Exception('${res.statusCode}: ${res.body}');
  return jsonDecode(res.body) as Map<String, dynamic>;
}

List<double> norm(List<double> v, int dims) {
  final x = v.take(dims).toList();
  final n = sqrt(x.fold<double>(0, (a, b) => a + b * b));
  return [for (final e in x) e / n];
}

double dot(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}

Future<List<List<double>>> embed(String model, List<String> input) async {
  final j = await post('/api/embed', {'model': model, 'input': input, 'keep_alive': '5m'});
  return [for (final e in j['embeddings'] as List) [for (final x in e as List) (x as num).toDouble()]];
}

// ------------------------------------------------------------------ embed

Future<void> benchEmbed() async {
  final models = {
    'embeddinggemma:300m': (
      (String q) => 'task: search result | query: $q',
      (String s, String b) => 'title: $s | text: $b',
    ),
    'qwen3-embedding:0.6b': (
      (String q) => 'Instruct: Given an email search query, retrieve the email that answers it\nQuery: $q',
      (String s, String b) => 'Subject: $s\n$b',
    ),
  };
  for (final MapEntry(key: model, value: (qf, df)) in models.entries) {
    await embed(model, ['warm up']);
    var sw = Stopwatch()..start();
    final docs = await embed(model, [for (final (s, b) in emails) df(s, b)]);
    final docMs = sw.elapsedMilliseconds;
    sw = Stopwatch()..start();
    final qs = <List<double>>[];
    for (final (q, _) in queries) {
      qs.addAll(await embed(model, [qf(q)]));
    }
    final qMs = sw.elapsedMilliseconds / queries.length;
    final full = docs.first.length;
    for (final dims in {full, 512, 256}) {
      if (dims > full) continue;
      var hit1 = 0, hit3 = 0;
      var mrr = 0.0;
      final d = [for (final v in docs) norm(v, dims)];
      for (var i = 0; i < queries.length; i++) {
        final q = norm(qs[i], dims);
        final order = List.generate(d.length, (j) => j)..sort((a, b) => dot(q, d[b]).compareTo(dot(q, d[a])));
        final rank = order.indexOf(queries[i].$2) + 1;
        if (rank == 1) hit1++;
        if (rank <= 3) hit3++;
        mrr += 1 / rank;
      }
      print('$model dims=$dims  top1=$hit1/${queries.length}  top3=$hit3/${queries.length}  '
          'MRR=${(mrr / queries.length).toStringAsFixed(3)}');
    }
    print('$model  ${emails.length} docs in ${docMs}ms (${(docMs / emails.length).toStringAsFixed(1)} ms/doc), '
        'query ${qMs.toStringAsFixed(0)} ms, full dims=$full\n');
  }
}

// ------------------------------------------------------------------ chat

/// (index, expected category, expected priority)
const labels = <(int, String, String)>[
  (0, 'travel', 'normal'), (1, 'finance', 'normal'), (2, 'work', 'high'), (3, 'shopping', 'normal'),
  (4, 'personal', 'normal'), (5, 'notification', 'high'), (7, 'newsletter', 'low'), (8, 'finance', 'high'),
  (9, 'work', 'high'), (10, 'finance', 'high'), (13, 'promotion', 'low'), (14, 'finance', 'high'),
  (15, 'notification', 'normal'), (18, 'work', 'high'), (20, 'travel', 'normal'), (21, 'personal', 'normal'),
  (24, 'finance', 'high'), (26, 'notification', 'normal'), (29, 'work', 'low'), (11, 'work', 'normal'),
];

const categories = 'personal, work, finance, shopping, travel, newsletter, promotion, social, notification, other';

Future<void> benchChat(List<String> models) async {
  for (final model in models) {
    // Speed: one writing task, measured by Ollama's own counters.
    await post('/api/chat', {
      'model': model, 'stream': false, 'think': false, 'keep_alive': '5m',
      'messages': [{'role': 'user', 'content': 'Say OK.'}],
    });
    final sw = Stopwatch()..start();
    final w = await post('/api/chat', {
      'model': model, 'stream': false, 'think': false, 'keep_alive': '5m',
      'options': {'temperature': 0.6, 'num_ctx': 8192},
      'messages': [
        {'role': 'system', 'content': 'You write short, natural emails. Output only the email body.'},
        {'role': 'user', 'content': 'Reply to Priya: yes to lunch, Wednesday works, suggest 12:30 at the ramen place.\n\nHer email: ${emails[4].$2}'},
      ],
    });
    final total = sw.elapsedMilliseconds;
    final tps = (w['eval_count'] as num) / ((w['eval_duration'] as num) / 1e9);
    final promptMs = (w['prompt_eval_duration'] as num? ?? 0) / 1e6;

    // Sorting accuracy, in batches of 10 like the app.
    var cat = 0, pri = 0, valid = 0;
    final sw2 = Stopwatch()..start();
    for (var b = 0; b < labels.length; b += 10) {
      final chunk = labels.sublist(b, min(b + 10, labels.length));
      final list = StringBuffer();
      for (var i = 0; i < chunk.length; i++) {
        final (s, body) = emails[chunk[i].$1];
        list.writeln('[$i] Subject: $s\n    Preview: $body');
      }
      final r = await post('/api/chat', {
        'model': model, 'stream': false, 'think': false, 'keep_alive': '5m',
        'options': {'temperature': 0.1, 'num_ctx': 8192},
        'format': {
          'type': 'object',
          'properties': {
            'items': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'index': {'type': 'integer'},
                  'category': {'type': 'string', 'enum': categories.split(', ')},
                  'priority': {'type': 'string', 'enum': ['high', 'normal', 'low']},
                },
                'required': ['index', 'category', 'priority'],
              },
            },
          },
          'required': ['items'],
        },
        'messages': [
          {'role': 'system', 'content': 'Sort these emails. category: one of $categories. priority: "high" only if a real person or institution needs action or attention soon (deadlines, direct questions, security problems, bills due); "low" for promotions, newsletters and trivial FYIs; otherwise "normal". Return one item per email using its [index].'},
          {'role': 'user', 'content': list.toString()},
        ],
      });
      try {
        final items = (jsonDecode(r['message']['content'] as String) as Map)['items'] as List;
        for (final it in items) {
          final i = it['index'] as int;
          if (i < 0 || i >= chunk.length) continue;
          valid++;
          if (it['category'] == chunk[i].$2) cat++;
          if (it['priority'] == chunk[i].$3) pri++;
        }
      } catch (_) {}
    }
    print('$model\n  writing: ${total}ms total, ${tps.toStringAsFixed(1)} tokens/s, prompt ${promptMs.toStringAsFixed(0)}ms'
        '\n  sorting: category $cat/${labels.length}, priority $pri/${labels.length}, '
        'valid $valid/${labels.length}, ${sw2.elapsedMilliseconds}ms for ${labels.length} emails'
        '\n  sample reply: ${(w['message']['content'] as String).replaceAll('\n', ' ⏎ ')}\n');
  }
}

// ------------------------------------------------------------------ translate

const samples = <(String, String, String)>[
  ('German', 'de', 'Sehr geehrter Herr Rivera, leider müssen wir Ihren Termin am Donnerstag absagen, da Frau Dr. Schulz erkrankt ist. Bitte vereinbaren Sie telefonisch einen neuen Termin. Die Stornogebühr entfällt selbstverständlich.'),
  ('French', 'fr', 'Bonjour, nous avons bien reçu votre dossier de candidature. Malheureusement, il manque une copie de votre diplôme. Pourriez-vous nous la faire parvenir avant le 30 novembre ? Cordialement, le service des admissions.'),
  ('Hindi', 'hi', 'बेटा, रविवार को मम्मी का जन्मदिन है। शाम को छह बजे वीडियो कॉल करेंगे, समय पर आ जाना। केक मैं घर पर मँगवा दूँगी।'),
  ('Japanese', 'ja', 'お世話になっております。先日ご依頼いただいた見積書を添付いたします。ご不明な点がございましたら、お気軽にお問い合わせください。'),
  ('English', 'en', 'Thanks for the quick turnaround! Could you push the review to next Tuesday? I\'m swamped until then. Happy to hop on a call if that\'s easier.'),
];

Future<void> benchTranslate(List<String> models) async {
  for (final model in models) {
    await post('/api/chat', {
      'model': model, 'stream': false, 'think': false, 'keep_alive': '5m',
      'messages': [{'role': 'user', 'content': 'Say OK.'}],
    });
    print('== $model');
    for (final (lang, code, text) in samples) {
      final toLang = code == 'en' ? 'German' : 'English';
      final toCode = code == 'en' ? 'de' : 'en';
      final prompt = model.startsWith('translategemma')
          ? 'You are a professional $lang ($code) to $toLang ($toCode) translator. Your goal is to accurately convey the meaning and nuances of the original $lang text while adhering to $toLang grammar, vocabulary, and cultural sensitivities.\n'
              'Produce only the $toLang translation, without any additional explanations or commentary. Please translate the following $lang text into $toLang:\n\n\n$text'
          : null;
      final sw = Stopwatch()..start();
      final r = await post('/api/chat', {
        'model': model, 'stream': false, 'think': false, 'keep_alive': '5m',
        'options': {'temperature': 0.1, 'num_ctx': 8192},
        'messages': prompt != null
            ? [{'role': 'user', 'content': prompt}]
            : [
                {'role': 'system', 'content': 'You are a professional translator. Translate the email the user gives you into $toLang. Keep names, numbers, dates, line breaks and tone. Output only the translation.'},
                {'role': 'user', 'content': text},
              ],
      });
      print('  [$code→$toCode ${sw.elapsedMilliseconds}ms] ${(r['message']['content'] as String).trim().replaceAll('\n', ' ⏎ ')}');
    }
  }
}

Future<void> main(List<String> args) async {
  final what = args.isEmpty ? 'embed' : args.first;
  switch (what) {
    case 'embed':
      await benchEmbed();
    case 'chat':
      await benchChat(args.length > 1 ? args.sublist(1) : ['gemma4:12b-mlx', 'qwen3.6:35b-a3b']);
    case 'translate':
      await benchTranslate(args.length > 1 ? args.sublist(1) : ['translategemma:4b', 'gemma4:12b-mlx', 'qwen3.6:35b-a3b']);
  }
  exit(0);
}
