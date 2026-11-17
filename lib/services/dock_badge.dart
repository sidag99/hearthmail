import 'dart:io';

import 'package:flutter/services.dart';

/// Shows a number on the macOS Dock icon (implemented in AppDelegate.swift).
class DockBadge {
  static const _channel = MethodChannel('app.hearthmail/badge');
  int? _last;

  /// Shows [count] on the Dock icon; nothing when it is 0.
  Future<void> set(int count) async {
    if (!Platform.isMacOS || count == _last) return;
    _last = count;
    try {
      await _channel.invokeMethod<void>('setBadge', count > 0 ? '$count' : '');
    } on MissingPluginException {
      // Running without the native side (tests); nothing to do.
    } catch (_) {}
  }
}
