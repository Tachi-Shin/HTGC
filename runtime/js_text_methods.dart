part of 'js_core.dart';

bool jHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;
bool jLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;
bool jIsPaired(String source, int index) {
  final unit = source.codeUnitAt(index);
  if (jHighSurrogate(unit)) {
    return index + 1 < source.length &&
        jLowSurrogate(source.codeUnitAt(index + 1));
  }
  return jLowSurrogate(unit) &&
      index > 0 &&
      jHighSurrogate(source.codeUnitAt(index - 1));
}

final jStringMethods = jBuildStringMethods();

Map<String, JFunction> jBuildStringMethods() {
  final methods = <String, JFunction>{};
  void add(
    String name,
    int arity,
    dynamic Function(String, List<dynamic>) run,
  ) {
    methods[name] = jNamedFunction(
      JFunction(
        (args, receiver) => run(jString(jRequireCoercible(receiver)), args),
        constructible: false,
      ),
      name,
      arity,
    );
  }

  for (final name in ['at', 'charAt', 'charCodeAt', 'codePointAt']) {
    add(name, 1, (text, args) {
      var index = jInteger(jArg(args, 0));
      if (name == 'at' && index < 0) index += text.length;
      if (index < 0 || index >= text.length) {
        return name == 'charAt'
            ? ''
            : name == 'charCodeAt'
            ? double.nan
            : jUndefined;
      }
      final i = index.toInt();
      final first = text.codeUnitAt(i);
      if (name == 'charCodeAt') return first.toDouble();
      if (name == 'codePointAt') {
        if (jHighSurrogate(first) && i + 1 < text.length) {
          final next = text.codeUnitAt(i + 1);
          if (jLowSurrogate(next))
            return (0x10000 + ((first - 0xd800) << 10) + next - 0xdc00)
                .toDouble();
        }
        return first.toDouble();
      }
      return text[i];
    });
  }
  add('normalize', 0, (text, args) => jNormalize(text, jArg(args, 0)));
  add('concat', 1, (text, args) => text + args.map(jString).join());
  for (final name in [
    'includes',
    'startsWith',
    'endsWith',
    'indexOf',
    'lastIndexOf',
  ]) {
    add(name, 1, (text, args) {
      final input = jArg(args, 0);
      final searchOnly = name == 'indexOf' || name == 'lastIndexOf';
      if (!searchOnly && jIsRegExp(input)) {
        throw JThrown(JError('TypeError', 'Search value cannot be a RegExp'));
      }
      final search = jString(input);
      final end = name == 'endsWith' && identical(jArg(args, 1), jUndefined);
      final backwards = name == 'lastIndexOf';
      final number = end
          ? text.length.toDouble()
          : backwards
          ? jNumber(jArg(args, 1))
          : jInteger(jArg(args, 1));
      final position = (backwards && number.isNaN ? text.length : number)
          .clamp(0, text.length)
          .toInt();
      switch (name) {
        case 'includes':
          return text.indexOf(search, position) >= 0;
        case 'startsWith':
          return text.startsWith(search, position);
        case 'endsWith':
          return position >= search.length &&
              text.startsWith(search, position - search.length);
        case 'lastIndexOf':
          return text.lastIndexOf(search, position).toDouble();
        default:
          return text.indexOf(search, position).toDouble();
      }
    });
  }
  for (final name in ['slice', 'substring']) {
    add(name, 2, (text, args) {
      int index(dynamic value) => name == 'slice'
          ? jRelativeIndex(value, text.length)
          : jInteger(value).clamp(0, text.length).toInt();
      final start = index(jArg(args, 0));
      final end = identical(jArg(args, 1), jUndefined)
          ? text.length
          : index(args[1]);
      if (end >= start) return text.substring(start, end);
      return name == 'slice' ? '' : text.substring(end, start);
    });
  }
  for (final left in [true, false]) {
    add(left ? 'padStart' : 'padEnd', 1, (text, args) {
      final missing = jLength(jArg(args, 0)) - text.length;
      if (missing <= 0) return text;
      final fill = identical(jArg(args, 1), jUndefined)
          ? ' '
          : jString(args[1]);
      if (fill.isEmpty) return text;
      jCheckStringLength(text.length + missing);
      final padding =
          fill * (missing ~/ fill.length) +
          fill.substring(0, missing % fill.length);
      return left ? padding + text : text + padding;
    });
  }
  add('repeat', 1, (text, args) {
    final times = jInteger(jArg(args, 0));
    if (!times.isFinite || times < 0)
      throw JThrown(JError('RangeError', 'Invalid repeat count'));
    if (text.isEmpty) return '';
    jCheckStringLength(text.length * times);
    return text * times.toInt();
  });
  final spaces =
      r'[\x09-\x0D\x20\xA0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]';
  final leading = RegExp('^$spaces+'), trailing = RegExp('$spaces+\$');
  add(
    'trim',
    0,
    (text, args) => text.replaceFirst(leading, '').replaceFirst(trailing, ''),
  );
  add('trimStart', 0, (text, args) => text.replaceFirst(leading, ''));
  add('trimEnd', 0, (text, args) => text.replaceFirst(trailing, ''));
  methods['trimLeft'] = methods['trimStart']!;
  methods['trimRight'] = methods['trimEnd']!;
  add('toLowerCase', 0, (text, args) => text.toLowerCase());
  add('toUpperCase', 0, (text, args) => text.toUpperCase());
  add('toLocaleLowerCase', 0, (text, args) => text.toLowerCase());
  add('toLocaleUpperCase', 0, (text, args) => text.toUpperCase());
  add(
    'localeCompare',
    1,
    (text, args) => text.compareTo(jString(jArg(args, 0))).sign.toDouble(),
  );
  add('isWellFormed', 0, (text, args) {
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if ((jHighSurrogate(unit) || jLowSurrogate(unit)) && !jIsPaired(text, i))
        return false;
    }
    return true;
  });
  add('toWellFormed', 0, (text, args) {
    final output = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      output.writeCharCode(
        (jHighSurrogate(unit) || jLowSurrogate(unit)) && !jIsPaired(text, i)
            ? 0xfffd
            : unit,
      );
    }
    return output.toString();
  });
  add('substr', 2, (text, args) {
    final start = jRelativeIndex(jArg(args, 0), text.length);
    final size = identical(jArg(args, 1), jUndefined)
        ? text.length - start
        : jInteger(args[1]).clamp(0, text.length - start).toInt();
    return text.substring(start, start + size);
  });
  final wrappers = {
    'anchor': ('a', 'name'),
    'big': ('big', ''),
    'blink': ('blink', ''),
    'bold': ('b', ''),
    'fixed': ('tt', ''),
    'fontcolor': ('font', 'color'),
    'fontsize': ('font', 'size'),
    'italics': ('i', ''),
    'link': ('a', 'href'),
    'small': ('small', ''),
    'strike': ('strike', ''),
    'sub': ('sub', ''),
    'sup': ('sup', ''),
  };
  for (final entry in wrappers.entries) {
    final (tag, attribute) = entry.value;
    add(entry.key, attribute.isEmpty ? 0 : 1, (text, args) {
      if (attribute.isEmpty) return '<$tag>$text</$tag>';
      final value = jString(jArg(args, 0)).replaceAll('"', '&quot;');
      return '<$tag $attribute="$value">$text</$tag>';
    });
  }
  return methods;
}

void jCheckStringLength(num length) {
  if (length > 0x1fffffe8)
    throw JThrown(JError('RangeError', 'String length out of range'));
}

String jStringRaw(List<dynamic> args) {
  final raw = jObject(jRequireCoercible(jGet(jArg(args, 0), 'raw')));
  final length = jLength(jGet(raw, 'length'));
  final output = StringBuffer();
  for (var i = 0; i < length; i++) {
    output.write(jString(jGet(raw, i)));
    if (i + 1 < length && i + 1 < args.length)
      output.write(jString(args[i + 1]));
  }
  return output.toString();
}

const _uriUnescaped =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()";
const _uriReserved = r";/?:@&=+$,#";
String jPercentHex(int value, int digits) =>
    value.toRadixString(16).toUpperCase().padLeft(digits, '0');

Never jInvalidUri() => throw JThrown(JError('URIError', 'Malformed URI'));

String jEncodeUri(String source, bool component) {
  for (var i = 0; i < source.length; i++) {
    final unit = source.codeUnitAt(i);
    if ((jHighSurrogate(unit) || jLowSurrogate(unit)) && !jIsPaired(source, i))
      jInvalidUri();
  }
  final allowed = component ? _uriUnescaped : _uriUnescaped + _uriReserved;
  final output = StringBuffer();
  for (final byte in utf8.encode(source)) {
    final character = String.fromCharCode(byte);
    output.write(
      allowed.contains(character) ? character : '%${jPercentHex(byte, 2)}',
    );
  }
  return output.toString();
}

String jDecodeUri(String source, bool component) {
  final output = StringBuffer();
  final hexDigits = RegExp(r'^[0-9a-fA-F]{2}$');
  int byteAt(int index) {
    if (index + 2 >= source.length || source[index] != '%') jInvalidUri();
    final hex = source.substring(index + 1, index + 3);
    if (!hexDigits.hasMatch(hex)) jInvalidUri();
    return int.parse(hex, radix: 16);
  }

  for (var i = 0; i < source.length;) {
    if (source[i] != '%') {
      output.writeCharCode(source.codeUnitAt(i++));
      continue;
    }
    final first = byteAt(i);
    final size = first < 0x80
        ? 1
        : first < 0xc2
        ? 0
        : first < 0xe0
        ? 2
        : first < 0xf0
        ? 3
        : first < 0xf5
        ? 4
        : 0;
    if (size == 0) jInvalidUri();
    final bytes = [first, for (var j = 1; j < size; j++) byteAt(i + j * 3)];
    try {
      final value = utf8.decode(bytes);
      output.write(
        !component && size == 1 && _uriReserved.contains(value)
            ? source.substring(i, i + 3)
            : value,
      );
    } on FormatException {
      jInvalidUri();
    }
    i += size * 3;
  }
  return output.toString();
}

String jLegacyEscape(String source, bool decode) {
  final output = StringBuffer();
  if (!decode) {
    const allowed =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@*_+-./';
    for (final unit in source.codeUnits) {
      final char = String.fromCharCode(unit);
      output.write(
        allowed.contains(char)
            ? char
            : unit <= 255
            ? '%${jPercentHex(unit, 2)}'
            : '%u${jPercentHex(unit, 4)}',
      );
    }
    return output.toString();
  }
  return source.replaceAllMapped(
    RegExp(r'%u([0-9a-fA-F]{4})|%([0-9a-fA-F]{2})'),
    (match) => String.fromCharCode(int.parse(match[1] ?? match[2]!, radix: 16)),
  );
}

class JTemplateArray extends JArray {
  JTemplateArray(super.items, {List<dynamic>? raw}) {
    if (raw != null) {
      extra.properties['raw'] = JTemplateArray(raw);
      extra.flags['raw'] = JPropertyFlags(
        writable: false,
        enumerable: false,
        configurable: false,
      );
    }
    extra.extensible = false;
  }
}

Iterable<String> jForInKeys(dynamic input) sync* {
  if (jNullish(input)) return;
  dynamic object = jObject(input);
  final seen = <String>{};
  final prototypes = HashSet<dynamic>.identity();
  while (object != null && prototypes.add(object)) {
    for (final key in jOwnKeys(object, strings: true)) {
      if (key is! String || seen.contains(key)) continue;
      final descriptor = jDescriptor(object, key);
      if (descriptor is JObject) {
        seen.add(key);
        if (jTruthy(jGet(descriptor, 'enumerable'))) yield key;
      }
    }
    object = jPrototype(object);
  }
}
