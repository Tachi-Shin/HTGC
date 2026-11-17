part of 'js_core.dart';

class JArray extends ListBase<dynamic> {
  final List<dynamic> items;
  final JObject extra = JObject();
  JArray(this.items);
  @override
  int get length => items.length;
  @override
  set length(int value) {
    while (items.length < value) items.add(_jHole);
    items.length = value;
  }

  @override
  dynamic operator [](int index) => items[index];
  @override
  void operator []=(int index, dynamic value) {
    items[index] = value;
  }
}

final jRegExpPrototype = JObject();

class JRegex extends JObject {
  String pattern, flagText;
  late RegExp value;
  final List<int> captureIndices = [];
  final Map<String, int> names = {};
  String marker = 'HTGCpos';
  JRegex(this.pattern, this.flagText) {
    final flags = flagText;
    prototype = jRegExpPrototype;
    if (flags.split('').any((c) => !'dgimsuvy'.contains(c)) ||
        flags.split('').toSet().length != flags.length ||
        flags.contains('u') && flags.contains('v'))
      throw JThrown(JError('SyntaxError', 'Invalid regular expression flags'));
    if (flags.contains('v'))
      throw JThrown(
        JError(
          'SyntaxError',
          'Unicode set notation is not implemented by this runtime',
        ),
      );
    try {
      value = RegExp(
        pattern,
        caseSensitive: !flags.contains('i'),
        multiLine: flags.contains('m'),
        dotAll: flags.contains('s'),
        unicode: flags.contains('u'),
      );
      if (flags.contains('d'))
        value = RegExp(
          instrument(),
          caseSensitive: !flags.contains('i'),
          multiLine: flags.contains('m'),
          dotAll: flags.contains('s'),
          unicode: flags.contains('u'),
        );
    } on FormatException catch (e) {
      throw JThrown(JError('SyntaxError', e.message));
    }
    properties['lastIndex'] = 0.0;
    flagsForLastIndex();
  }
  void flagsForLastIndex() {
    super.flags['lastIndex'] = JPropertyFlags(
      enumerable: false,
      configurable: false,
    );
  }

  String get source => pattern.isEmpty
      ? '(?:)'
      : pattern.replaceAllMapped(RegExp(r'\\[\s\S]|/|[\n\r\u2028\u2029]'), (m) {
          final v = m[0]!;
          if (v.startsWith('\\')) return v;
          return v == '/'
              ? r'\/'
              : v == '\n'
              ? r'\n'
              : v == '\r'
              ? r'\r'
              : v == '\u2028'
              ? r'\u2028'
              : r'\u2029';
        });
  String instrument() {
    while (pattern.contains(marker)) marker += 'X';
    final tokens = <String>[], stack = <int>[], mapping = <int, int>{};
    var inClass = false, original = 0, native = 0;
    for (var i = 0; i < pattern.length; i++) {
      final c = pattern[i];
      if (c == '\\') {
        var end = i + 2;
        if (end <= pattern.length &&
            !inClass &&
            RegExp(r'[1-9]').hasMatch(pattern[i + 1]))
          while (end < pattern.length &&
              RegExp(r'[0-9]').hasMatch(pattern[end]))
            end++;
        tokens.add(pattern.substring(i, math.min(end, pattern.length)));
        i = end - 1;
        continue;
      }
      if (c == '[') inClass = true;
      if (c == ']') inClass = false;
      if (!inClass && c == '(') {
        final capturing =
            i + 1 == pattern.length ||
            pattern[i + 1] != '?' ||
            pattern.startsWith('(?<', i) &&
                !pattern.startsWith('(?<=', i) &&
                !pattern.startsWith('(?<!', i);
        if (capturing) {
          original++;
          native++;
          mapping[original] = native;
          captureIndices.add(native);
          stack.add(original);
          if (pattern.startsWith('(?<', i)) {
            final end = pattern.indexOf('>', i + 3);
            names[pattern.substring(i + 3, end)] = original;
            tokens.add(pattern.substring(i, end + 1));
            i = end;
          } else
            tokens.add('(');
          tokens.add('(?=(?<$marker${original}S>[\\s\\S]*))(?:');
          native++;
        } else {
          stack.add(0);
          tokens.add(c);
        }
      } else if (!inClass && c == ')') {
        final group = stack.removeLast();
        if (group != 0) {
          tokens.add(')(?=(?<$marker${group}E>[\\s\\S]*))');
          native++;
        }
        tokens.add(c);
      } else
        tokens.add(c);
    }
    return tokens.map((token) {
      if (!RegExp(r'^\\[1-9][0-9]*$').hasMatch(token)) return token;
      final n = int.parse(token.substring(1));
      if (mapping.containsKey(n)) return '\\${mapping[n]}';
      final octal = RegExp(r'^\\([0-3][0-7]{0,2}|[4-7][0-7]?)')
          .firstMatch(token);
      if (octal != null)
        return '\\x${int.parse(octal[1]!, radix: 8).toRadixString(16).padLeft(2, '0')}${token.substring(octal.end)}';
      return token.substring(1);
    }).join();
  }
}

int jLength(dynamic value) {
  final n = jInteger(value);
  return n <= 0 ? 0 : math.min(n, 9007199254740991).toInt();
}

String jRegexEscape(dynamic input) {
  if (input is! String)
    throw JThrown(JError('TypeError', 'RegExp.escape requires a string'));
  final result = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    final c = input[i], code = input.codeUnitAt(i);
    if (i == 0 &&
        (code >= 48 && code <= 57 ||
            code >= 65 && code <= 90 ||
            code >= 97 && code <= 122))
      result.write('\\x${code.toRadixString(16).padLeft(2, '0')}');
    else if (r'^$\.*+?()[]{}|/'.contains(c))
      result.write('\\$c');
    else if ({
      12: r'\f',
      10: r'\n',
      13: r'\r',
      9: r'\t',
      11: r'\v',
    }.containsKey(code))
      result.write(
        {12: r'\f', 10: r'\n', 13: r'\r', 9: r'\t', 11: r'\v'}[code],
      );
    else if (",-=<>#&!%:;@~'`\" ".contains(c))
      result.write('\\x${code.toRadixString(16).padLeft(2, '0')}');
    else if (code >= 0xd800 &&
        code <= 0xdbff &&
        i + 1 < input.length &&
        input.codeUnitAt(i + 1) >= 0xdc00 &&
        input.codeUnitAt(i + 1) <= 0xdfff) {
      result.write(input.substring(i, i + 2));
      i++;
    } else if (code >= 0xd800 && code <= 0xdfff ||
        RegExp(
          r'[\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]',
        ).hasMatch(c))
      result.write('\\u${code.toRadixString(16).padLeft(4, '0')}');
    else
      result.write(c);
  }
  return result.toString();
}

int jAdvanceString(String value, int index, bool unicode) {
  if (!unicode || index + 1 >= value.length) return index + 1;
  final a = value.codeUnitAt(index), b = value.codeUnitAt(index + 1);
  return a >= 0xd800 && a <= 0xdbff && b >= 0xdc00 && b <= 0xdfff
      ? index + 2
      : index + 1;
}

bool jIsRegExp(dynamic value) {
  if (!jIsObject(value)) return false;
  final match = jGet(value, jSymbols['match']);
  return identical(match, jUndefined) ? value is JRegex : jTruthy(match);
}

dynamic jRegexBuiltinExec(JRegex regex, String input) {
  final start = jLength(regex.get('lastIndex')),
      stateful = regex.flagText.contains('g') || regex.flagText.contains('y');
  final offset = stateful ? start : 0;
  if (offset > input.length) {
    if (stateful) regex.set('lastIndex', 0.0);
    return null;
  }
  RegExpMatch? match;
  final matches = regex.value.allMatches(input, offset);
  if (matches.isNotEmpty) match = matches.first;
  if (match == null || regex.flagText.contains('y') && match.start != offset) {
    if (stateful) regex.set('lastIndex', 0.0);
    return null;
  }
  if (stateful) regex.set('lastIndex', match.end.toDouble());
  final captures = regex.flagText.contains('d')
      ? regex.captureIndices
      : [for (var i = 1; i <= match.groupCount; i++) i];
  final result = JArray([
    match[0],
    for (final i in captures) match[i] ?? jUndefined,
  ]);
  result.extra.properties.addAll({
    'index': match.start.toDouble(),
    'input': input,
  });
  final names = regex.flagText.contains('d')
      ? regex.names.keys
      : match.groupNames;
  final groups = JObject.root();
  for (final name in names)
    groups.properties[name] = match.namedGroup(name) ?? jUndefined;
  result.extra.properties['groups'] = names.isEmpty ? jUndefined : groups;
  if (regex.flagText.contains('d')) {
    final indices = JArray([
          <dynamic>[match.start.toDouble(), match.end.toDouble()],
        ]),
        named = JObject.root();
    for (var i = 1; i <= captures.length; i++) {
      final start = match.namedGroup('${regex.marker}${i}S'),
          end = match.namedGroup('${regex.marker}${i}E');
      indices.add(
        start == null || end == null
            ? jUndefined
            : <dynamic>[
                (input.length - start.length).toDouble(),
                (input.length - end.length).toDouble(),
              ],
      );
    }
    for (final entry in regex.names.entries)
      named.properties[entry.key] = indices[entry.value];
    indices.extra.properties['groups'] = regex.names.isEmpty
        ? jUndefined
        : named;
    result.extra.properties['indices'] = indices;
  }
  return result;
}

dynamic jRegexExec(dynamic regex, String input) {
  final exec = jGet(regex, 'exec');
  if (exec is JFunction) {
    final result = jCall(exec, [input], receiver: regex);
    if (result != null && !jIsObject(result))
      throw JThrown(
        JError('TypeError', 'RegExp exec result must be an object or null'),
      );
    return result;
  }
  if (regex is! JRegex) throw JThrown(JError('TypeError', 'RegExp required'));
  return jRegexBuiltinExec(regex, input);
}

String jSubstitute(
  String replacement,
  String input,
  int position,
  String match,
  List<dynamic> captures,
  dynamic groups,
) {
  final result = StringBuffer();
  for (var i = 0; i < replacement.length; i++) {
    if (replacement[i] != '\$' || i + 1 == replacement.length) {
      result.write(replacement[i]);
      continue;
    }
    final c = replacement[i + 1];
    if (c == '\$') {
      result.write('\$');
      i++;
    } else if (c == '&') {
      result.write(match);
      i++;
    } else if (c == '`') {
      result.write(input.substring(0, position));
      i++;
    } else if (c == "'") {
      result.write(
        input.substring(math.min(input.length, position + match.length)),
      );
      i++;
    } else if (c == '<' &&
        !identical(groups, jUndefined) &&
        replacement.indexOf('>', i + 2) != -1) {
      final end = replacement.indexOf('>', i + 2),
          name = replacement.substring(i + 2, end),
          value = jGet(groups, name);
      result.write(identical(value, jUndefined) ? '' : jString(value));
      i = end;
    } else {
      var n = int.tryParse(c) ?? -1, consumed = 1;
      if (n >= 0 && i + 2 < replacement.length) {
        final digit = int.tryParse(replacement[i + 2]);
        if (digit != null &&
            n * 10 + digit > 0 &&
            n * 10 + digit <= captures.length) {
          n = n * 10 + digit;
          consumed = 2;
        }
      }
      if (n > 0 && n <= captures.length) {
        final value = captures[n - 1];
        result.write(identical(value, jUndefined) ? '' : jString(value));
        i += consumed;
      } else
        result.write('\$');
    }
  }
  return result.toString();
}

dynamic jRegexMatch(dynamic regex, String input) {
  if (!jTruthy(jGet(regex, 'global'))) return jRegexExec(regex, input);
  final unicode =
      jTruthy(jGet(regex, 'unicode')) || jTruthy(jGet(regex, 'unicodeSets'));
  jSet(regex, 'lastIndex', 0.0);
  final values = <dynamic>[];
  while (true) {
    final match = jRegexExec(regex, input);
    if (match == null) return values.isEmpty ? null : values;
    final text = jString(jGet(match, 0));
    values.add(text);
    if (text.isEmpty)
      jSet(
        regex,
        'lastIndex',
        jAdvanceString(
          input,
          jLength(jGet(regex, 'lastIndex')),
          unicode,
        ).toDouble(),
      );
  }
}

dynamic jRegexReplace(dynamic regex, String input, dynamic replacement) {
  final functional = replacement is JFunction,
      text = functional ? '' : jString(replacement),
      global = jTruthy(jGet(regex, 'global'));
  final unicode =
      global &&
      (jTruthy(jGet(regex, 'unicode')) || jTruthy(jGet(regex, 'unicodeSets')));
  if (global) jSet(regex, 'lastIndex', 0.0);
  final matches = <dynamic>[];
  while (true) {
    final result = jRegexExec(regex, input);
    if (result == null) break;
    matches.add(result);
    if (!global) break;
    if (jString(jGet(result, 0)).isEmpty)
      jSet(
        regex,
        'lastIndex',
        jAdvanceString(
          input,
          jLength(jGet(regex, 'lastIndex')),
          unicode,
        ).toDouble(),
      );
  }
  var next = 0;
  final output = StringBuffer();
  for (final result in matches) {
    final length = jLength(jGet(result, 'length')),
        matched = jString(jGet(result, 0)),
        position = jInteger(jGet(result, 'index'))
            .clamp(0, input.length)
            .toInt();
    final captures = [
          for (var i = 1; i < length; i++)
            identical(jGet(result, i), jUndefined)
                ? jUndefined
                : jString(jGet(result, i)),
        ],
        groups = jGet(result, 'groups');
    final replaced = functional
        ? jString(
            jCall(replacement, [
              matched,
              ...captures,
              position.toDouble(),
              input,
              if (!identical(groups, jUndefined)) groups,
            ]),
          )
        : jSubstitute(
            text,
            input,
            position,
            matched,
            captures,
            identical(groups, jUndefined) ? groups : jObject(groups),
          );
    if (position >= next) {
      output.write(input.substring(next, position));
      output.write(replaced);
      next = position + matched.length;
    }
  }
  output.write(input.substring(math.min(next, input.length)));
  return output.toString();
}

dynamic jRegexSplit(JRegex regex, String input, dynamic limitValue) {
  final limit = identical(limitValue, jUndefined)
          ? 0xffffffff
          : jUint32(limitValue),
      out = <dynamic>[];
  if (limit == 0) return out;
  final splitter = JRegex(
    regex.pattern,
    regex.flagText.contains('y') ? regex.flagText : '${regex.flagText}y',
  );
  if (input.isEmpty)
    return jRegexExec(splitter, input) == null ? <dynamic>[''] : out;
  var p = 0, q = 0;
  while (q < input.length) {
    splitter.set('lastIndex', q.toDouble());
    final match = jRegexExec(splitter, input);
    if (match == null) {
      q = jAdvanceString(input, q, regex.flagText.contains('u'));
      continue;
    }
    final end = math.min(jLength(splitter.get('lastIndex')), input.length);
    if (end == p) {
      q = jAdvanceString(input, q, regex.flagText.contains('u'));
      continue;
    }
    out.add(input.substring(p, q));
    if (out.length == limit) return out;
    p = end;
    for (var i = 1; i < jLength(jGet(match, 'length')); i++) {
      out.add(jGet(match, i));
      if (out.length == limit) return out;
    }
    q = p;
  }
  out.add(input.substring(p));
  return out;
}

JObject jRegexMatchAll(JRegex source, String input) {
  final regex = JRegex(source.pattern, source.flagText)
    ..set('lastIndex', jLength(source.get('lastIndex')).toDouble());
  final iterator = JObject();
  var done = false;
  iterator.properties['next'] = jBuiltin((a) {
    if (done) return JObject({'value': jUndefined, 'done': true});
    final result = jRegexExec(regex, input);
    if (result == null) {
      done = true;
      return JObject({'value': jUndefined, 'done': true});
    }
    if (!regex.flagText.contains('g'))
      done = true;
    else if (jString(jGet(result, 0)).isEmpty)
      regex.set(
        'lastIndex',
        jAdvanceString(
          input,
          jLength(regex.get('lastIndex')),
          regex.flagText.contains('u'),
        ).toDouble(),
      );
    return JObject({'value': result, 'done': false});
  });
  iterator.symbols[jSymbols['iterator']!] = jBuiltin((a) => iterator);
  return iterator;
}

dynamic jStringRegExp(String operation, String input, List<dynamic> args) {
  final pattern = jArg(args, 0), argument = jArg(args, 1);
  if (!jNullish(pattern)) {
    if ((operation == 'matchAll' || operation == 'replaceAll') &&
        jIsRegExp(pattern) &&
        !jString(jRequireCoercible(jGet(pattern, 'flags'))).contains('g'))
      throw JThrown(JError('TypeError', 'Global RegExp required'));
    final symbol = jSymbols[operation == 'replaceAll' ? 'replace' : operation];
    final method = symbol == null ? jUndefined : jGet(pattern, symbol);
    if (!jNullish(method))
      return jCall(method, [
        input,
        if (operation == 'split' || operation.startsWith('replace')) argument,
      ], receiver: pattern);
  }
  if (operation == 'match' ||
      operation == 'search' ||
      operation == 'matchAll') {
    final regex = JRegex(
      identical(pattern, jUndefined) ? '' : jString(pattern),
      operation == 'matchAll' ? 'g' : '',
    );
    return jCall(jGet(regex, jSymbols[operation]), [input], receiver: regex);
  }
  if (operation == 'split') {
    final limit = identical(argument, jUndefined)
        ? 0xffffffff
        : jUint32(argument);
    if (limit == 0) return <dynamic>[];
    if (identical(pattern, jUndefined)) return <dynamic>[input];
    final separator = jString(pattern);
    return (separator.isEmpty
            ? [for (var i = 0; i < input.length; i++) input[i]]
            : input.split(separator))
        .take(limit)
        .toList();
  }
  final needle = jString(pattern),
      functional = argument is JFunction,
      replacement = functional ? '' : jString(argument);
  final output = StringBuffer();
  var next = 0, search = 0;
  while (search <= input.length) {
    final index = input.indexOf(needle, search);
    if (index < 0) break;
    output.write(input.substring(next, index));
    output.write(
      functional
          ? jString(jCall(argument, [needle, index.toDouble(), input]))
          : jSubstitute(replacement, input, index, needle, [], jUndefined),
    );
    next = index + needle.length;
    if (operation != 'replaceAll') break;
    search = index + math.max(needle.length, 1);
  }
  output.write(input.substring(next));
  return output.toString();
}

void installJSRegExp(JScope scope) {
  JRegex receiver(dynamic r) {
    if (r is! JRegex)
      throw JThrown(JError('TypeError', 'RegExp receiver required'));
    return r;
  }

  late final JFunction constructor;
  dynamic create(List<dynamic> a, bool construct) {
    final input = jArg(a, 0), flags = jArg(a, 1), isRegex = jIsRegExp(input);
    if (!construct &&
        isRegex &&
        identical(flags, jUndefined) &&
        identical(jGet(input, 'constructor'), constructor))
      return input;
    final source = input is JRegex
        ? input.pattern
        : isRegex
        ? jString(jGet(input, 'source'))
        : identical(input, jUndefined)
        ? ''
        : jString(input);
    final options = identical(flags, jUndefined)
        ? input is JRegex
              ? input.flagText
              : isRegex
              ? jString(jGet(input, 'flags'))
              : ''
        : jString(flags);
    return JRegex(source, options);
  }

  constructor = JFunction(
    (a, r) => create(a, false),
    construct: (a) => create(a, true),
  );
  constructor.properties['prototype'] = jRegExpPrototype;
  jRegExpPrototype.properties['constructor'] = constructor;
  constructor.properties['escape'] = jNamedFunction(
    jBuiltin((a) => jRegexEscape(jArg(a, 0))),
    'escape',
    1,
  );
  jAccessor(
    jRegExpPrototype,
    'source',
    (r) => identical(r, jRegExpPrototype) ? '(?:)' : receiver(r).source,
  );
  for (final entry in {
    'hasIndices': 'd',
    'global': 'g',
    'ignoreCase': 'i',
    'multiline': 'm',
    'dotAll': 's',
    'unicode': 'u',
    'unicodeSets': 'v',
    'sticky': 'y',
  }.entries)
    jAccessor(
      jRegExpPrototype,
      entry.key,
      (r) => identical(r, jRegExpPrototype)
          ? jUndefined
          : receiver(r).flagText.contains(entry.value),
    );
  jAccessor(
    jRegExpPrototype,
    'flags',
    (r) => [
      for (final entry in {
        'hasIndices': 'd',
        'global': 'g',
        'ignoreCase': 'i',
        'multiline': 'm',
        'dotAll': 's',
        'unicode': 'u',
        'unicodeSets': 'v',
        'sticky': 'y',
      }.entries)
        if (jTruthy(jGet(r, entry.key))) entry.value,
    ].join(),
  );
  jRegExpPrototype.properties['exec'] = JFunction(
    (a, r) => jRegexBuiltinExec(receiver(r), jString(jArg(a, 0))),
    constructible: false,
  );
  jRegExpPrototype.properties['test'] = JFunction(
    (a, r) => jRegexExec(r, jString(jArg(a, 0))) != null,
    constructible: false,
  );
  jRegExpPrototype.properties['compile'] = JFunction((a, r) {
    final regex = receiver(r), input = jArg(a, 0), flags = jArg(a, 1);
    if (input is JRegex && !identical(flags, jUndefined))
      throw JThrown(
        JError('TypeError', 'Flags cannot accompany a RegExp in compile'),
      );
    final replacement = input is JRegex
        ? JRegex(input.pattern, input.flagText)
        : JRegex(
            identical(input, jUndefined) ? '' : jString(input),
            identical(flags, jUndefined) ? '' : jString(flags),
          );
    regex.pattern = replacement.pattern;
    regex.flagText = replacement.flagText;
    regex.value = replacement.value;
    regex.captureIndices
      ..clear()
      ..addAll(replacement.captureIndices);
    regex.names
      ..clear()
      ..addAll(replacement.names);
    regex.marker = replacement.marker;
    regex.set('lastIndex', 0.0);
    return regex;
  }, constructible: false);
  jRegExpPrototype.properties['toString'] = JFunction(
    (a, r) => '/${jString(jGet(r, 'source'))}/${jString(jGet(r, 'flags'))}',
    constructible: false,
  );
  jRegExpPrototype.symbols[jSymbols['match']!] = JFunction(
    (a, r) => jRegexMatch(r, jString(jArg(a, 0))),
    constructible: false,
  );
  jRegExpPrototype.symbols[jSymbols['replace']!] = JFunction(
    (a, r) => jRegexReplace(r, jString(jArg(a, 0)), jArg(a, 1)),
    constructible: false,
  );
  jRegExpPrototype.symbols[jSymbols['search']!] = JFunction((a, r) {
    final input = jString(jArg(a, 0)), previous = jGet(r, 'lastIndex');
    if (!jSameValue(previous, 0.0)) jSet(r, 'lastIndex', 0.0);
    final result = jRegexExec(r, input);
    if (!jSameValue(jGet(r, 'lastIndex'), previous))
      jSet(r, 'lastIndex', previous);
    return result == null ? -1.0 : jGet(result, 'index');
  }, constructible: false);
  jRegExpPrototype.symbols[jSymbols['split']!] = JFunction(
    (a, r) => jRegexSplit(receiver(r), jString(jArg(a, 0)), jArg(a, 1)),
    constructible: false,
  );
  jRegExpPrototype.symbols[jSymbols['matchAll']!] = JFunction(
    (a, r) => jRegexMatchAll(receiver(r), jString(jArg(a, 0))),
    constructible: false,
  );
  jBuiltinProperties(constructor);
  jBuiltinProperties(jRegExpPrototype);
  jNameFunction(constructor, 'RegExp', 2);
  constructor.flags['prototype'] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  for (final entry in {
    'exec': 1,
    'test': 1,
    'compile': 2,
    'toString': 0,
  }.entries)
    jNameFunction(
      jRegExpPrototype.properties[entry.key],
      entry.key,
      entry.value,
    );
  for (final entry in {
    'match': 1,
    'matchAll': 1,
    'search': 1,
    'replace': 2,
    'split': 2,
  }.entries)
    jNameFunction(
      jRegExpPrototype.symbols[jSymbols[entry.key]],
      '[Symbol.${entry.key}]',
      entry.value,
    );
  scope.define('RegExp', constructor);
}
