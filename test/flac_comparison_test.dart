import 'package:flutter_test/flutter_test.dart';
import 'package:synctune/sync/flac_comparison.dart';

import 'flac_test_data.dart';

String? comparison(List<int> data, {int chunkSize = 7}) {
  final h = FlacComparisonHasher();
  for (var i = 0; i < data.length; i += chunkSize) {
    h.add(
      data.sublist(
        i,
        i + chunkSize < data.length ? i + chunkSize : data.length,
      ),
    );
  }
  return h.close();
}

void main() {
  test(
    'normalizes field order and field-name case across chunk boundaries',
    () {
      final a = testFlac(['TITLE=Song', 'artist=A', 'ARTIST=B', 'ALBUM=X']);
      final b = testFlac(['album=X', 'ARTIST=A', 'artist=B', 'title=Song']);
      expect(comparison(a, chunkSize: 1), isNotNull);
      expect(comparison(a, chunkSize: 1), comparison(b, chunkSize: 11));
    },
  );
  test(
    'retains different values, repeated value order, cover, audio and vendor',
    () {
      final a = comparison(testFlac(['ARTIST=A', 'ARTIST=B', 'TITLE=Song']));
      for (final bytes in [
        testFlac(['ARTIST=A', 'ARTIST=B', 'TITLE=Other']),
        testFlac(['ARTIST=B', 'ARTIST=A', 'TITLE=Song']),
        testFlac(['ARTIST=A', 'TITLE=Song']),
        testFlac(['ARTIST=A', 'ARTIST=B', 'TITLE=Song'], picture: [5, 5]),
        testFlac(['ARTIST=A', 'ARTIST=B', 'TITLE=Song'], audio: [1, 2, 4]),
        testFlac(['ARTIST=A', 'ARTIST=B', 'TITLE=Song'], vendor: 'other'),
      ]) {
        expect(comparison(bytes), isNot(a));
      }
    },
  );
  test('malformed and truncated files fail closed', () {
    expect(comparison([0, 1, 2]), isNull);
    final data = testFlac(['TITLE=Song']);
    expect(comparison(data.sublist(0, 15)), isNull);
    expect(comparison(testFlac(['not a valid field'])), isNull);
    expect(comparison(testFlac(['TITLE=Song'], audio: [])), isNull);
  });
}
