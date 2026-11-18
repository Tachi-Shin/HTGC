import 'dart:io';

import '../runtime/js_core.dart';

String decode(String hex) => String.fromCharCodes(
  hex
      .trim()
      .split(RegExp(r'\s+'))
      .where((v) => v.isNotEmpty)
      .map((v) => int.parse(v, radix: 16)),
);
void main(List<String> args) {
  var cases = 0;
  for (final line in File(args.first).readAsLinesSync()) {
    final data = line.split('#').first.trim();
    if (data.isEmpty || data.startsWith('@')) continue;
    final columns = data.split(';').take(5).map(decode).toList();
    for (var i = 0; i < 5; i++) {
      final expectedNfc = columns[i < 3 ? 1 : 3];
      final expectedNfd = columns[i < 3 ? 2 : 4];
      for (final (form, expected) in [
        ('NFC', expectedNfc),
        ('NFD', expectedNfd),
        ('NFKC', columns[3]),
        ('NFKD', columns[4]),
      ]) {
        if (jNormalize(columns[i], form) != expected)
          throw StateError(
            'Normalization failed at row $cases, column $i, $form',
          );
      }
    }
    cases++;
  }
  if (jNormalize('\ud800A\udc00', 'NFC') != '\ud800A\udc00')
    throw StateError('Surrogates');
  print('PASS $cases Unicode normalization rows');
}
