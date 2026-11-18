import 'package:flutter_test/flutter_test.dart';
import 'package:hearthmail/models/brief.dart';
import 'package:hearthmail/services/settings_store.dart';

void main() {
  test('briefing items parse and fall back safely', () {
    final b = BriefItem.fromJson({'group': 'attention', 'takeaway': ' Pay the invoice ', 'action': 'pay', 'due': 'Friday'});
    expect(b.group, BriefGroup.attention);
    expect(b.action, BriefAction.pay);
    expect(b.takeaway, 'Pay the invoice');
    expect(b.due, 'Friday');
    final odd = BriefItem.fromJson({'group': 'urgent!!', 'action': 'call'});
    expect(odd.group, BriefGroup.fyi);
    expect(odd.action, BriefAction.none);
  });

  test('view options are off by default and persist', () {
    const s = AppSettings();
    expect(s.showCategories, isFalse);
    expect(s.priorityFirst, isFalse);
    expect(s.showContactPhotos, isFalse);
    final back = AppSettings.fromJson(s.copyWith(showCategories: true, showContactPhotos: true).toJson());
    expect(back.showCategories, isTrue);
    expect(back.showContactPhotos, isTrue);
    expect(back.priorityFirst, isFalse);
  });
}
