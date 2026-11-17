part of 'js_core.dart';

// The tables are parsed lazily so applications that never normalize text do
// not pay the startup or memory cost of constructing them.
final Map<int, int> _jCombiningClasses = {
  for (final entry
      in _jUnicodeCombiningData.split(',').where((s) => s.isNotEmpty))
    int.parse(entry.split(':')[0], radix: 16): int.parse(
      entry.split(':')[1],
      radix: 16,
    ),
};
final Map<int, (bool, List<int>)> _jDecompositions = {
  for (final entry
      in _jUnicodeDecompositionData.split(',').where((s) => s.isNotEmpty))
    int.parse(entry.split(':')[0], radix: 16): (
      entry.split(':')[1].startsWith('k'),
      entry
          .split(':')[1]
          .substring(1)
          .split('.')
          .map((s) => int.parse(s, radix: 16))
          .toList(),
    ),
};
final Map<int, int> _jCompositions = {
  for (final entry
      in _jUnicodeCompositionData.split(',').where((s) => s.isNotEmpty))
    (int.parse(entry.split(':')[0].split('.')[0], radix: 16) << 21) |
        int.parse(entry.split(':')[0].split('.')[1], radix: 16): int.parse(
      entry.split(':')[1],
      radix: 16,
    ),
};

int? _jCompose(int first, int second) {
  // Hangul syllables compose algorithmically and have no UCD decomposition.
  const lBase = 0x1100, vBase = 0x1161, tBase = 0x11a7, sBase = 0xac00;
  const lCount = 19, vCount = 21, tCount = 28, nCount = vCount * tCount;
  final lIndex = first - lBase, vIndex = second - vBase;
  if (lIndex >= 0 && lIndex < lCount && vIndex >= 0 && vIndex < vCount) {
    return sBase + (lIndex * vCount + vIndex) * tCount;
  }
  final sIndex = first - sBase, tIndex = second - tBase;
  if (sIndex >= 0 &&
      sIndex < lCount * nCount &&
      sIndex % tCount == 0 &&
      tIndex > 0 &&
      tIndex < tCount) {
    return first + tIndex;
  }
  return _jCompositions[(first << 21) | second];
}

String jNormalize(String text, dynamic argument) {
  final form = identical(argument, jUndefined) ? 'NFC' : jString(argument);
  if (!const {'NFC', 'NFD', 'NFKC', 'NFKD'}.contains(form)) {
    throw JThrown(JError('RangeError', 'Invalid Unicode normalization form'));
  }
  final compatibility = form == 'NFKC' || form == 'NFKD';
  final decomposed = <int>[];
  void append(int cp) {
    const sBase = 0xac00, sCount = 11172, nCount = 588, tCount = 28;
    final sIndex = cp - sBase;
    if (sIndex >= 0 && sIndex < sCount) {
      append(0x1100 + sIndex ~/ nCount);
      append(0x1161 + (sIndex % nCount) ~/ tCount);
      final trailing = sIndex % tCount;
      if (trailing != 0) append(0x11a7 + trailing);
      return;
    }
    final mapping = _jDecompositions[cp];
    if (mapping != null && (!mapping.$1 || compatibility)) {
      for (final item in mapping.$2) append(item);
      return;
    }
    final combining = _jCombiningClasses[cp] ?? 0;
    var position = decomposed.length;
    if (combining != 0) {
      while (position > 0) {
        final previous = _jCombiningClasses[decomposed[position - 1]] ?? 0;
        if (previous == 0 || previous <= combining) break;
        position--;
      }
    }
    decomposed.insert(position, cp);
  }

  // Dart's runes replace lone surrogates, whereas JavaScript preserves them.
  for (var index = 0; index < text.length; index++) {
    final first = text.codeUnitAt(index);
    if (jHighSurrogate(first) &&
        index + 1 < text.length &&
        jLowSurrogate(text.codeUnitAt(index + 1))) {
      append(
        0x10000 + ((first - 0xd800) << 10) + text.codeUnitAt(++index) - 0xdc00,
      );
    } else {
      append(first);
    }
  }
  if (form == 'NFD' || form == 'NFKD' || decomposed.isEmpty) {
    return String.fromCharCodes(decomposed);
  }
  final result = <int>[decomposed.first];
  var starterPosition = 0, starter = decomposed.first, lastClass = 0;
  for (final cp in decomposed.skip(1)) {
    final combining = _jCombiningClasses[cp] ?? 0;
    final composite = _jCompose(starter, cp);
    if (composite != null && (lastClass == 0 || lastClass < combining)) {
      result[starterPosition] = starter = composite;
    } else {
      if (combining == 0) {
        starterPosition = result.length;
        starter = cp;
      }
      result.add(cp);
      lastClass = combining;
    }
  }
  return String.fromCharCodes(result);
}
