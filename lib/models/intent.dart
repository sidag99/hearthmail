/// Short options the local model proposes for what an email should convey.
/// The user picks from them and a (possibly cloud) writer writes the email.
class IntentOptions {
  const IntentOptions({this.goals = const [], this.points = const [], this.tones = const []});

  /// Mutually exclusive overall messages ("Accept the invitation").
  final List<String> goals;

  /// Optional details to add ("Ask whether Q1 is included").
  final List<String> points;

  /// Tones that fit ("Warm", "Brief and direct").
  final List<String> tones;

  bool get isEmpty => goals.isEmpty && points.isEmpty && tones.isEmpty;

  static List<String> _list(Object? v, int max) => {
        if (v is List)
          for (final x in v)
            if (x is String && x.trim().isNotEmpty) x.trim().replaceAll(RegExp(r'[.]$'), ''),
      }.take(max).toList();

  factory IntentOptions.fromJson(Map<String, dynamic> j) => IntentOptions(
        goals: _list(j['goals'], 4),
        points: _list(j['points'], 6),
        tones: _list(j['tones'], 4),
      );
}

/// What the user picked; turned into instructions for the writer.
class IntentChoice {
  const IntentChoice({this.goal, this.points = const [], this.tone, this.notes = ''});

  final String? goal;
  final List<String> points;
  final String? tone;

  /// Anything the user typed in their own words.
  final String notes;

  bool get isEmpty => (goal == null || goal!.isEmpty) && points.isEmpty && notes.trim().isEmpty;

  String toPrompt() => [
        if (goal != null && goal!.isNotEmpty) 'Main message: $goal',
        if (points.isNotEmpty) 'Also include:\n${points.map((p) => '- $p').join('\n')}',
        if (notes.trim().isNotEmpty) 'In my own words: ${notes.trim()}',
        if (tone != null && tone!.isNotEmpty) 'Tone: $tone',
      ].join('\n');
}
