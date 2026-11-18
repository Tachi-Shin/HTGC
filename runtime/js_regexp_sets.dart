part of 'js_core.dart';

// A UnicodeSets class denotes code points plus a finite set of strings.
// Keep these separate so subtraction compares whole strings, including "".
class _RegExpSet {
  final String? character;
  final Set<String> strings;
  final bool mayContainStrings;
  const _RegExpSet(
    this.character, [
    this.strings = const {},
    this.mayContainStrings = false,
  ]);

  static _RegExpSet union(List<_RegExpSet> sets) {
    final atoms = [
      for (final set in sets)
        if (set.character != null) set.character!,
    ];
    return _RegExpSet(atoms.isEmpty ? null : '(?:${atoms.join('|')})', {
      for (final set in sets) ...set.strings,
    }, sets.any((set) => set.mayContainStrings));
  }

  _RegExpSet combine(_RegExpSet other, {required bool subtract}) {
    final a = character, b = other.character;
    final chars = a == null || b == null
        ? (subtract ? a : null)
        : subtract
        ? '(?:(?!$b)$a)'
        : '(?:(?=$b)$a)';
    return _RegExpSet(
      chars,
      subtract
          ? strings.difference(other.strings)
          : strings.intersection(other.strings),
      mayContainStrings && (subtract || other.mayContainStrings),
    );
  }

  _RegExpSet complement() {
    if (mayContainStrings) _invalidSet();
    return _RegExpSet(
      character == null
          ? r'[\s\S]'
          : '(?:(?!$character)'
                r'[\s\S])',
    );
  }

  String pattern() {
    final words = strings.where((s) => s.isNotEmpty).toList()
      ..sort((a, b) => b.runes.length.compareTo(a.runes.length));
    final choices = [
      for (final word in words) RegExp.escape(word),
      if (character != null) character,
      if (strings.contains('')) '',
    ];
    return choices.isEmpty ? '(?:(?!))' : '(?:${choices.join('|')})';
  }
}

Never _invalidSet() =>
    throw JThrown(JError('SyntaxError', 'Invalid Unicode sets pattern'));

int _foldRegExpPoint(int point) {
  var lo = 0, hi = _regexpFolds.length ~/ 3;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2, index = mid * 3;
    if (point < _regexpFolds[index]) {
      hi = mid;
    } else if (point > _regexpFolds[index + 1]) {
      lo = mid + 1;
    } else {
      return point + _regexpFolds[index + 2];
    }
  }
  return point;
}

class _RegExpSetParser {
  final String source;
  final bool ignoreCase;
  int at = 0;
  _RegExpSetParser(this.source, this.ignoreCase);

  bool atText(String text) => source.startsWith(text, at);
  bool take(String text) {
    if (!atText(text)) return false;
    at += text.length;
    return true;
  }

  static String atom(int point) => r'\u{' + point.toRadixString(16) + '}';
  int nextPoint() {
    if (at >= source.length) _invalidSet();
    final first = source.codeUnitAt(at++);
    if (first >= 0xd800 && first <= 0xdbff && at < source.length) {
      final next = source.codeUnitAt(at);
      if (next >= 0xdc00 && next <= 0xdfff) {
        at++;
        return 0x10000 + ((first - 0xd800) << 10) + next - 0xdc00;
      }
    }
    return first;
  }

  int hex(int count) {
    if (at + count > source.length) _invalidSet();
    final text = source.substring(at, at + count);
    if (!RegExp(r'^[a-fA-F0-9]+$').hasMatch(text)) _invalidSet();
    at += count;
    return int.parse(text, radix: 16);
  }

  int character() {
    const syntax = r'()[]{}/-\|';
    const reserved = r'&!#%,:;<=>@`~';
    const doubled = r'&!#$%*+,.:;<=>?@^`~';
    if (!take(r'\')) {
      final point = nextPoint(), s = String.fromCharCode(point);
      if (syntax.contains(s) || doubled.contains(s) && atText(s)) _invalidSet();
      return point;
    }
    if (take('u')) {
      if (take('{')) {
        final end = source.indexOf('}', at);
        if (end == -1 || at == end) _invalidSet();
        final digits = source.substring(at, end);
        if (!RegExp(r'^[a-fA-F0-9]+$').hasMatch(digits)) _invalidSet();
        final n = int.tryParse(digits, radix: 16);
        if (n == null || n < 0 || n > 0x10ffff) _invalidSet();
        at = end + 1;
        return n;
      }
      final point = hex(4);
      if (point >= 0xd800 &&
          point <= 0xdbff &&
          atText(r'\u') &&
          !atText(r'\u{')) {
        final saved = at;
        at += 2;
        final low = hex(4);
        if (low >= 0xdc00 && low <= 0xdfff)
          return 0x10000 + ((point - 0xd800) << 10) + low - 0xdc00;
        at = saved;
      }
      return point;
    }
    if (take('x')) return hex(2);
    if (take('c')) {
      final cp = nextPoint();
      if (!(cp >= 65 && cp <= 90 || cp >= 97 && cp <= 122)) _invalidSet();
      return cp % 32;
    }
    final point = nextPoint(), s = String.fromCharCode(point);
    const controls = {
      't': 9,
      'n': 10,
      'v': 11,
      'f': 12,
      'r': 13,
      'b': 8,
      '0': 0,
    };
    if (s == '0' && at < source.length && '0123456789'.contains(source[at]))
      _invalidSet();
    if (controls.containsKey(s)) return controls[s]!;
    if (!syntax.contains(s) && !reserved.contains(s) && !r'^$.*+?'.contains(s))
      _invalidSet();
    return point;
  }

  _RegExpSet words() {
    final characters = <_RegExpSet>[], strings = <String>{};
    do {
      final points = <int>[];
      while (!atText('|') && !atText('}')) points.add(character());
      if (points.length == 1) {
        characters.add(_RegExpSet(atom(points.single)));
      } else {
        strings.add(
          String.fromCharCodes(
            ignoreCase ? points.map(_foldRegExpPoint) : points,
          ),
        );
      }
    } while (take('|'));
    if (!take('}')) _invalidSet();
    return _RegExpSet(
      _RegExpSet.union(characters).character,
      strings,
      strings.isNotEmpty,
    );
  }

  _RegExpSet property() {
    final negative = atText(r'\P');
    at += 2;
    if (!take('{')) _invalidSet();
    final end = source.indexOf('}', at);
    if (end < 0) _invalidSet();
    final name = source.substring(at, end);
    at = end + 1;
    if (name == 'RGI_Emoji' || _emojiStringProperties.containsKey(name)) {
      if (negative) _invalidSet();
      final parts = name == 'RGI_Emoji'
          ? _emojiStringProperties.values
          : [_emojiStringProperties[name]!];
      return _RegExpSet.union([
        for (final (chars, words) in parts)
          _RegExpSet(
            chars == '[]' ? null : chars,
            words.split(' ').toSet(),
            true,
          ),
      ]);
    }
    final pattern = '\\p{$name}';
    try {
      RegExp(pattern, unicode: true);
    } on FormatException {
      _invalidSet();
    }
    final set = _RegExpSet(pattern);
    return negative ? set.complement() : set;
  }

  (_RegExpSet, int?) operand() {
    if (take('[')) return (group(), null);
    if (take(r'\q{')) return (words(), null);
    if (atText(r'\p') || atText(r'\P')) return (property(), null);
    if (atText(r'\') &&
        at + 1 < source.length &&
        'dDsSwW'.contains(source[at + 1])) {
      final token = source.substring(at, at + 2);
      at += 2;
      return (_RegExpSet(token), null);
    }
    final point = character();
    return (_RegExpSet(atom(point)), point);
  }

  _RegExpSet group() {
    final negate = take('^'), parts = <_RegExpSet>[];
    String? operation;
    while (!take(']')) {
      final (item, low) = operand();
      var current = item;
      if (atText('-') && !atText('--')) {
        at++;
        if (low == null || operation != null) _invalidSet();
        final high = character();
        if (high < low || atText('&&') || atText('--')) _invalidSet();
        current = _RegExpSet('[${atom(low)}-${atom(high)}]');
      }
      parts.add(current);
      if (atText('&&') || atText('--')) {
        final next = source.substring(at, at + 2);
        if (operation == null && parts.length != 1 ||
            operation != null && operation != next)
          _invalidSet();
        operation = next;
        at += 2;
        if (atText(']') || atText(next[0])) _invalidSet();
      } else if (!atText(']') && operation != null) {
        _invalidSet();
      }
    }
    final set = operation == null
        ? _RegExpSet.union(parts)
        : parts.reduce((a, b) => a.combine(b, subtract: operation == '--'));
    return negate ? set.complement() : set;
  }

  String lower() {
    final out = StringBuffer();
    while (at < source.length) {
      if (take('[')) {
        out.write(group().pattern());
      } else if (atText(r'\p') || atText(r'\P')) {
        out.write(property().pattern());
      } else if (take(r'\')) {
        if (at >= source.length) _invalidSet();
        out.write(r'\');
        out.write(source[at++]);
      } else {
        out.write(source[at++]);
      }
    }
    return out.toString();
  }
}
