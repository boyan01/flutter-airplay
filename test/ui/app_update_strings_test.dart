import 'package:flutter_airplay/ui/widgets/app_update_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plain and empty legacy notes are preserved', () {
    expect(localizedUpdateNotes(null, 'zh'), '');
    expect(
      localizedUpdateNotes('  Improved playback.  ', 'zh'),
      'Improved playback.',
    );
    expect(
      localizedUpdateNotes('<b>Playback</b>\nBug fixes', 'en'),
      '<b>Playback</b>\nBug fixes',
    );
  });

  test(
    'language headings support feed text, Markdown and Windows newlines',
    () {
      const notes =
          '### English\r\n• Playback\r\n  continuation\r\n\r\n### 中文\r\n• 播放';
      expect(localizedUpdateNotes(notes, 'zh'), '• 播放');
      expect(localizedUpdateNotes(notes, 'en'), '• Playback\r\n  continuation');
      expect(localizedUpdateNotes(notes, 'ja'), '• Playback\r\n  continuation');
    },
  );

  test('missing or empty sections fall back to available notes', () {
    expect(localizedUpdateNotes('English\n• Playback', 'zh'), '• Playback');
    expect(localizedUpdateNotes('中文\nEnglish\n• Playback', 'zh'), '• Playback');
    expect(localizedUpdateNotes('中文\n• 播放', 'en'), '• 播放');
  });
}
