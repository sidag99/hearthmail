import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ai/email_ai.dart';

/// Apple's on-device language detection and translation (macOS 26+), via
/// macos/Runner/MainFlutterWindow.swift. Much faster than a language model;
/// callers fall back to the local model when this returns null.
class AppleLanguage {
  static const _channel = MethodChannel('app.hearthmail/apple_language');

  static bool get available =>
      !kIsWeb && Platform.isMacOS && !Platform.environment.containsKey('FLUTTER_TEST');

  /// The language of [text] as an English name ("German"), or null.
  static Future<String?> detect(String text) async {
    if (!available || text.trim().length < 20) return null;
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('detect', {'text': text});
      final code = r?['code'] as String?;
      final confidence = (r?['confidence'] as num?)?.toDouble() ?? 0;
      if (code == null || confidence < 0.6) return null;
      return Languages.nameOf(code);
    } catch (_) {
      return null;
    }
  }

  /// "installed", "supported" (pack not downloaded yet) or "unsupported".
  static Future<String> status(String source, String target) async {
    if (!available) return 'unsupported';
    try {
      return await _channel.invokeMethod<String>(
              'status', {'source': Languages.code(source), 'target': Languages.code(target)}) ??
          'unsupported';
    } catch (_) {
      return 'unsupported';
    }
  }

  /// Translates [text] keeping its line structure, or returns null if Apple
  /// can't (older macOS, or the language pair isn't downloaded).
  static Future<String?> translate(String text, {required String source, required String target}) async {
    if (!available) return null;
    final lines = text.split('\n');
    final idx = <int>[];
    final paragraphs = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isNotEmpty) {
        idx.add(i);
        paragraphs.add(lines[i]);
      }
    }
    if (paragraphs.isEmpty) return text;
    try {
      final out = await _channel.invokeListMethod<String>('translate', {
        'source': Languages.code(source),
        'target': Languages.code(target),
        'paragraphs': paragraphs,
      });
      if (out == null || out.length != paragraphs.length) return null;
      for (var j = 0; j < idx.length; j++) {
        lines[idx[j]] = out[j];
      }
      return lines.join('\n');
    } catch (_) {
      return null;
    }
  }
}
